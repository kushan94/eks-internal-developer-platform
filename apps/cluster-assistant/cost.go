package main

import (
	"fmt"
	"os"
	"strconv"
	"sync"
	"time"
)

// price is dollars per million tokens. These are Anthropic's list prices as of
// 2026-10-06 for prompts up to 100K tokens; PRICE_INPUT_PER_MTOK and
// PRICE_OUTPUT_PER_MTOK override them when they change.
type price struct{ in, out float64 }

var prices = map[string]price{
	"claude-fable-5-1":  {10, 50},
	"claude-fable-5":    {10, 50},
	"claude-opus-5-5":   {4, 20},
	"claude-opus-5":     {5, 25},
	"claude-opus-4-8":   {5, 25},
	"claude-sonnet-5-5": {2, 10},
	"claude-sonnet-5":   {2, 10},
	"claude-haiku-5-5":  {0.10, 0.50},
}

// priceOf returns the price of a model. A model it doesn't know is priced at
// the most expensive one, so the spend cap errs towards stopping early, and
// known says the price was a guess.
func priceOf(model string) (p price, known bool) {
	in, errIn := strconv.ParseFloat(os.Getenv("PRICE_INPUT_PER_MTOK"), 64)
	out, errOut := strconv.ParseFloat(os.Getenv("PRICE_OUTPUT_PER_MTOK"), 64)
	if errIn == nil && errOut == nil {
		return price{in, out}, true
	}
	if p, ok := prices[model]; ok {
		return p, true
	}
	for _, p := range prices {
		if p.out > out || p.in > in {
			in, out = max(in, p.in), max(out, p.out)
		}
	}
	return price{in, out}, false
}

// costUSD estimates what a diagnosis cost from its token counts.
func costUSD(model string, inputTokens, outputTokens int64) (usd float64, known bool) {
	p, known := priceOf(model)
	return float64(inputTokens)/1e6*p.in + float64(outputTokens)/1e6*p.out, known
}

// spend adds up estimated spend per UTC day, to enforce a daily cap. It is
// kept in memory, so a restart starts the day at zero. Every diagnosis is also
// logged with its cost, which is where the real record is.
type spend struct {
	mu        sync.Mutex
	day       string
	usd       float64
	diagnoses int
	tokens    int64
}

func (s *spend) roll(now time.Time) {
	if d := now.UTC().Format("2006-01-02"); d != s.day {
		s.day, s.usd, s.diagnoses, s.tokens = d, 0, 0, 0
	}
}

func (s *spend) add(now time.Time, usd float64, tokens int64) {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.roll(now)
	s.usd += usd
	s.tokens += tokens
	s.diagnoses++
}

// over reports whether today's spend has reached the cap. A cap of zero or less means no cap.
func (s *spend) over(now time.Time, capUSD float64) bool {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.roll(now)
	return capUSD > 0 && s.usd >= capUSD
}

type Usage struct {
	Day         string  `json:"day"`
	SpentUSD    float64 `json:"spentUSD"`
	CapUSD      float64 `json:"capUSD"`
	Diagnoses   int     `json:"diagnoses"`
	Tokens      int64   `json:"tokens"`
	HourlyUsed  int     `json:"hourlyUsed"`
	HourlyLimit int     `json:"hourlyLimit"`
}

func (s *spend) snapshot(now time.Time) Usage {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.roll(now)
	return Usage{Day: s.day, SpentUSD: s.usd, Diagnoses: s.diagnoses, Tokens: s.tokens}
}

// diagnosisCache keeps recent answers, so the same question asked twice in a
// few minutes (a colleague opens the same alert) costs nothing the second time.
type diagnosisCache struct {
	mu      sync.Mutex
	ttl     time.Duration
	entries map[string]cachedResult
}

type cachedResult struct {
	result Result
	at     time.Time
}

const maxCachedDiagnoses = 100

func (c *diagnosisCache) get(key string, now time.Time) (Result, time.Time, bool) {
	c.mu.Lock()
	defer c.mu.Unlock()
	if c.ttl <= 0 {
		return Result{}, time.Time{}, false
	}
	e, ok := c.entries[key]
	if !ok || now.Sub(e.at) > c.ttl {
		delete(c.entries, key)
		return Result{}, time.Time{}, false
	}
	return e.result, e.at, true
}

func (c *diagnosisCache) put(key string, r Result, now time.Time) {
	c.mu.Lock()
	defer c.mu.Unlock()
	if c.ttl <= 0 {
		return
	}
	if c.entries == nil {
		c.entries = map[string]cachedResult{}
	}
	if len(c.entries) >= maxCachedDiagnoses {
		oldest, first := "", true
		var at time.Time
		for k, e := range c.entries {
			if first || e.at.Before(at) {
				oldest, at, first = k, e.at, false
			}
		}
		delete(c.entries, oldest)
	}
	c.entries[key] = cachedResult{r, now}
}

func cacheKey(req diagnoseRequest) string {
	return fmt.Sprintf("%s\x00%s\x00%s\x00%s", req.Namespace, req.Service, req.Pod, req.Question)
}
