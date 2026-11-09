// visits is the platform's database demo. Every page view adds a row to
// Postgres and shows how many there are, and which database holds them.
//
// It connects with DATABASE_URL when it is set (Kubernetes), and otherwise
// with the standard PG* variables (ECS), as the WebService API provides.
package main

import (
	"context"
	"fmt"
	"html/template"
	"log"
	"net/http"
	"os"
	"time"

	"github.com/jackc/pgx/v5/pgxpool"
	"github.com/prometheus/client_golang/prometheus"
	"github.com/prometheus/client_golang/prometheus/promauto"
	"github.com/prometheus/client_golang/prometheus/promhttp"
)

// Served at /metrics for Prometheus, which the WebService's metrics field turns on.
var (
	pageViews = promauto.NewCounterVec(prometheus.CounterOpts{
		Name: "visits_page_views_total",
		Help: "Page views, by whether the database answered.",
	}, []string{"result"})
	queryDuration = promauto.NewHistogram(prometheus.HistogramOpts{
		Name:    "visits_database_query_duration_seconds",
		Help:    "Time to record a visit and read the count.",
		Buckets: prometheus.ExponentialBuckets(0.001, 2, 12),
	})
)

var page = template.Must(template.New("page").Parse(`<!doctype html>
<html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1">
<title>Visits</title>
<style>
body{font-family:system-ui,sans-serif;max-width:40rem;margin:3rem auto;padding:0 1rem;color:#1f2328;background:#fff}
@media (prefers-color-scheme:dark){body{color:#e6edf3;background:#0d1117}td{border-color:#30363d}}
h1{font-size:3rem;margin:0}td{padding:.3rem 1rem .3rem 0;border-bottom:1px solid #d0d7de}
</style></head><body>
<p>Visit number</p><h1>{{.Count}}</h1>
<p>Stored in Postgres through the platform's <code>WebService</code> database.</p>
<table>
<tr><td>Database</td><td><code>{{.Database}}</code></td></tr>
<tr><td>Login</td><td><code>{{.User}}</code></td></tr>
<tr><td>Server</td><td><code>{{.Server}}</code></td></tr>
<tr><td>Postgres</td><td>{{.Version}}</td></tr>
<tr><td>Encrypted</td><td>{{.SSL}}</td></tr>
</table></body></html>`))

type info struct {
	Count                           int64
	Database, User, Server, Version string
	SSL                             bool
}

func main() {
	ctx := context.Background()
	// An empty connection string makes pgx read the PG* variables.
	pool, err := pgxpool.New(ctx, os.Getenv("DATABASE_URL"))
	if err != nil {
		log.Fatalf("invalid database settings: %v", err)
	}
	defer pool.Close()

	// The database can appear a little after the app, so keep trying.
	for {
		_, err = pool.Exec(ctx, `CREATE TABLE IF NOT EXISTS visits (id bigserial PRIMARY KEY, at timestamptz NOT NULL DEFAULT now())`)
		if err == nil {
			break
		}
		log.Printf("waiting for the database: %v", err)
		time.Sleep(5 * time.Second)
	}
	log.Print("connected to the database")

	http.HandleFunc("GET /healthz", func(w http.ResponseWriter, r *http.Request) {
		fmt.Fprintln(w, "ok")
	})
	http.Handle("GET /metrics", promhttp.Handler())
	http.HandleFunc("GET /{$}", func(w http.ResponseWriter, r *http.Request) {
		var i info
		start := time.Now()
		err := pool.QueryRow(r.Context(), `
			WITH added AS (INSERT INTO visits DEFAULT VALUES RETURNING id)
			SELECT (SELECT count(*) FROM visits) + 1, current_database(), current_user,
			       coalesce(host(inet_server_addr()), 'local socket'), current_setting('server_version'),
			       coalesce((SELECT ssl FROM pg_stat_ssl WHERE pid = pg_backend_pid()), false)
			FROM added`).Scan(&i.Count, &i.Database, &i.User, &i.Server, &i.Version, &i.SSL)
		queryDuration.Observe(time.Since(start).Seconds())
		if err != nil {
			pageViews.WithLabelValues("error").Inc()
			log.Printf("query failed: %v", err)
			http.Error(w, "database unavailable", http.StatusServiceUnavailable)
			return
		}
		pageViews.WithLabelValues("ok").Inc()
		w.Header().Set("Content-Type", "text/html; charset=utf-8")
		page.Execute(w, i)
	})

	addr := ":" + envOr("PORT", "8080")
	log.Printf("listening on %s", addr)
	log.Fatal(http.ListenAndServe(addr, nil))
}

func envOr(key, fallback string) string {
	if v := os.Getenv(key); v != "" {
		return v
	}
	return fallback
}
