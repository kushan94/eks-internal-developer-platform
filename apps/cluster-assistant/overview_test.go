package main

import (
	"context"
	"encoding/json"
	"io"
	"log/slog"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"
)

var now = time.Date(2026, 11, 14, 12, 0, 0, 0, time.UTC)

func TestParseQuantity(t *testing.T) {
	for in, want := range map[string]float64{
		"": 0, "2": 2, "250m": 0.25, "1500m": 1.5, "128Mi": 128 << 20, "1Gi": 1 << 30, "32Mi": 32 << 20,
		"1G": 1e9, "500k": 5e5, "4021324Ki": 4021324 * 1024, "1e3": 1000, "nonsense": 0, "12Xi": 0,
	} {
		if got := parseQuantity(in); got != want {
			t.Errorf("parseQuantity(%q) = %v, want %v", in, got, want)
		}
	}
}

func mustPod(t *testing.T, js string) pod {
	t.Helper()
	var p pod
	if err := json.Unmarshal([]byte(js), &p); err != nil {
		t.Fatal(err)
	}
	return p
}

func TestPodState(t *testing.T) {
	young := `"creationTimestamp":"2026-11-14T11:59:40Z"`
	old := `"creationTimestamp":"2026-11-14T11:00:00Z"`
	for _, c := range []struct {
		name, pod, status string
		sev               int
		detail            string
	}{
		{"crash loop with the last exit", `{"metadata":{` + old + `},"status":{"phase":"Running","containerStatuses":[{"name":"a","restartCount":7,"state":{"waiting":{"reason":"CrashLoopBackOff"}},"lastState":{"terminated":{"reason":"OOMKilled","exitCode":137}}}]}}`, "CrashLoopBackOff", sevError, "OOMKilled"},
		{"image pull", `{"metadata":{` + old + `},"status":{"phase":"Pending","containerStatuses":[{"name":"a","state":{"waiting":{"reason":"ImagePullBackOff","message":"not found"}}}]}}`, "ImagePullBackOff", sevError, "not found"},
		{"unschedulable", `{"metadata":{` + old + `},"status":{"phase":"Pending","conditions":[{"type":"PodScheduled","status":"False","reason":"Unschedulable","message":"0/1 nodes: Insufficient cpu"}]}}`, "Unschedulable", sevError, "Insufficient cpu"},
		{"healthy", `{"metadata":{` + old + `},"status":{"phase":"Running","containerStatuses":[{"name":"a","ready":true}]}}`, "Running", sevOK, ""},
		{"restarted a lot but running", `{"metadata":{` + old + `},"status":{"phase":"Running","containerStatuses":[{"name":"a","ready":true,"restartCount":4,"lastState":{"terminated":{"reason":"Error","exitCode":1}}}]}}`, "Restarting", sevWarning, "4 restarts"},
		{"not ready for a while", `{"metadata":{` + old + `},"status":{"phase":"Running","conditions":[{"type":"Ready","status":"False","reason":"ContainersNotReady"}],"containerStatuses":[{"name":"a","ready":false}]}}`, "NotReady", sevWarning, "ContainersNotReady"},
		{"not ready yet, just started", `{"metadata":{` + young + `},"status":{"phase":"Running","containerStatuses":[{"name":"a","ready":false}]}}`, "NotReady", sevOK, ""},
		{"completed job", `{"metadata":{` + old + `},"status":{"phase":"Succeeded"}}`, "Completed", sevOK, ""},
		{"evicted", `{"metadata":{` + old + `},"status":{"phase":"Failed","reason":"Evicted","message":"low on memory"}}`, "Evicted", sevError, "low on memory"},
		{"init container failing", `{"metadata":{` + old + `},"status":{"phase":"Pending","initContainerStatuses":[{"name":"i","state":{"waiting":{"reason":"CrashLoopBackOff"}}}]}}`, "Init:CrashLoopBackOff", sevError, ""},
		{"terminating", `{"metadata":{` + old + `,"deletionTimestamp":"2026-11-14T11:59:00Z"},"status":{"phase":"Running"}}`, "Terminating", sevOK, ""},
	} {
		status, sev, detail := podState(mustPod(t, c.pod), now)
		if status != c.status || sev != c.sev || !strings.Contains(detail, c.detail) {
			t.Errorf("%s: got %q sev %d %q, want %q sev %d containing %q", c.name, status, sev, detail, c.status, c.sev, c.detail)
		}
	}
}

func TestVersionHint(t *testing.T) {
	for _, c := range []struct {
		cp    string
		nodes map[string]int
		hint  string
	}{
		{"v1.34.2-eks-abc", map[string]int{"v1.34.1": 2}, ""},
		{"v1.34.2", map[string]int{"v1.33.5": 1, "v1.34.1": 1}, "1 minor version behind"},
		{"v1.34.2", map[string]int{"v1.31.0": 1}, "3 minor versions behind"},
		{"", map[string]int{"v1.31.0": 1}, ""},
	} {
		got := versionHint(VersionInfo{ControlPlane: c.cp, Nodes: c.nodes})
		if (c.hint == "") != (got == "") || !strings.Contains(got, c.hint) {
			t.Errorf("versionHint(%s, %v) = %q, want %q", c.cp, c.nodes, got, c.hint)
		}
	}
}

// fakeCluster serves a small cluster: two nodes, a healthy app, a crashing
// app, and an Argo CD app that is out of sync.
func fakeCluster(t *testing.T, withArgo bool) *Kube {
	t.Helper()
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		switch r.URL.Path {
		case "/version":
			w.Write([]byte(`{"gitVersion":"v1.34.2-eks-1"}`))
		case "/api/v1/nodes":
			w.Write([]byte(`{"items":[
			 {"metadata":{"name":"n1","creationTimestamp":"2026-11-14T10:00:00Z","labels":{"node-role.kubernetes.io/control-plane":"","topology.kubernetes.io/zone":"eu-north-1a","node.kubernetes.io/instance-type":"t3.medium"}},
			  "status":{"allocatable":{"cpu":"2","memory":"4Gi","pods":"110"},"nodeInfo":{"kubeletVersion":"v1.34.1"},"conditions":[{"type":"Ready","status":"True"},{"type":"MemoryPressure","status":"False"}]}},
			 {"metadata":{"name":"n2","creationTimestamp":"2026-11-14T10:00:00Z"},
			  "status":{"allocatable":{"cpu":"2","memory":"4Gi","pods":"110"},"nodeInfo":{"kubeletVersion":"v1.33.5"},"conditions":[{"type":"Ready","status":"True"},{"type":"DiskPressure","status":"True"}]}}]}`))
		case "/api/v1/pods":
			w.Write([]byte(`{"items":[
			 {"metadata":{"name":"ok-1","namespace":"shop","creationTimestamp":"2026-11-14T10:00:00Z"},"spec":{"nodeName":"n1","containers":[{"resources":{"requests":{"cpu":"250m","memory":"256Mi"}}},{"resources":{"requests":{"cpu":"250m","memory":"256Mi"}}}]},"status":{"phase":"Running","containerStatuses":[{"name":"a","ready":true}]}},
			 {"metadata":{"name":"crash-1","namespace":"shop","creationTimestamp":"2026-11-14T10:00:00Z"},"spec":{"nodeName":"n2","containers":[{"resources":{"requests":{"cpu":"1","memory":"1Gi"}}}]},"status":{"phase":"Running","containerStatuses":[{"name":"a","restartCount":9,"state":{"waiting":{"reason":"CrashLoopBackOff"}},"lastState":{"terminated":{"reason":"OOMKilled","exitCode":137}}}]}},
			 {"metadata":{"name":"stuck-1","namespace":"jobs","creationTimestamp":"2026-11-14T10:00:00Z"},"spec":{"containers":[{"resources":{"requests":{"cpu":"100"}}}]},"status":{"phase":"Pending","conditions":[{"type":"PodScheduled","status":"False","reason":"Unschedulable","message":"Insufficient cpu"}]}},
			 {"metadata":{"name":"done-1","namespace":"jobs","creationTimestamp":"2026-11-14T10:00:00Z"},"spec":{"nodeName":"n1","containers":[{"resources":{"requests":{"cpu":"1"}}}]},"status":{"phase":"Succeeded"}}]}`))
		case "/apis/apps/v1/deployments":
			w.Write([]byte(`{"items":[{"spec":{"replicas":2},"status":{"availableReplicas":2}},{"spec":{"replicas":1},"status":{}}]}`))
		case "/apis/argoproj.io/v1alpha1/namespaces/argocd/applications":
			if !withArgo {
				http.NotFound(w, r)
				return
			}
			w.Write([]byte(`{"items":[
			 {"metadata":{"name":"shop"},"spec":{"destination":{"namespace":"shop"}},"status":{"sync":{"status":"Synced","revision":"0123456789abcdef"},"health":{"status":"Healthy"}}},
			 {"metadata":{"name":"loki"},"spec":{"destination":{"namespace":"monitoring"}},"status":{"sync":{"status":"OutOfSync"},"health":{"status":"Degraded"},"conditions":[{"message":"ComparisonError: boom"}]}}]}`))
		case "/api/v1/events":
			w.Write([]byte(`{"items":[
			 {"metadata":{"namespace":"shop"},"type":"Warning","reason":"BackOff","message":"Back-off restarting","count":9,"lastTimestamp":"2026-11-14T11:55:00Z","involvedObject":{"kind":"Pod","name":"crash-1"}},
			 {"metadata":{"namespace":"jobs"},"type":"Warning","reason":"FailedScheduling","message":"Insufficient cpu","lastTimestamp":"2026-11-14T11:58:00Z","involvedObject":{"kind":"Pod","name":"stuck-1"}}]}`))
		case "/api/v1/namespaces/shop/pods":
			w.Write([]byte(`{"items":[
			 {"metadata":{"name":"ok-1","creationTimestamp":"2026-11-14T10:00:00Z"},"spec":{"nodeName":"n1"},"status":{"phase":"Running","containerStatuses":[{"name":"a","ready":true}]}},
			 {"metadata":{"name":"crash-1","creationTimestamp":"2026-11-14T10:00:00Z"},"spec":{"nodeName":"n2"},"status":{"phase":"Running","containerStatuses":[{"name":"a","restartCount":9,"state":{"waiting":{"reason":"CrashLoopBackOff"}}}]}}]}`))
		case "/apis/apps/v1/namespaces/shop/deployments":
			w.Write([]byte(`{"items":[{"metadata":{"name":"web"},"spec":{"replicas":2},"status":{"availableReplicas":1}}]}`))
		case "/apis/platform.example.org/v1alpha1/namespaces/shop/webservices":
			w.Write([]byte(`{"items":[{"metadata":{"name":"web"},"status":{"conditions":[{"type":"Synced","status":"True"},{"type":"Ready","status":"False","message":"waiting for the Deployment"}]}}]}`))
		case "/api/v1/namespaces/shop/events":
			w.Write([]byte(`{"items":[
			 {"type":"Normal","reason":"Pulled","message":"ok","lastTimestamp":"2026-11-14T11:59:00Z","involvedObject":{"kind":"Pod","name":"ok-1"}},
			 {"type":"Warning","reason":"BackOff","message":"Back-off","count":9,"lastTimestamp":"2026-11-14T11:55:00Z","involvedObject":{"kind":"Pod","name":"crash-1"}}]}`))
		default:
			http.NotFound(w, r)
		}
	}))
	t.Cleanup(srv.Close)
	return &Kube{base: srv.URL, http: srv.Client(), token: func() string { return "" }}
}

func TestOverview(t *testing.T) {
	o, err := fakeCluster(t, true).Overview(context.Background(), now)
	if err != nil {
		t.Fatal(err)
	}
	if o.Totals.Nodes != (Count{2, 2}) || o.Totals.Pods != (Count{4, 2}) || o.Totals.Deployments != (Count{2, 1}) || o.Totals.Apps != (Count{2, 1}) || o.Totals.Warnings != 2 || o.Totals.Pending != 1 || o.Totals.Restarts != 9 {
		t.Errorf("totals: %+v", o.Totals)
	}
	// Requests count for pods on a node that haven't finished: ok-1 (0.5 CPU) and crash-1 (1 CPU). Not the finished or the unscheduled pod.
	if o.Capacity.CPU.Allocatable != 4 || o.Capacity.CPU.Requested != 1.5 || o.Capacity.Pods.Requested != 2 || o.Capacity.Memory.Requested != (512<<20)+(1<<30) {
		t.Errorf("capacity: %+v", o.Capacity)
	}
	n1 := o.Nodes[0]
	if n1.CPU.Requested != 0.5 || n1.Zone != "eu-north-1a" || n1.InstanceType != "t3.medium" || len(n1.Roles) != 1 || n1.Roles[0] != "control-plane" {
		t.Errorf("node n1: %+v", n1)
	}
	if o.Version.ControlPlane != "v1.34.2-eks-1" || !strings.Contains(o.Version.Hint, "1 minor version behind") {
		t.Errorf("version: %+v", o.Version)
	}
	// Namespaces: the one with a failing pod is first.
	if o.Namespaces[0].Name != "jobs" && o.Namespaces[0].Name != "shop" || o.Namespaces[0].Failing == 0 {
		t.Errorf("namespaces: %+v", o.Namespaces)
	}
	got := map[string]string{}
	for _, p := range o.Problems {
		got[p.Kind+"/"+p.Name] = p.Severity + ":" + p.Reason
	}
	for k, v := range map[string]string{
		"Pod/crash-1": "error:CrashLoopBackOff", "Pod/stuck-1": "error:Unschedulable",
		"Argo CD app/loki": "error:Degraded", "Node/n2": "warning:DiskPressure",
	} {
		if got[k] != v {
			t.Errorf("problem %s = %q, want %q (all: %v)", k, got[k], v, got)
		}
	}
	if _, ok := got["Pod/ok-1"]; ok || got["Pod/done-1"] != "" {
		t.Errorf("healthy and finished pods are listed as problems: %v", got)
	}
	for i, p := range o.Problems {
		if p.Severity == "warning" && i < len(o.Problems)-1 && o.Problems[i+1].Severity == "error" {
			t.Errorf("errors don't come first: %+v", o.Problems)
		}
	}
	if len(o.Events) != 2 || o.Events[0].Reason != "FailedScheduling" {
		t.Errorf("events: %+v", o.Events)
	}
	if len(o.Apps) != 2 || o.Apps[0].Revision != "0123456" || o.Apps[1].Message != "ComparisonError: boom" {
		t.Errorf("apps: %+v", o.Apps)
	}
}

// Without the Argo CD CRD the overview still works, and says what it left out.
func TestOverviewWithoutArgoCD(t *testing.T) {
	o, err := fakeCluster(t, false).Overview(context.Background(), now)
	if err != nil {
		t.Fatal(err)
	}
	if len(o.Apps) != 0 || len(o.Errors) != 1 || !strings.HasPrefix(o.Errors[0], "applications:") {
		t.Errorf("apps=%v errors=%v", o.Apps, o.Errors)
	}
}

func TestOverviewFailsWithoutPods(t *testing.T) {
	srv := httptest.NewServer(http.NotFoundHandler())
	defer srv.Close()
	k := &Kube{base: srv.URL, http: srv.Client(), token: func() string { return "" }}
	if _, err := k.Overview(context.Background(), now); err == nil {
		t.Error("expected an error")
	}
}

func TestNamespaceDetail(t *testing.T) {
	d, err := fakeCluster(t, true).NamespaceDetail(context.Background(), "shop", now)
	if err != nil {
		t.Fatal(err)
	}
	if d.Pods[0].Name != "crash-1" || d.Pods[0].Severity != "error" || d.Pods[0].Restarts != 9 || d.Pods[1].Ready != "1/1" {
		t.Errorf("pods: %+v", d.Pods)
	}
	if len(d.Deployments) != 1 || d.Deployments[0].Available != 1 || d.Deployments[0].Desired != 2 {
		t.Errorf("deployments: %+v", d.Deployments)
	}
	if len(d.WebServices) != 1 || d.WebServices[0].Ready != "False" || d.WebServices[0].Message != "waiting for the Deployment" {
		t.Errorf("webservices: %+v", d.WebServices)
	}
	if len(d.Events) != 1 || d.Events[0].Reason != "BackOff" {
		t.Errorf("only warnings should be listed: %+v", d.Events)
	}
	if _, err := fakeCluster(t, true).NamespaceDetail(context.Background(), "shop/../x", now); err == nil {
		t.Error("an invalid namespace was accepted")
	}
}

func TestCharts(t *testing.T) {
	var queries []string
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		queries = append(queries, r.URL.Query().Get("query"))
		if strings.Contains(r.URL.Query().Get("query"), "notready") || strings.Contains(r.URL.Query().Get("query"), "kube_pod_status_ready") {
			http.Error(w, "boom", http.StatusInternalServerError)
			return
		}
		w.Write([]byte(`{"status":"success","data":{"resultType":"matrix","result":[{"metric":{},"values":[[1700000000,"12.5"],[1700000060,"13"]]}]}}`))
	}))
	defer srv.Close()
	c := (&Prometheus{base: srv.URL, http: srv.Client()}).Charts(context.Background(), now)
	if !c.Enabled || len(c.Series) != 3 || len(c.Errors) != 1 || c.Series[0].Points[1] != [2]float64{1700000060, 13} {
		t.Errorf("charts: %+v", c)
	}
	if off := (*Prometheus)(nil).Charts(context.Background(), now); off.Enabled {
		t.Error("charts are enabled without Prometheus")
	}
}

func testServer(m Messenger, tools ...Tool) *server {
	log := slog.New(slog.NewTextHandler(io.Discard, nil))
	return &server{agent: &Agent{Model: "m", Client: m, Tools: tools, MaxTurns: 3, MaxTokens: 100, Log: log}, limit: &limiter{max: 2}, log: log}
}

func TestStreamedDiagnosis(t *testing.T) {
	m := &scripted{replies: []string{
		reply("tool_use", `[`+toolUse("t1", "list_pods", `{"namespace":"shop"}`)+`]`),
		reply("end_turn", `[{"type":"text","text":"Out of memory."}]`),
	}}
	s := testServer(m, echo("list_pods", "OOMKilled", nil))
	rec := httptest.NewRecorder()
	s.handleDiagnoseStream(rec, httptest.NewRequest("POST", "/api/diagnose/stream", strings.NewReader(`{"namespace":"shop","pod":"crash-1"}`)))
	body := rec.Body.String()
	if rec.Header().Get("Content-Type") != "text/event-stream" {
		t.Errorf("content type %q", rec.Header().Get("Content-Type"))
	}
	last := -1
	for _, want := range []string{"event: turn", "event: tool", "event: step", "event: turn", "event: done", "Out of memory."} {
		i := strings.Index(body[last+1:], want)
		if i < 0 {
			t.Fatalf("missing %q in order:\n%s", want, body)
		}
		last += i + 1
	}
	if !strings.Contains(string(mustJSON(m.sent[0].Messages)), "Diagnose the pod crash-1 in the namespace shop.") {
		t.Errorf("prompt: %s", mustJSON(m.sent[0].Messages))
	}
}

func mustJSON(v any) []byte { b, _ := json.Marshal(v); return b }

func TestDiagnosisRequestsAreChecked(t *testing.T) {
	s := testServer(&scripted{})
	for body, want := range map[string]int{
		`{"namespace":"shop"}`:             0, // allowed; fails later only because the script is empty
		`{"namespace":"../x"}`:             http.StatusBadRequest,
		`{"namespace":"shop","pod":"A B"}`: http.StatusBadRequest,
		`{"namespace":"shop","question":"` + strings.Repeat("x", 1001) + `"}`: http.StatusBadRequest,
		`not json`: http.StatusBadRequest,
	} {
		rec := httptest.NewRecorder()
		s.handleDiagnose(rec, httptest.NewRequest("POST", "/api/diagnose", strings.NewReader(body)))
		if want != 0 && rec.Code != want {
			t.Errorf("%s: status %d, want %d", body, rec.Code, want)
		}
	}
	// The two-per-hour limit: one was used above, so the next fills it and the one after is refused.
	rec := httptest.NewRecorder()
	s.handleDiagnose(rec, httptest.NewRequest("POST", "/api/diagnose", strings.NewReader(`{"namespace":"shop"}`)))
	rec = httptest.NewRecorder()
	s.handleDiagnose(rec, httptest.NewRequest("POST", "/api/diagnose", strings.NewReader(`{"namespace":"shop"}`)))
	if rec.Code != http.StatusTooManyRequests {
		t.Errorf("limit not enforced: %d", rec.Code)
	}
}

func TestCacheReusesValues(t *testing.T) {
	c := cache[int]{ttl: time.Hour}
	calls := 0
	for range 3 {
		v, _ := c.get(func() (int, error) { calls++; return 7, nil })
		if v != 7 {
			t.Fatal(v)
		}
	}
	if calls != 1 {
		t.Errorf("loaded %d times", calls)
	}
}

// The page reads .length on every list, so each one must be present and an
// array, for a busy cluster and for an empty one.
func TestOverviewListsAreAlwaysArrays(t *testing.T) {
	busy, err := fakeCluster(t, true).Overview(context.Background(), now)
	if err != nil {
		t.Fatal(err)
	}
	quiet, err := (&Kube{base: emptyCluster(t), http: http.DefaultClient, token: func() string { return "" }}).Overview(context.Background(), now)
	if err != nil {
		t.Fatal(err)
	}
	for name, o := range map[string]*Overview{"busy": busy, "quiet": quiet} {
		b, _ := json.Marshal(o)
		var m struct {
			Nodes []map[string]any `json:"nodes"`
			Rest  map[string]any   `json:"-"`
		}
		var top map[string]any
		if err := json.Unmarshal(b, &top); err != nil {
			t.Fatal(err)
		}
		if err := json.Unmarshal(b, &m); err != nil {
			t.Fatal(err)
		}
		for _, key := range []string{"nodes", "namespaces", "problems", "apps", "events"} {
			if _, ok := top[key].([]any); !ok {
				t.Errorf("%s: %q is %T, not an array", name, key, top[key])
			}
		}
		for _, n := range m.Nodes {
			for _, key := range []string{"conditions", "roles"} {
				if _, ok := n[key].([]any); !ok {
					t.Errorf("%s: node %v has %q = %v, not an array", name, n["name"], key, n[key])
				}
			}
		}
	}
}

// emptyCluster serves a cluster with one healthy node and nothing running.
func emptyCluster(t *testing.T) string {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path == "/api/v1/nodes" {
			w.Write([]byte(`{"items":[{"metadata":{"name":"n1"},"status":{"allocatable":{"cpu":"2","memory":"4Gi","pods":"110"},"conditions":[{"type":"Ready","status":"True"}]}}]}`))
			return
		}
		w.Write([]byte(`{"items":[]}`))
	}))
	t.Cleanup(srv.Close)
	return srv.URL
}

func TestNamespaceEndpointRejectsBadNames(t *testing.T) {
	s := &server{kube: fakeCluster(t, true), log: slog.New(slog.NewTextHandler(io.Discard, nil))}
	mux := http.NewServeMux()
	mux.HandleFunc("GET /api/namespaces/{ns}", s.handleNamespace)
	for path, want := range map[string]int{
		"/api/namespaces/shop":     http.StatusOK,
		"/api/namespaces/Bad_Name": http.StatusBadRequest,
		"/api/namespaces/-x":       http.StatusBadRequest,
	} {
		rec := httptest.NewRecorder()
		mux.ServeHTTP(rec, httptest.NewRequest("GET", path, nil))
		if rec.Code != want {
			t.Errorf("%s: status %d, want %d", path, rec.Code, want)
		}
	}
}
