// cluster-assistant is a dashboard for the cluster, with an assistant that
// diagnoses problems. The dashboard shows nodes, namespaces, problems, Argo CD
// apps and charts. The assistant is a model that investigates with read-only
// tools: pods, events, logs, objects and metrics. Nothing here can change the
// cluster.
package main

import (
	"context"
	"embed"
	"encoding/json"
	"fmt"
	"io/fs"
	"log"
	"log/slog"
	"net/http"
	"os"
	"strconv"
	"sync"
	"time"

	"github.com/anthropics/anthropic-sdk-go"
)

//go:embed web
var webFiles embed.FS

func env(key, fallback string) string {
	if v := os.Getenv(key); v != "" {
		return v
	}
	return fallback
}

// limiter allows a fixed number of diagnoses per hour, as a spending cap.
type limiter struct {
	mu    sync.Mutex
	max   int
	count int
	reset time.Time
}

func (l *limiter) allow(now time.Time) bool {
	l.mu.Lock()
	defer l.mu.Unlock()
	if now.After(l.reset) {
		l.count, l.reset = 0, now.Add(time.Hour)
	}
	if l.count >= l.max {
		return false
	}
	l.count++
	return true
}

// cache keeps a computed value for a few seconds, so many open dashboards
// cost the API server one read.
type cache[T any] struct {
	mu    sync.Mutex
	ttl   time.Duration
	at    time.Time
	value T
}

func (c *cache[T]) get(load func() (T, error)) (T, error) {
	c.mu.Lock()
	defer c.mu.Unlock()
	if !c.at.IsZero() && time.Since(c.at) < c.ttl {
		return c.value, nil
	}
	v, err := load()
	if err != nil {
		var zero T
		return zero, err
	}
	c.value, c.at = v, time.Now()
	return v, nil
}

type server struct {
	kube     *Kube
	prom     *Prometheus
	agent    *Agent
	limit    *limiter
	log      *slog.Logger
	overview cache[*Overview]
	charts   cache[Charts]
	pods     cache[*PodList]
	events   cache[*EventList]
}

type diagnoseRequest struct {
	Namespace string `json:"namespace"`
	Service   string `json:"service"`
	Pod       string `json:"pod"`
	Question  string `json:"question"`
}

func writeJSON(w http.ResponseWriter, v any) {
	w.Header().Set("Content-Type", "application/json")
	w.Header().Set("Cache-Control", "no-store")
	json.NewEncoder(w).Encode(v)
}

func (s *server) handleOverview(w http.ResponseWriter, r *http.Request) {
	o, err := s.overview.get(func() (*Overview, error) { return s.kube.Overview(r.Context(), time.Now()) })
	if err != nil {
		s.log.Error("overview", "error", err.Error())
		http.Error(w, "couldn't read the cluster: "+err.Error(), http.StatusBadGateway)
		return
	}
	writeJSON(w, o)
}

func (s *server) handleNamespace(w http.ResponseWriter, r *http.Request) {
	if !validName(r.PathValue("ns")) {
		http.Error(w, "not a valid namespace name", http.StatusBadRequest)
		return
	}
	d, err := s.kube.NamespaceDetail(r.Context(), r.PathValue("ns"), time.Now())
	if err != nil {
		http.Error(w, err.Error(), http.StatusBadGateway)
		return
	}
	writeJSON(w, d)
}

func (s *server) handlePods(w http.ResponseWriter, r *http.Request) {
	l, err := s.pods.get(func() (*PodList, error) { return s.kube.AllPods(r.Context(), time.Now()) })
	if err != nil {
		http.Error(w, "couldn't read the pods: "+err.Error(), http.StatusBadGateway)
		return
	}
	writeJSON(w, l)
}

func (s *server) handleEvents(w http.ResponseWriter, r *http.Request) {
	l, err := s.events.get(func() (*EventList, error) { return s.kube.WarningEvents(r.Context()) })
	if err != nil {
		http.Error(w, "couldn't read the events: "+err.Error(), http.StatusBadGateway)
		return
	}
	writeJSON(w, l)
}

func (s *server) handleCharts(w http.ResponseWriter, r *http.Request) {
	c, _ := s.charts.get(func() (Charts, error) { return s.prom.Charts(r.Context(), time.Now()), nil })
	writeJSON(w, c)
}

// prepare checks a diagnosis request and turns it into the prompt.
func (s *server) prepare(w http.ResponseWriter, r *http.Request) (diagnoseRequest, string, bool) {
	var req diagnoseRequest
	if err := json.NewDecoder(http.MaxBytesReader(w, r.Body, 8<<10)).Decode(&req); err != nil {
		http.Error(w, "bad request", http.StatusBadRequest)
		return req, "", false
	}
	if !validName(req.Namespace) || (req.Service != "" && !validName(req.Service)) || (req.Pod != "" && !validName(req.Pod)) || len(req.Question) > 1000 {
		http.Error(w, "namespace, service and pod must be Kubernetes names, and the question under 1000 characters", http.StatusBadRequest)
		return req, "", false
	}
	if !s.limit.allow(time.Now()) {
		http.Error(w, "hourly diagnosis limit reached", http.StatusTooManyRequests)
		return req, "", false
	}
	prompt := "Diagnose the namespace " + req.Namespace + "."
	switch {
	case req.Pod != "":
		prompt = "Diagnose the pod " + req.Pod + " in the namespace " + req.Namespace + "."
	case req.Service != "":
		prompt = "Diagnose the service " + req.Service + " in the namespace " + req.Namespace + "."
	}
	if req.Question != "" {
		prompt += " The engineer says: " + req.Question
	}
	return req, prompt, true
}

func (s *server) audit(req diagnoseRequest, res Result, err error, start time.Time) {
	s.log.Info("diagnosis", "namespace", req.Namespace, "service", req.Service, "pod", req.Pod, "question", req.Question,
		"steps", len(res.Steps), "inputTokens", res.InputTokens, "outputTokens", res.OutputTokens,
		"stopped", res.Stopped, "seconds", int(time.Since(start).Seconds()), "error", fmt.Sprint(err))
}

func (s *server) handleDiagnose(w http.ResponseWriter, r *http.Request) {
	req, prompt, ok := s.prepare(w, r)
	if !ok {
		return
	}
	ctx, cancel := context.WithTimeout(r.Context(), 4*time.Minute)
	defer cancel()
	start := time.Now()
	res, err := s.agent.Run(ctx, prompt)
	s.audit(req, res, err, start)
	if err != nil {
		http.Error(w, "the diagnosis failed: "+err.Error(), http.StatusBadGateway)
		return
	}
	writeJSON(w, res)
}

// handleDiagnoseStream is handleDiagnose as server-sent events, so the page
// can show each step as it happens.
func (s *server) handleDiagnoseStream(w http.ResponseWriter, r *http.Request) {
	req, prompt, ok := s.prepare(w, r)
	if !ok {
		return
	}
	flusher, ok := w.(http.Flusher)
	if !ok {
		http.Error(w, "streaming isn't supported", http.StatusInternalServerError)
		return
	}
	w.Header().Set("Content-Type", "text/event-stream")
	w.Header().Set("Cache-Control", "no-store")
	w.Header().Set("X-Accel-Buffering", "no")
	var mu sync.Mutex
	send := func(kind string, data any) {
		b, _ := json.Marshal(data)
		mu.Lock()
		defer mu.Unlock()
		fmt.Fprintf(w, "event: %s\ndata: %s\n\n", kind, b)
		flusher.Flush()
	}
	ctx, cancel := context.WithTimeout(r.Context(), 4*time.Minute)
	defer cancel()
	start := time.Now()
	res, err := s.agent.RunWith(ctx, prompt, send)
	s.audit(req, res, err, start)
	if err != nil {
		send("failed", map[string]string{"error": "the diagnosis failed: " + err.Error()})
		return
	}
	send("done", res)
}

func main() {
	logger := slog.New(slog.NewJSONHandler(os.Stdout, nil))
	kube, err := NewKube()
	if err != nil {
		log.Fatal(err)
	}
	if len(os.Args) > 2 && os.Args[1] == "evidence" {
		evidence(context.Background(), kube, os.Args[2])
		return
	}
	prom := &Prometheus{base: os.Getenv("PROMETHEUS_URL"), http: &http.Client{Timeout: 20 * time.Second}}
	perHour, _ := strconv.Atoi(env("MAX_DIAGNOSES_PER_HOUR", "30"))
	s := &server{
		kube: kube,
		prom: prom,
		agent: &Agent{
			Model:     env("MODEL", "claude-opus-5-5"),
			Client:    sdkMessenger{anthropic.NewClient()}, // ANTHROPIC_API_KEY
			Tools:     BuildTools(kube, prom),
			MaxTurns:  12,
			MaxTokens: 8000,
			Log:       logger,
		},
		limit:    &limiter{max: perHour},
		log:      logger,
		overview: cache[*Overview]{ttl: 5 * time.Second},
		charts:   cache[Charts]{ttl: 30 * time.Second},
		pods:     cache[*PodList]{ttl: 5 * time.Second},
		events:   cache[*EventList]{ttl: 5 * time.Second},
	}
	site, _ := fs.Sub(webFiles, "web")
	mux := http.NewServeMux()
	mux.HandleFunc("GET /api/overview", s.handleOverview)
	mux.HandleFunc("GET /api/namespaces/{ns}", s.handleNamespace)
	mux.HandleFunc("GET /api/pods", s.handlePods)
	mux.HandleFunc("GET /api/events", s.handleEvents)
	mux.HandleFunc("GET /api/charts", s.handleCharts)
	mux.HandleFunc("POST /api/diagnose", s.handleDiagnose)
	mux.HandleFunc("POST /api/diagnose/stream", s.handleDiagnoseStream)
	mux.HandleFunc("GET /healthz", func(w http.ResponseWriter, _ *http.Request) { w.Write([]byte("ok")) })
	mux.Handle("GET /", http.FileServerFS(site))
	addr := env("ADDR", ":8080")
	logger.Info("listening", "addr", addr, "model", s.agent.Model)
	log.Fatal((&http.Server{Addr: addr, Handler: securityHeaders(mux), ReadHeaderTimeout: 10 * time.Second}).ListenAndServe())
}

// The page loads only its own files, and nothing it shows can run as script:
// cluster data is untrusted text.
func securityHeaders(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		h := w.Header()
		h.Set("Content-Security-Policy", "default-src 'none'; script-src 'self'; style-src 'self'; connect-src 'self'; img-src 'self' data:; base-uri 'none'; form-action 'none'; frame-ancestors 'none'")
		h.Set("X-Content-Type-Options", "nosniff")
		h.Set("Referrer-Policy", "no-referrer")
		next.ServeHTTP(w, r)
	})
}

// evidence prints what the assistant's tools see for a namespace, without a
// model. The fault tests use it to check the evidence is there, and an
// engineer can use it to see what the model would be shown.
func evidence(ctx context.Context, k *Kube, namespace string) {
	show := func(title string, out string, err error) {
		if err != nil {
			out = "Error: " + err.Error()
		}
		fmt.Printf("== %s\n%s\n", title, redact(out))
	}
	pods, err := k.Pods(ctx, namespace, "", time.Now())
	show("pods", pods, err)
	events, err := k.Events(ctx, namespace, "")
	show("events", events, err)
	for _, name := range k.PodNames(ctx, namespace) {
		for _, previous := range []bool{false, true} {
			logs, err := k.Logs(ctx, namespace, name, "", previous, 50)
			show(fmt.Sprintf("logs %s previous=%t", name, previous), logs, err)
		}
	}
}
