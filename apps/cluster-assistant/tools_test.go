package main

import (
	"context"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync/atomic"
	"testing"
	"time"
)

const crashingPods = `{"items":[{
 "metadata":{"name":"visits-abc","creationTimestamp":"2026-11-14T10:00:00Z"},
 "spec":{"nodeName":"ip-10-0-1-5"},
 "status":{"phase":"Running",
  "conditions":[{"type":"Ready","status":"False","reason":"ContainersNotReady","message":"containers with unready status: [app]"}],
  "containerStatuses":[{"name":"app","ready":false,"restartCount":7,
   "state":{"waiting":{"reason":"CrashLoopBackOff","message":"back-off 5m0s restarting failed container"}},
   "lastState":{"terminated":{"reason":"OOMKilled","exitCode":137}}}]}}]}`

func fakeKube(t *testing.T, hits *atomic.Int32) *Kube {
	t.Helper()
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		hits.Add(1)
		switch r.URL.Path {
		case "/api/v1/namespaces/demo-dev/pods":
			w.Write([]byte(crashingPods))
		case "/api/v1/namespaces/demo-dev/events":
			w.Write([]byte(`{"items":[
			 {"type":"Warning","reason":"BackOff","message":"Back-off restarting failed container","count":12,"lastTimestamp":"2026-11-14T10:05:00Z","involvedObject":{"kind":"Pod","name":"visits-abc"}},
			 {"type":"Normal","reason":"Pulled","message":"Image pulled","count":1,"lastTimestamp":"2026-11-14T10:01:00Z","involvedObject":{"kind":"Pod","name":"visits-abc"}}]}`))
		case "/apis/apps/v1/namespaces/demo-dev/deployments/visits":
			w.Write([]byte(`{"metadata":{"name":"visits","managedFields":[{"manager":"x"}],"annotations":{"kubectl.kubernetes.io/last-applied-configuration":"{}"}},"status":{"unavailableReplicas":1}}`))
		case "/api/v1/namespaces/demo-dev/pods/visits-abc/log":
			w.Write([]byte("connecting with postgres://app:hunter2@db:5432/app\npanic: out of memory\n"))
		default:
			http.NotFound(w, r)
		}
	}))
	t.Cleanup(srv.Close)
	return &Kube{base: srv.URL, http: srv.Client(), token: func() string { return "" }}
}

func TestPodsExplainWhyContainersAreNotRunning(t *testing.T) {
	var hits atomic.Int32
	k := fakeKube(t, &hits)
	out, err := k.Pods(context.Background(), "demo-dev", "", time.Date(2026, 11, 14, 10, 10, 0, 0, time.UTC))
	if err != nil {
		t.Fatal(err)
	}
	for _, want := range []string{"CrashLoopBackOff", "OOMKilled", "exit code 137", "restarts=7", "ContainersNotReady", "age 10m0s"} {
		if !strings.Contains(out, want) {
			t.Errorf("pods summary is missing %q:\n%s", want, out)
		}
	}
}

func TestEventsAreNewestFirst(t *testing.T) {
	var hits atomic.Int32
	out, err := fakeKube(t, &hits).Events(context.Background(), "demo-dev", "")
	if err != nil {
		t.Fatal(err)
	}
	if strings.Index(out, "BackOff") > strings.Index(out, "Pulled") {
		t.Errorf("events are not newest first:\n%s", out)
	}
}

func TestResourceStripsNoise(t *testing.T) {
	var hits atomic.Int32
	out, err := fakeKube(t, &hits).Resource(context.Background(), "deployments", "demo-dev", "visits", "")
	if err != nil {
		t.Fatal(err)
	}
	if strings.Contains(out, "managedFields") || strings.Contains(out, "last-applied") || !strings.Contains(out, "unavailableReplicas") {
		t.Errorf("unexpected output:\n%s", out)
	}
}

// Secrets can't be read, and bad names never reach the API server.
func TestResourceRefusesWhatItShouldNot(t *testing.T) {
	var hits atomic.Int32
	k := fakeKube(t, &hits)
	for _, c := range []struct{ kind, ns, name string }{
		{"secrets", "demo-dev", "db"},
		{"configmaps", "demo-dev", ""},
		{"pods", "demo-dev/../kube-system", ""},
		{"pods", "demo-dev", "x?watch=true"},
		{"deployments", "", "visits"},
		{"pods", "Demo", ""},
	} {
		if _, err := k.Resource(context.Background(), c.kind, c.ns, c.name, ""); err == nil {
			t.Errorf("%+v was allowed", c)
		}
	}
	if hits.Load() != 0 {
		t.Errorf("%d refused requests reached the API server", hits.Load())
	}
}

func TestApplicationsAreAlwaysInTheArgoCDNamespace(t *testing.T) {
	var got string
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) { got = r.URL.Path; w.Write([]byte(`{}`)) }))
	defer srv.Close()
	k := &Kube{base: srv.URL, http: srv.Client(), token: func() string { return "" }}
	if _, err := k.Resource(context.Background(), "applications", "kube-system", "visits", ""); err != nil {
		t.Fatal(err)
	}
	if want := "/apis/argoproj.io/v1alpha1/namespaces/argocd/applications/visits"; got != want {
		t.Errorf("path = %s, want %s", got, want)
	}
}

func TestRedact(t *testing.T) {
	for in, leak := range map[string]string{
		"dial postgres://app:hunter2@db:5432/app":                                          "hunter2",
		"password=hunter2 other":                                                           "hunter2",
		`{"token": "abc123secret"}`:                                                        "abc123secret",
		"key AKIAIOSFODNN7EXAMPLE used":                                                    "AKIAIOSFODNN7EXAMPLE",
		"Authorization: Bearer abcdefghijklmnopqrstuv":                                     "abcdefghijklmnopqrstuv",
		"ghp_abcdefghijklmnopqrstuvwxyz0123456789":                                         "abcdefghijklmnopqrstuvwxyz",
		"eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxMjM0NTY3ODkw.SflKxwRJSMeKKF2QT4fwpMeJf36POk6yJV": "SflKxwRJSMeKKF2QT4",
	} {
		if out := redact(in); strings.Contains(out, leak) {
			t.Errorf("redact(%q) = %q still has %q", in, out, leak)
		}
	}
	if out := redact("back-off restarting failed container"); out != "back-off restarting failed container" {
		t.Errorf("redact changed a plain message: %q", out)
	}
}

func TestTruncate(t *testing.T) {
	out := truncate(strings.Repeat("a", maxResultBytes+50))
	if !strings.HasSuffix(out, "[truncated 50 more bytes]") {
		t.Errorf("unexpected suffix: %q", out[len(out)-40:])
	}
}
