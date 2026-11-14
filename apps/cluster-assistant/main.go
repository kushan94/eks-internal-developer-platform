// cluster-assistant diagnoses problems on the cluster. An engineer names a
// namespace and a service, and a model investigates with read-only tools:
// pods, events, logs, objects and metrics. It can't change anything.
package main

import (
	"context"
	_ "embed"
	"encoding/json"
	"fmt"
	"log"
	"log/slog"
	"net/http"
	"os"
	"strconv"
	"sync"
	"time"

	"github.com/anthropics/anthropic-sdk-go"
)

//go:embed index.html
var indexHTML []byte

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

type server struct {
	agent *Agent
	limit *limiter
	log   *slog.Logger
}

type diagnoseRequest struct {
	Namespace string `json:"namespace"`
	Service   string `json:"service"`
	Question  string `json:"question"`
}

func (s *server) diagnose(w http.ResponseWriter, r *http.Request) {
	var req diagnoseRequest
	if err := json.NewDecoder(http.MaxBytesReader(w, r.Body, 8<<10)).Decode(&req); err != nil {
		http.Error(w, "bad request", http.StatusBadRequest)
		return
	}
	if !validName(req.Namespace) || (req.Service != "" && !validName(req.Service)) || len(req.Question) > 1000 {
		http.Error(w, "namespace and service must be Kubernetes names, and the question under 1000 characters", http.StatusBadRequest)
		return
	}
	if !s.limit.allow(time.Now()) {
		http.Error(w, "hourly diagnosis limit reached", http.StatusTooManyRequests)
		return
	}
	prompt := "Diagnose the namespace " + req.Namespace + "."
	if req.Service != "" {
		prompt = "Diagnose the service " + req.Service + " in the namespace " + req.Namespace + "."
	}
	if req.Question != "" {
		prompt += " The engineer says: " + req.Question
	}
	ctx, cancel := context.WithTimeout(r.Context(), 4*time.Minute)
	defer cancel()
	start := time.Now()
	res, err := s.agent.Run(ctx, prompt)
	s.log.Info("diagnosis", "namespace", req.Namespace, "service", req.Service, "question", req.Question,
		"steps", len(res.Steps), "inputTokens", res.InputTokens, "outputTokens", res.OutputTokens,
		"stopped", res.Stopped, "seconds", int(time.Since(start).Seconds()), "error", fmt.Sprint(err))
	if err != nil {
		http.Error(w, "the diagnosis failed: "+err.Error(), http.StatusBadGateway)
		return
	}
	w.Header().Set("Content-Type", "application/json")
	json.NewEncoder(w).Encode(res)
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
		agent: &Agent{
			Model:     env("MODEL", "claude-opus-5-5"),
			Client:    sdkMessenger{anthropic.NewClient()}, // ANTHROPIC_API_KEY
			Tools:     BuildTools(kube, prom),
			MaxTurns:  12,
			MaxTokens: 8000,
			Log:       logger,
		},
		limit: &limiter{max: perHour},
		log:   logger,
	}
	mux := http.NewServeMux()
	mux.HandleFunc("POST /api/diagnose", s.diagnose)
	mux.HandleFunc("GET /healthz", func(w http.ResponseWriter, _ *http.Request) { w.Write([]byte("ok")) })
	mux.HandleFunc("GET /{$}", func(w http.ResponseWriter, _ *http.Request) {
		w.Header().Set("Content-Type", "text/html; charset=utf-8")
		w.Write(indexHTML)
	})
	addr := env("ADDR", ":8080")
	logger.Info("listening", "addr", addr, "model", s.agent.Model)
	log.Fatal((&http.Server{Addr: addr, Handler: mux, ReadHeaderTimeout: 10 * time.Second}).ListenAndServe())
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
