package main

import (
	"context"
	"encoding/json"
	"fmt"
	"net/url"
	"sort"
	"strconv"
	"strings"
	"sync"
	"time"
)

// The dashboard's view of the cluster. Everything here is computed from
// read-only API calls, so it works without Prometheus.

type Overview struct {
	GeneratedAt time.Time      `json:"generatedAt"`
	Version     VersionInfo    `json:"version"`
	Totals      Totals         `json:"totals"`
	Capacity    Capacity       `json:"capacity"`
	Nodes       []NodeInfo     `json:"nodes"`
	Namespaces  []NamespaceRow `json:"namespaces"`
	Problems    []Problem      `json:"problems"`
	Apps        []AppInfo      `json:"apps"`
	Events      []EventInfo    `json:"events"`
	Errors      []string       `json:"errors,omitempty"`
}

type VersionInfo struct {
	ControlPlane string         `json:"controlPlane"`
	Nodes        map[string]int `json:"nodes"`
	// Hint is set when the nodes lag the control plane, which is the state
	// to be in right after a control plane upgrade and before the nodes follow.
	Hint string `json:"hint,omitempty"`
}

type Count struct {
	Total int `json:"total"`
	Good  int `json:"good"`
}

type Totals struct {
	Nodes       Count `json:"nodes"`
	Pods        Count `json:"pods"`
	Deployments Count `json:"deployments"`
	Apps        Count `json:"apps"`
	Warnings    int   `json:"warnings"`
	Pending     int   `json:"pending"`
	Restarts    int   `json:"restarts"`
}

type Resource struct {
	Allocatable float64 `json:"allocatable"`
	Requested   float64 `json:"requested"`
}

type Capacity struct {
	CPU    Resource `json:"cpu"`
	Memory Resource `json:"memory"`
	Pods   Resource `json:"pods"`
}

type NodeInfo struct {
	Name         string   `json:"name"`
	Ready        bool     `json:"ready"`
	Roles        []string `json:"roles"`
	Version      string   `json:"version"`
	Zone         string   `json:"zone,omitempty"`
	InstanceType string   `json:"instanceType,omitempty"`
	AgeSeconds   int64    `json:"ageSeconds"`
	CPU          Resource `json:"cpu"`
	Memory       Resource `json:"memory"`
	Pods         Resource `json:"pods"`
	Conditions   []string `json:"conditions"`
}

type NamespaceRow struct {
	Name     string  `json:"name"`
	Pods     int     `json:"pods"`
	Healthy  int     `json:"healthy"`
	Warning  int     `json:"warning"`
	Failing  int     `json:"failing"`
	Restarts int     `json:"restarts"`
	CPU      float64 `json:"cpuRequested"`
	Memory   float64 `json:"memoryRequested"`
}

type Problem struct {
	Severity  string `json:"severity"` // "warning" or "error"
	Kind      string `json:"kind"`
	Namespace string `json:"namespace,omitempty"`
	Name      string `json:"name"`
	Reason    string `json:"reason"`
	Detail    string `json:"detail,omitempty"`
}

type AppInfo struct {
	Name      string `json:"name"`
	Sync      string `json:"sync"`
	Health    string `json:"health"`
	Revision  string `json:"revision,omitempty"`
	Namespace string `json:"namespace,omitempty"`
	Message   string `json:"message,omitempty"`
}

type EventInfo struct {
	Time      time.Time `json:"time"`
	Namespace string    `json:"namespace"`
	Object    string    `json:"object"`
	Reason    string    `json:"reason"`
	Message   string    `json:"message"`
	Count     int       `json:"count"`
}

const (
	sevOK = iota
	sevWarning
	sevError
)

// podState says what a person would see in the STATUS column of kubectl get
// pods, how serious it is, and any detail worth showing.
func podState(p pod, now time.Time) (status string, sev int, detail string) {
	if p.Metadata.DeletionTimestamp != nil {
		return "Terminating", sevOK, ""
	}
	restarts := 0
	lastTerminated := ""
	for _, c := range p.Status.ContainerStatuses {
		restarts += c.RestartCount
		if c.LastState.Terminated != nil && c.LastState.Terminated.Reason != "" {
			lastTerminated = c.LastState.Terminated.Reason
		}
	}
	switch p.Status.Phase {
	case "Succeeded":
		return "Completed", sevOK, ""
	case "Failed":
		reason := p.Status.Reason
		if reason == "" {
			reason = "Failed"
		}
		return reason, sevError, p.Status.Message
	}
	for _, c := range p.Status.InitContainerStatuses {
		if w := c.State.Waiting; w != nil && w.Reason != "" && w.Reason != "PodInitializing" {
			return "Init:" + w.Reason, sevError, w.Message
		}
	}
	for _, c := range p.Status.ContainerStatuses {
		if w := c.State.Waiting; w != nil && w.Reason != "" {
			if w.Reason == "ContainerCreating" {
				if now.Sub(p.Metadata.CreationTimestamp) > 3*time.Minute {
					return w.Reason, sevWarning, "creating for " + now.Sub(p.Metadata.CreationTimestamp).Round(time.Second).String()
				}
				return w.Reason, sevOK, ""
			}
			d := w.Message
			if lastTerminated != "" {
				d = fmt.Sprintf("last exit: %s, %d restarts", lastTerminated, restarts)
			}
			return w.Reason, sevError, d
		}
		if t := c.State.Terminated; t != nil && t.ExitCode != 0 {
			return t.Reason, sevError, fmt.Sprintf("exit code %d", t.ExitCode)
		}
	}
	if p.Status.Phase == "Pending" {
		for _, c := range p.Status.Conditions {
			if c.Type == "PodScheduled" && c.Status == "False" {
				return "Unschedulable", sevError, c.Message
			}
		}
		return "Pending", sevWarning, ""
	}
	ready := len(p.Status.ContainerStatuses) > 0
	for _, c := range p.Status.ContainerStatuses {
		ready = ready && c.Ready
	}
	if !ready {
		age := now.Sub(p.Metadata.CreationTimestamp)
		sev := sevWarning
		if age < time.Minute {
			sev = sevOK
		}
		return "NotReady", sev, notReadyDetail(p)
	}
	if restarts >= 3 {
		return "Restarting", sevWarning, fmt.Sprintf("%d restarts, last exit: %s", restarts, lastTerminated)
	}
	return "Running", sevOK, ""
}

func notReadyDetail(p pod) string {
	for _, c := range p.Status.Conditions {
		if c.Status == "False" && c.Type == "Ready" {
			return strings.TrimSpace(c.Reason + " " + c.Message)
		}
	}
	return ""
}

func podRequests(p pod) (cpu, mem float64) {
	for _, c := range p.Spec.Containers {
		cpu += parseQuantity(c.Resources.Requests["cpu"])
		mem += parseQuantity(c.Resources.Requests["memory"])
	}
	return
}

func podRestarts(p pod) int {
	n := 0
	for _, c := range p.Status.ContainerStatuses {
		n += c.RestartCount
	}
	return n
}

type nodeObj struct {
	Metadata struct {
		Name              string            `json:"name"`
		Labels            map[string]string `json:"labels"`
		CreationTimestamp time.Time         `json:"creationTimestamp"`
	} `json:"metadata"`
	Status struct {
		Allocatable map[string]string `json:"allocatable"`
		Conditions  []struct {
			Type, Status, Message string
		} `json:"conditions"`
		NodeInfo struct {
			KubeletVersion string `json:"kubeletVersion"`
		} `json:"nodeInfo"`
	} `json:"status"`
}

func getList[T any](ctx context.Context, k *Kube, path string, q url.Values) ([]T, error) {
	body, err := k.Get(ctx, path, q)
	if err != nil {
		return nil, err
	}
	var l struct {
		Items []T `json:"items"`
	}
	if err := json.Unmarshal(body, &l); err != nil {
		return nil, err
	}
	return l.Items, nil
}

// Overview reads the cluster and summarises it. A source that can't be read
// (the Argo CD CRD isn't installed, say) is reported in Errors and left out.
func (k *Kube) Overview(ctx context.Context, now time.Time) (*Overview, error) {
	var (
		wg      sync.WaitGroup
		mu      sync.Mutex
		nodes   []nodeObj
		pods    []pod
		deploys []struct {
			Spec   struct{ Replicas *int } `json:"spec"`
			Status struct{ AvailableReplicas int }
		}
		apps    []map[string]any
		events  []eventObj
		version struct {
			GitVersion string `json:"gitVersion"`
		}
		errs  []string
		fatal error
	)
	run := func(name string, required bool, f func() error) {
		wg.Add(1)
		go func() {
			defer wg.Done()
			if err := f(); err != nil {
				mu.Lock()
				defer mu.Unlock()
				if required {
					fatal = fmt.Errorf("%s: %w", name, err)
				} else {
					errs = append(errs, name+": "+err.Error())
				}
			}
		}()
	}
	run("nodes", true, func() (err error) { nodes, err = getList[nodeObj](ctx, k, "/api/v1/nodes", nil); return })
	run("pods", true, func() (err error) { pods, err = getList[pod](ctx, k, "/api/v1/pods", nil); return })
	run("deployments", false, func() (err error) {
		deploys, err = getList[struct {
			Spec   struct{ Replicas *int } `json:"spec"`
			Status struct{ AvailableReplicas int }
		}](ctx, k, "/apis/apps/v1/deployments", nil)
		return
	})
	run("applications", false, func() (err error) {
		apps, err = getList[map[string]any](ctx, k, "/apis/argoproj.io/v1alpha1/namespaces/argocd/applications", nil)
		return
	})
	run("events", false, func() (err error) {
		events, err = getList[eventObj](ctx, k, "/api/v1/events", url.Values{"fieldSelector": {"type=Warning"}})
		return
	})
	run("version", false, func() error {
		body, err := k.Get(ctx, "/version", nil)
		if err == nil {
			err = json.Unmarshal(body, &version)
		}
		return err
	})
	wg.Wait()
	if fatal != nil {
		return nil, fatal
	}

	o := &Overview{GeneratedAt: now, Errors: errs, Nodes: []NodeInfo{}, Namespaces: []NamespaceRow{}, Problems: []Problem{}, Apps: []AppInfo{}, Events: []EventInfo{}}
	o.Version = VersionInfo{ControlPlane: version.GitVersion, Nodes: map[string]int{}}

	nodeIdx := map[string]int{}
	for _, n := range nodes {
		ni := NodeInfo{
			Name:         n.Metadata.Name,
			Version:      n.Status.NodeInfo.KubeletVersion,
			Zone:         n.Metadata.Labels["topology.kubernetes.io/zone"],
			InstanceType: n.Metadata.Labels["node.kubernetes.io/instance-type"],
			AgeSeconds:   int64(now.Sub(n.Metadata.CreationTimestamp).Seconds()),
			CPU:          Resource{Allocatable: parseQuantity(n.Status.Allocatable["cpu"])},
			Memory:       Resource{Allocatable: parseQuantity(n.Status.Allocatable["memory"])},
			Pods:         Resource{Allocatable: parseQuantity(n.Status.Allocatable["pods"])},
			Roles:        []string{},
			Conditions:   []string{},
		}
		for l := range n.Metadata.Labels {
			if r, ok := strings.CutPrefix(l, "node-role.kubernetes.io/"); ok {
				ni.Roles = append(ni.Roles, r)
			}
		}
		sort.Strings(ni.Roles)
		for _, c := range n.Status.Conditions {
			switch {
			case c.Type == "Ready":
				ni.Ready = c.Status == "True"
				if !ni.Ready {
					ni.Conditions = append(ni.Conditions, "NotReady: "+c.Message)
				}
			case c.Status == "True":
				ni.Conditions = append(ni.Conditions, c.Type)
			}
		}
		if !ni.Ready || len(ni.Conditions) > 0 {
			sev := "warning"
			if !ni.Ready {
				sev = "error"
			}
			reason := "NotReady"
			if ni.Ready {
				reason = ni.Conditions[0]
			}
			o.Problems = append(o.Problems, Problem{Severity: sev, Kind: "Node", Name: ni.Name, Reason: reason, Detail: strings.Join(ni.Conditions, "; ")})
		}
		o.Version.Nodes[ni.Version]++
		o.Totals.Nodes.Total++
		if ni.Ready {
			o.Totals.Nodes.Good++
		}
		nodeIdx[ni.Name] = len(o.Nodes)
		o.Nodes = append(o.Nodes, ni)
		o.Capacity.CPU.Allocatable += ni.CPU.Allocatable
		o.Capacity.Memory.Allocatable += ni.Memory.Allocatable
		o.Capacity.Pods.Allocatable += ni.Pods.Allocatable
	}
	o.Version.Hint = versionHint(o.Version)

	nsIdx := map[string]int{}
	for _, p := range pods {
		status, sev, detail := podState(p, now)
		ns := p.Metadata.Namespace
		i, ok := nsIdx[ns]
		if !ok {
			i = len(o.Namespaces)
			nsIdx[ns] = i
			o.Namespaces = append(o.Namespaces, NamespaceRow{Name: ns})
		}
		row := &o.Namespaces[i]
		cpu, mem := podRequests(p)
		restarts := podRestarts(p)
		row.Pods++
		row.Restarts += restarts
		o.Totals.Pods.Total++
		o.Totals.Restarts += restarts
		switch sev {
		case sevOK:
			row.Healthy++
			o.Totals.Pods.Good++
		case sevWarning:
			row.Warning++
		default:
			row.Failing++
		}
		if p.Status.Phase == "Pending" {
			o.Totals.Pending++
		}
		if sev > sevOK {
			s := "warning"
			if sev == sevError {
				s = "error"
			}
			o.Problems = append(o.Problems, Problem{Severity: s, Kind: "Pod", Namespace: ns, Name: p.Metadata.Name, Reason: status, Detail: detail})
		}
		// Finished pods hold no resources. Pending pods with a node do.
		if p.Spec.NodeName != "" && p.Status.Phase != "Succeeded" && p.Status.Phase != "Failed" {
			row.CPU += cpu
			row.Memory += mem
			o.Capacity.CPU.Requested += cpu
			o.Capacity.Memory.Requested += mem
			o.Capacity.Pods.Requested++
			if i, ok := nodeIdx[p.Spec.NodeName]; ok {
				n := &o.Nodes[i]
				n.CPU.Requested += cpu
				n.Memory.Requested += mem
				n.Pods.Requested++
			}
		}
	}

	for _, d := range deploys {
		want := 1
		if d.Spec.Replicas != nil {
			want = *d.Spec.Replicas
		}
		o.Totals.Deployments.Total++
		if d.Status.AvailableReplicas >= want {
			o.Totals.Deployments.Good++
		}
	}

	for _, a := range apps {
		ai := appInfo(a)
		o.Apps = append(o.Apps, ai)
		o.Totals.Apps.Total++
		if ai.Sync == "Synced" && ai.Health == "Healthy" {
			o.Totals.Apps.Good++
			continue
		}
		sev := "warning"
		if ai.Health == "Degraded" || ai.Health == "Missing" {
			sev = "error"
		}
		reason := ai.Sync
		if ai.Health != "Healthy" {
			reason = ai.Health
		}
		o.Problems = append(o.Problems, Problem{Severity: sev, Kind: "Argo CD app", Name: ai.Name, Reason: reason, Detail: ai.Message})
	}

	sort.Slice(events, func(i, j int) bool { return events[i].when().After(events[j].when()) })
	o.Totals.Warnings = len(events)
	for _, e := range events {
		if len(o.Events) == 30 {
			break
		}
		o.Events = append(o.Events, EventInfo{Time: e.when(), Namespace: e.Metadata.Namespace, Object: e.InvolvedObject.Kind + "/" + e.InvolvedObject.Name, Reason: e.Reason, Message: e.Message, Count: max(e.Count, 1)})
	}

	sort.Slice(o.Namespaces, func(i, j int) bool {
		a, b := o.Namespaces[i], o.Namespaces[j]
		if a.Failing != b.Failing {
			return a.Failing > b.Failing
		}
		if a.Warning != b.Warning {
			return a.Warning > b.Warning
		}
		return a.Name < b.Name
	})
	sort.SliceStable(o.Problems, func(i, j int) bool { return o.Problems[i].Severity == "error" && o.Problems[j].Severity != "error" })
	return o, nil
}

type eventObj struct {
	Metadata       struct{ Namespace string }  `json:"metadata"`
	Type           string                      `json:"type"`
	Reason         string                      `json:"reason"`
	Message        string                      `json:"message"`
	Count          int                         `json:"count"`
	LastTimestamp  time.Time                   `json:"lastTimestamp"`
	EventTime      time.Time                   `json:"eventTime"`
	InvolvedObject struct{ Kind, Name string } `json:"involvedObject"`
}

func (e eventObj) when() time.Time {
	if !e.LastTimestamp.IsZero() {
		return e.LastTimestamp
	}
	return e.EventTime
}

func nested(m map[string]any, path ...string) string {
	var cur any = m
	for _, p := range path {
		mm, ok := cur.(map[string]any)
		if !ok {
			return ""
		}
		cur = mm[p]
	}
	s, _ := cur.(string)
	return s
}

func appInfo(a map[string]any) AppInfo {
	rev := nested(a, "status", "sync", "revision")
	if len(rev) > 7 {
		rev = rev[:7]
	}
	msg := nested(a, "status", "health", "message")
	if conds, ok := a["status"].(map[string]any)["conditions"].([]any); ok && len(conds) > 0 {
		if c, ok := conds[0].(map[string]any); ok {
			if m, _ := c["message"].(string); m != "" {
				msg = m
			}
		}
	}
	return AppInfo{
		Name: nested(a, "metadata", "name"), Sync: nested(a, "status", "sync", "status"), Health: nested(a, "status", "health", "status"),
		Revision: rev, Namespace: nested(a, "spec", "destination", "namespace"), Message: msg,
	}
}

func minor(v string) int {
	parts := strings.Split(strings.TrimPrefix(v, "v"), ".")
	if len(parts) < 2 {
		return -1
	}
	n, err := strconv.Atoi(parts[1])
	if err != nil {
		return -1
	}
	return n
}

func versionHint(v VersionInfo) string {
	cp := minor(v.ControlPlane)
	if cp < 0 {
		return ""
	}
	lag := 0
	for ver := range v.Nodes {
		if m := minor(ver); m >= 0 && cp-m > lag {
			lag = cp - m
		}
	}
	switch {
	case lag == 0:
		return ""
	case lag >= 3:
		return fmt.Sprintf("Nodes are %d minor versions behind the control plane, which is the most Kubernetes supports. Upgrade the nodes before the next control plane upgrade.", lag)
	default:
		return fmt.Sprintf("Nodes are %d minor version behind the control plane. Upgrade the node group to match.", lag)
	}
}
