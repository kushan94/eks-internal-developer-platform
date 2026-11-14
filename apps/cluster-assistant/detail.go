package main

import (
	"context"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"sort"
	"strconv"
	"time"
)

type PodRow struct {
	Name       string  `json:"name"`
	Status     string  `json:"status"`
	Severity   string  `json:"severity"`
	Detail     string  `json:"detail,omitempty"`
	Ready      string  `json:"ready"`
	Restarts   int     `json:"restarts"`
	Node       string  `json:"node,omitempty"`
	AgeSeconds int64   `json:"ageSeconds"`
	CPU        float64 `json:"cpuRequested"`
	Memory     float64 `json:"memoryRequested"`
}

type DeploymentRow struct {
	Name      string `json:"name"`
	Desired   int    `json:"desired"`
	Available int    `json:"available"`
}

type WebServiceRow struct {
	Name    string `json:"name"`
	Ready   string `json:"ready"` // "True", "False" or "" before Crossplane reports
	Message string `json:"message,omitempty"`
}

type NamespaceDetail struct {
	Name        string          `json:"name"`
	Pods        []PodRow        `json:"pods"`
	Deployments []DeploymentRow `json:"deployments"`
	WebServices []WebServiceRow `json:"webservices"`
	Events      []EventInfo     `json:"events"`
}

var (
	severityNames = [...]string{"ok", "warning", "error"}
	severityRank  = map[string]int{"ok": sevOK, "warning": sevWarning, "error": sevError}
)

// NamespaceDetail reads what is in one namespace for the drill-down view.
func (k *Kube) NamespaceDetail(ctx context.Context, ns string, now time.Time) (*NamespaceDetail, error) {
	if !validName(ns) {
		return nil, fmt.Errorf("namespace %q is not valid", ns)
	}
	pods, err := getList[pod](ctx, k, "/api/v1/namespaces/"+ns+"/pods", nil)
	if err != nil {
		return nil, err
	}
	d := &NamespaceDetail{Name: ns, Pods: []PodRow{}, Deployments: []DeploymentRow{}, WebServices: []WebServiceRow{}, Events: []EventInfo{}}
	for _, p := range pods {
		status, sev, detail := podState(p, now)
		ready := 0
		for _, c := range p.Status.ContainerStatuses {
			if c.Ready {
				ready++
			}
		}
		cpu, mem := podRequests(p)
		d.Pods = append(d.Pods, PodRow{
			Name: p.Metadata.Name, Status: status, Severity: severityNames[sev], Detail: detail,
			Ready: strconv.Itoa(ready) + "/" + strconv.Itoa(len(p.Status.ContainerStatuses)), Restarts: podRestarts(p),
			Node: p.Spec.NodeName, AgeSeconds: int64(now.Sub(p.Metadata.CreationTimestamp).Seconds()), CPU: cpu, Memory: mem,
		})
	}
	// Worst first.
	sort.SliceStable(d.Pods, func(i, j int) bool { return severityRank[d.Pods[i].Severity] > severityRank[d.Pods[j].Severity] })

	deploys, _ := getList[struct {
		Metadata struct{ Name string }   `json:"metadata"`
		Spec     struct{ Replicas *int } `json:"spec"`
		Status   struct{ AvailableReplicas int }
	}](ctx, k, "/apis/apps/v1/namespaces/"+ns+"/deployments", nil)
	for _, x := range deploys {
		want := 1
		if x.Spec.Replicas != nil {
			want = *x.Spec.Replicas
		}
		d.Deployments = append(d.Deployments, DeploymentRow{Name: x.Metadata.Name, Desired: want, Available: x.Status.AvailableReplicas})
	}

	// The WebService kind only exists once Crossplane has installed it.
	wss, _ := getList[map[string]any](ctx, k, "/apis/platform.example.org/v1alpha1/namespaces/"+ns+"/webservices", nil)
	for _, w := range wss {
		row := WebServiceRow{Name: nested(w, "metadata", "name")}
		if st, ok := w["status"].(map[string]any); ok {
			if conds, ok := st["conditions"].([]any); ok {
				for _, c := range conds {
					if cm, ok := c.(map[string]any); ok && cm["type"] == "Ready" {
						row.Ready, _ = cm["status"].(string)
						row.Message, _ = cm["message"].(string)
					}
				}
			}
		}
		d.WebServices = append(d.WebServices, row)
	}

	events, _ := getList[eventObj](ctx, k, "/api/v1/namespaces/"+ns+"/events", nil)
	sort.Slice(events, func(i, j int) bool { return events[i].when().After(events[j].when()) })
	for _, e := range events {
		if len(d.Events) == 30 {
			break
		}
		if e.Type != "Warning" {
			continue
		}
		d.Events = append(d.Events, EventInfo{Time: e.when(), Namespace: ns, Object: e.InvolvedObject.Kind + "/" + e.InvolvedObject.Name, Reason: e.Reason, Message: e.Message, Count: max(e.Count, 1)})
	}
	return d, nil
}

// Series is one chart: a name and points of [unix seconds, value].
type Series struct {
	Name   string       `json:"name"`
	Title  string       `json:"title"`
	Unit   string       `json:"unit"`
	Points [][2]float64 `json:"points"`
}

type Charts struct {
	Enabled bool     `json:"enabled"`
	Series  []Series `json:"series"`
	Errors  []string `json:"errors,omitempty"`
}

// The charts are fixed queries, so the dashboard can't be used to run
// arbitrary PromQL.
var chartQueries = []struct{ name, title, unit, query string }{
	{"cpu", "Node CPU in use", "%", `100 * (1 - avg(rate(node_cpu_seconds_total{mode="idle"}[5m])))`},
	{"memory", "Node memory in use", "%", `100 * (1 - sum(node_memory_MemAvailable_bytes) / sum(node_memory_MemTotal_bytes))`},
	{"restarts", "Container restarts (10 min)", "", `sum(increase(kube_pod_container_status_restarts_total[10m]))`},
	{"notready", "Pods not ready", "", `sum(kube_pod_status_ready{condition="false"})`},
}

// QueryRange runs a range query that returns one series, and gives its points.
func (p *Prometheus) QueryRange(ctx context.Context, query string, start, end time.Time, step time.Duration) ([][2]float64, error) {
	q := url.Values{
		"query": {query}, "step": {fmt.Sprint(int(step.Seconds()))},
		"start": {strconv.FormatInt(start.Unix(), 10)}, "end": {strconv.FormatInt(end.Unix(), 10)},
	}
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, p.base+"/api/v1/query_range?"+q.Encode(), nil)
	if err != nil {
		return nil, err
	}
	resp, err := p.http.Do(req)
	if err != nil {
		return nil, err
	}
	defer resp.Body.Close()
	body, err := io.ReadAll(io.LimitReader(resp.Body, maxBodyBytes))
	if err != nil {
		return nil, err
	}
	if resp.StatusCode != http.StatusOK {
		return nil, fmt.Errorf("Prometheus %s", resp.Status)
	}
	var r struct {
		Data struct {
			Result []struct {
				Values [][2]any `json:"values"`
			} `json:"result"`
		} `json:"data"`
	}
	if err := json.Unmarshal(body, &r); err != nil {
		return nil, err
	}
	points := [][2]float64{}
	if len(r.Data.Result) == 0 {
		return points, nil
	}
	for _, v := range r.Data.Result[0].Values {
		ts, _ := v[0].(float64)
		val, _ := strconv.ParseFloat(fmt.Sprint(v[1]), 64)
		points = append(points, [2]float64{ts, val})
	}
	return points, nil
}

// Charts gathers the last hour of the fixed chart queries.
func (p *Prometheus) Charts(ctx context.Context, now time.Time) Charts {
	c := Charts{Series: []Series{}}
	if p == nil || p.base == "" {
		return c
	}
	c.Enabled = true
	for _, q := range chartQueries {
		points, err := p.QueryRange(ctx, q.query, now.Add(-time.Hour), now, time.Minute)
		if err != nil {
			c.Errors = append(c.Errors, q.name+": "+err.Error())
			continue
		}
		c.Series = append(c.Series, Series{Name: q.name, Title: q.title, Unit: q.unit, Points: points})
	}
	return c
}
