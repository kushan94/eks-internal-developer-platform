package main

import (
	"context"
	"crypto/tls"
	"crypto/x509"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"os"
	"regexp"
	"strings"
	"time"
)

// Kube reads from the Kubernetes API with plain HTTP, so the assistant needs
// no client library. It only ever sends GET requests.
type Kube struct {
	base  string
	http  *http.Client
	token func() string
}

const (
	saDir        = "/var/run/secrets/kubernetes.io/serviceaccount"
	maxBodyBytes = 4 << 20
)

// NewKube talks to the API server from inside the cluster, or to KUBE_API_URL
// (for example `kubectl proxy`) when that is set.
func NewKube() (*Kube, error) {
	if u := os.Getenv("KUBE_API_URL"); u != "" {
		return &Kube{base: strings.TrimSuffix(u, "/"), http: &http.Client{Timeout: 20 * time.Second}, token: func() string { return "" }}, nil
	}
	ca, err := os.ReadFile(saDir + "/ca.crt")
	if err != nil {
		return nil, fmt.Errorf("not in a cluster and KUBE_API_URL is not set: %w", err)
	}
	pool := x509.NewCertPool()
	pool.AppendCertsFromPEM(ca)
	return &Kube{
		base: "https://kubernetes.default.svc",
		http: &http.Client{
			Timeout:   20 * time.Second,
			Transport: &http.Transport{TLSClientConfig: &tls.Config{RootCAs: pool, MinVersion: tls.VersionTLS12}},
		},
		// The token is rotated, so it is read on every request.
		token: func() string {
			b, _ := os.ReadFile(saDir + "/token")
			return strings.TrimSpace(string(b))
		},
	}, nil
}

// Get returns the body of a GET request to the API server.
func (k *Kube) Get(ctx context.Context, path string, query url.Values) ([]byte, error) {
	u := k.base + path
	if len(query) > 0 {
		u += "?" + query.Encode()
	}
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, u, nil)
	if err != nil {
		return nil, err
	}
	if t := k.token(); t != "" {
		req.Header.Set("Authorization", "Bearer "+t)
	}
	resp, err := k.http.Do(req)
	if err != nil {
		return nil, err
	}
	defer resp.Body.Close()
	body, err := io.ReadAll(io.LimitReader(resp.Body, maxBodyBytes))
	if err != nil {
		return nil, err
	}
	if resp.StatusCode != http.StatusOK {
		return nil, fmt.Errorf("kubernetes API %s: %s", resp.Status, strings.TrimSpace(string(body)))
	}
	return body, nil
}

// resourceKind says where the API serves a kind. Secrets and ConfigMaps are
// left out on purpose: this list is what the assistant can read.
type resourceKind struct {
	prefix     string
	namespaced bool
	fixedNS    string
}

var kinds = map[string]resourceKind{
	"pods":                     {"/api/v1", true, ""},
	"services":                 {"/api/v1", true, ""},
	"endpoints":                {"/api/v1", true, ""},
	"persistentvolumeclaims":   {"/api/v1", true, ""},
	"nodes":                    {"/api/v1", false, ""},
	"deployments":              {"/apis/apps/v1", true, ""},
	"replicasets":              {"/apis/apps/v1", true, ""},
	"statefulsets":             {"/apis/apps/v1", true, ""},
	"daemonsets":               {"/apis/apps/v1", true, ""},
	"horizontalpodautoscalers": {"/apis/autoscaling/v2", true, ""},
	"poddisruptionbudgets":     {"/apis/policy/v1", true, ""},
	"networkpolicies":          {"/apis/networking.k8s.io/v1", true, ""},
	"httproutes":               {"/apis/gateway.networking.k8s.io/v1", true, ""},
	"webservices":              {"/apis/platform.example.org/v1alpha1", true, ""},
	"clusters":                 {"/apis/postgresql.cnpg.io/v1", true, ""},
	"applications":             {"/apis/argoproj.io/v1alpha1", true, "argocd"},
}

var nameRE = regexp.MustCompile(`^[a-z0-9]([-a-z0-9.]*[a-z0-9])?$`)

func validName(s string) bool { return len(s) <= 253 && nameRE.MatchString(s) }

// Resource reads one object, or lists a kind. The kind, namespace and name are
// checked before they become part of a URL.
func (k *Kube) Resource(ctx context.Context, kind, namespace, name, labelSelector string) (string, error) {
	rk, ok := kinds[kind]
	if !ok {
		names := make([]string, 0, len(kinds))
		for n := range kinds {
			names = append(names, n)
		}
		return "", fmt.Errorf("kind %q can't be read; readable kinds: %s", kind, strings.Join(sortedStrings(names), ", "))
	}
	if rk.fixedNS != "" {
		namespace = rk.fixedNS
	}
	path := rk.prefix
	if rk.namespaced {
		if !validName(namespace) {
			return "", fmt.Errorf("namespace %q is not valid", namespace)
		}
		path += "/namespaces/" + namespace
	}
	path += "/" + kind
	if name != "" {
		if !validName(name) {
			return "", fmt.Errorf("name %q is not valid", name)
		}
		path += "/" + name
	}
	q := url.Values{}
	if labelSelector != "" && name == "" {
		q.Set("labelSelector", labelSelector)
	}
	body, err := k.Get(ctx, path, q)
	if err != nil {
		return "", err
	}
	return stripNoise(body)
}

// stripNoise removes the parts of Kubernetes objects that make them long and
// say nothing about health.
func stripNoise(body []byte) (string, error) {
	var v any
	if err := json.Unmarshal(body, &v); err != nil {
		return "", err
	}
	var clean func(any)
	clean = func(x any) {
		switch t := x.(type) {
		case map[string]any:
			if md, ok := t["metadata"].(map[string]any); ok {
				delete(md, "managedFields")
				if an, ok := md["annotations"].(map[string]any); ok {
					delete(an, "kubectl.kubernetes.io/last-applied-configuration")
				}
			}
			for _, c := range t {
				clean(c)
			}
		case []any:
			for _, c := range t {
				clean(c)
			}
		}
	}
	clean(v)
	out, err := json.MarshalIndent(v, "", " ")
	return string(out), err
}

type podList struct {
	Items []pod `json:"items"`
}

type pod struct {
	Metadata struct {
		Name              string     `json:"name"`
		Namespace         string     `json:"namespace"`
		CreationTimestamp time.Time  `json:"creationTimestamp"`
		DeletionTimestamp *time.Time `json:"deletionTimestamp"`
	} `json:"metadata"`
	Spec struct {
		NodeName   string `json:"nodeName"`
		Containers []struct {
			Resources struct {
				Requests map[string]string `json:"requests"`
			} `json:"resources"`
		} `json:"containers"`
	} `json:"spec"`
	Status struct {
		Phase      string `json:"phase"`
		Reason     string `json:"reason"`
		Message    string `json:"message"`
		Conditions []struct {
			Type, Status, Reason, Message string
		} `json:"conditions"`
		InitContainerStatuses []containerStatus `json:"initContainerStatuses"`
		ContainerStatuses     []containerStatus `json:"containerStatuses"`
	} `json:"status"`
}

type containerStatus struct {
	Name         string `json:"name"`
	Ready        bool   `json:"ready"`
	RestartCount int    `json:"restartCount"`
	State        state  `json:"state"`
	LastState    state  `json:"lastState"`
}

type state struct {
	Waiting    *struct{ Reason, Message string } `json:"waiting"`
	Terminated *struct {
		Reason   string `json:"reason"`
		Message  string `json:"message"`
		ExitCode int    `json:"exitCode"`
	} `json:"terminated"`
}

func (s state) String() string {
	switch {
	case s.Waiting != nil:
		return strings.TrimSpace("waiting: " + s.Waiting.Reason + " " + s.Waiting.Message)
	case s.Terminated != nil:
		return fmt.Sprintf("terminated: %s (exit code %d) %s", s.Terminated.Reason, s.Terminated.ExitCode, s.Terminated.Message)
	}
	return ""
}

// Pods summarises the pods in a namespace: what a person would read from
// kubectl get pods plus the reason a container isn't running.
func (k *Kube) Pods(ctx context.Context, namespace, labelSelector string, now time.Time) (string, error) {
	if !validName(namespace) {
		return "", fmt.Errorf("namespace %q is not valid", namespace)
	}
	q := url.Values{}
	if labelSelector != "" {
		q.Set("labelSelector", labelSelector)
	}
	body, err := k.Get(ctx, "/api/v1/namespaces/"+namespace+"/pods", q)
	if err != nil {
		return "", err
	}
	var pl podList
	if err := json.Unmarshal(body, &pl); err != nil {
		return "", err
	}
	if len(pl.Items) == 0 {
		return "No pods in namespace " + namespace + " match.", nil
	}
	var b strings.Builder
	for _, p := range pl.Items {
		fmt.Fprintf(&b, "pod %s: phase %s, node %q, age %s\n", p.Metadata.Name, p.Status.Phase, p.Spec.NodeName, now.Sub(p.Metadata.CreationTimestamp).Round(time.Second))
		if p.Status.Reason != "" {
			fmt.Fprintf(&b, "  status reason: %s %s\n", p.Status.Reason, p.Status.Message)
		}
		for _, c := range p.Status.Conditions {
			if c.Status == "False" {
				fmt.Fprintf(&b, "  condition %s is False: %s %s\n", c.Type, c.Reason, c.Message)
			}
		}
		for _, c := range p.Status.ContainerStatuses {
			fmt.Fprintf(&b, "  container %s: ready=%t restarts=%d", c.Name, c.Ready, c.RestartCount)
			if s := c.State.String(); s != "" {
				fmt.Fprintf(&b, " state=[%s]", s)
			}
			if s := c.LastState.String(); s != "" {
				fmt.Fprintf(&b, " lastState=[%s]", s)
			}
			b.WriteByte('\n')
		}
	}
	return b.String(), nil
}

type eventList struct {
	Items []struct {
		Type, Reason, Message string
		Count                 int
		LastTimestamp         time.Time                   `json:"lastTimestamp"`
		EventTime             time.Time                   `json:"eventTime"`
		InvolvedObject        struct{ Kind, Name string } `json:"involvedObject"`
	} `json:"items"`
}

// Events lists the newest events in a namespace, optionally for one object.
func (k *Kube) Events(ctx context.Context, namespace, object string) (string, error) {
	if !validName(namespace) {
		return "", fmt.Errorf("namespace %q is not valid", namespace)
	}
	q := url.Values{}
	if object != "" {
		if !validName(object) {
			return "", fmt.Errorf("object %q is not valid", object)
		}
		q.Set("fieldSelector", "involvedObject.name="+object)
	}
	body, err := k.Get(ctx, "/api/v1/namespaces/"+namespace+"/events", q)
	if err != nil {
		return "", err
	}
	var el eventList
	if err := json.Unmarshal(body, &el); err != nil {
		return "", err
	}
	items := el.Items
	when := func(i int) time.Time {
		if !items[i].LastTimestamp.IsZero() {
			return items[i].LastTimestamp
		}
		return items[i].EventTime
	}
	sortBy(len(items), func(i, j int) bool { return when(i).After(when(j)) }, func(i, j int) { items[i], items[j] = items[j], items[i] })
	if len(items) == 0 {
		return "No events.", nil
	}
	if len(items) > 40 {
		items = items[:40]
	}
	var b strings.Builder
	for i, e := range items {
		fmt.Fprintf(&b, "%s %s %s/%s %s: %s (x%d)\n", when(i).Format(time.RFC3339), e.Type, e.InvolvedObject.Kind, e.InvolvedObject.Name, e.Reason, e.Message, max(e.Count, 1))
	}
	return b.String(), nil
}

// Logs returns the last lines of a container's log.
func (k *Kube) Logs(ctx context.Context, namespace, pod, container string, previous bool, tail int) (string, error) {
	if !validName(namespace) || !validName(pod) {
		return "", fmt.Errorf("namespace or pod name is not valid")
	}
	if container != "" && !validName(container) {
		return "", fmt.Errorf("container %q is not valid", container)
	}
	tail = min(max(tail, 1), 300)
	q := url.Values{"tailLines": {fmt.Sprint(tail)}}
	if container != "" {
		q.Set("container", container)
	}
	if previous {
		q.Set("previous", "true")
	}
	body, err := k.Get(ctx, "/api/v1/namespaces/"+namespace+"/pods/"+pod+"/log", q)
	if err != nil {
		return "", err
	}
	if len(body) == 0 {
		return "The log is empty.", nil
	}
	return string(body), nil
}

// PodNames lists the names of the pods in a namespace, or nothing on error.
func (k *Kube) PodNames(ctx context.Context, namespace string) []string {
	if !validName(namespace) {
		return nil
	}
	body, err := k.Get(ctx, "/api/v1/namespaces/"+namespace+"/pods", nil)
	if err != nil {
		return nil
	}
	var pl podList
	if json.Unmarshal(body, &pl) != nil {
		return nil
	}
	names := make([]string, 0, len(pl.Items))
	for _, p := range pl.Items {
		names = append(names, p.Metadata.Name)
	}
	return names
}
