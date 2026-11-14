package main

import (
	"context"
	"encoding/json"
	"errors"
	"math"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/anthropics/anthropic-sdk-go"
)

func sentJSON(m *scripted, i int) string { b, _ := json.Marshal(m.sent[i]); return string(b) }

func toolsForbidden(m *scripted, i int) bool {
	return strings.Contains(sentJSON(m, i), `"tool_choice":{"type":"none"}`)
}

func calls(n int, tool string) []string {
	r := make([]string, n)
	for i := range r {
		r[i] = reply("tool_use", `[`+toolUse("t", tool, `{}`)+`]`)
	}
	return r
}

// When the turns run out, the assistant is told to answer from what it has,
// instead of being cut off with nothing.
func TestLastTurnIsAWrapUpThatProducesAnAnswer(t *testing.T) {
	m := &scripted{replies: append(calls(3, "list_pods"), reply("end_turn", `[{"type":"text","text":"Probably OOM; I couldn't read the logs."}]`))}
	res, err := agentWith(m, echo("list_pods", "x", nil)).Run(context.Background(), "x") // 4 turns
	if err != nil {
		t.Fatal(err)
	}
	if res.Answer != "Probably OOM; I couldn't read the logs." || res.Stopped != "max_turns" || len(res.Steps) != 3 || len(m.sent) != 4 {
		t.Fatalf("res=%+v after %d calls", res, len(m.sent))
	}
	for i := 0; i < 3; i++ {
		if toolsForbidden(m, i) {
			t.Errorf("call %d had tools forbidden too early", i)
		}
	}
	if !toolsForbidden(m, 3) || !strings.Contains(sentJSON(m, 3), "almost out of budget") {
		t.Errorf("the last call wasn't a wrap-up: %s", sentJSON(m, 3))
	}
}

func TestTokenBudgetTriggersAWrapUp(t *testing.T) {
	// Each call uses 120 tokens. Of a budget of 300, 70% is 210, which the second call passes.
	m := &scripted{replies: append(calls(2, "list_pods"), reply("end_turn", `[{"type":"text","text":"Best guess."}]`))}
	a := agentWith(m, echo("list_pods", "x", nil))
	a.MaxTotalTokens = 300
	a.MaxTurns = 10
	res, err := a.Run(context.Background(), "x")
	if err != nil {
		t.Fatal(err)
	}
	if res.Stopped != "budget" || res.Answer != "Best guess." || len(m.sent) != 3 {
		t.Fatalf("res=%+v after %d calls", res, len(m.sent))
	}
	if toolsForbidden(m, 1) || !toolsForbidden(m, 2) || strings.Count(sentJSON(m, 2), "almost out of budget") != 1 {
		t.Errorf("wrap-up on the wrong call: %s", sentJSON(m, 2))
	}
}

func TestNoBudgetMeansNoWrapUpUntilTheLastTurn(t *testing.T) {
	m := &scripted{replies: append(calls(2, "list_pods"), reply("end_turn", `[{"type":"text","text":"done"}]`))}
	a := agentWith(m, echo("list_pods", "x", nil))
	a.MaxTurns = 10
	res, _ := a.Run(context.Background(), "x")
	if res.Stopped != "" || toolsForbidden(m, 2) {
		t.Errorf("stopped=%q, tools forbidden=%t", res.Stopped, toolsForbidden(m, 2))
	}
}

// A model that asks for a tool anyway during the wrap-up doesn't get it.
func TestToolsAreNotRunDuringTheWrapUp(t *testing.T) {
	ran := 0
	tool := Tool{Name: "list_pods", Run: func(context.Context, json.RawMessage) (string, error) { ran++; return "x", nil }}
	m := &scripted{replies: calls(4, "list_pods")}
	res, _ := agentWith(m, tool).Run(context.Background(), "x")
	if ran != 3 || len(res.Steps) != 3 || res.Stopped != "max_turns" {
		t.Errorf("ran %d, steps %d, stopped %q", ran, len(res.Steps), res.Stopped)
	}
}

func TestResultsCarryTheEstimatedCost(t *testing.T) {
	m := &scripted{replies: []string{reply("end_turn", `[{"type":"text","text":"ok"}]`)}}
	a := agentWith(m)
	a.Model = "claude-opus-5-5"
	res, _ := a.Run(context.Background(), "x") // 100 in, 20 out
	want := 100.0/1e6*4 + 20.0/1e6*20
	if !res.CostKnown || math.Abs(res.CostUSD-want) > 1e-12 {
		t.Errorf("cost %v known=%t, want %v", res.CostUSD, res.CostKnown, want)
	}
}

func TestPricing(t *testing.T) {
	if c, known := costUSD("claude-sonnet-5-5", 1_000_000, 1_000_000); !known || c != 12 {
		t.Errorf("sonnet: %v %t", c, known)
	}
	// A model it doesn't know is priced as the most expensive, and flagged.
	c, known := costUSD("claude-mystery-9", 1_000_000, 1_000_000)
	if known || c != 60 {
		t.Errorf("unknown model: %v %t", c, known)
	}
	t.Setenv("PRICE_INPUT_PER_MTOK", "1")
	t.Setenv("PRICE_OUTPUT_PER_MTOK", "2")
	if c, known := costUSD("claude-mystery-9", 1_000_000, 1_000_000); !known || c != 3 {
		t.Errorf("override: %v %t", c, known)
	}
}

func TestSpendResetsEachUTCDay(t *testing.T) {
	var s spend
	day1 := time.Date(2026, 11, 14, 23, 59, 0, 0, time.UTC)
	s.add(day1, 4, 1000)
	s.add(day1, 2, 500)
	if !s.over(day1, 5) || s.over(day1, 7) || s.over(day1, 0) {
		t.Error("over() is wrong at $6 against caps of 5, 7 and none")
	}
	if u := s.snapshot(day1); u.SpentUSD != 6 || u.Diagnoses != 2 || u.Tokens != 1500 || u.Day != "2026-11-14" {
		t.Errorf("snapshot: %+v", u)
	}
	day2 := day1.Add(2 * time.Minute)
	if s.over(day2, 5) || s.snapshot(day2).SpentUSD != 0 {
		t.Error("spend didn't reset at midnight UTC")
	}
}

func TestACacheWithNoTTLIsOff(t *testing.T) {
	c := diagnosisCache{}
	now := time.Now()
	c.put("a", Result{Answer: "A"}, now)
	if _, _, ok := c.get("a", now); ok || len(c.entries) != 0 {
		t.Error("a cache with no TTL kept an entry")
	}
}

func TestDiagnosisCacheExpiresAndIsBounded(t *testing.T) {
	c := diagnosisCache{ttl: time.Minute}
	t0 := time.Date(2026, 11, 14, 12, 0, 0, 0, time.UTC)
	c.put("a", Result{Answer: "A"}, t0)
	if r, _, ok := c.get("a", t0.Add(30*time.Second)); !ok || r.Answer != "A" {
		t.Error("a fresh entry wasn't found")
	}
	if _, _, ok := c.get("a", t0.Add(2*time.Minute)); ok {
		t.Error("an expired entry was returned")
	}
	for i := 0; i < maxCachedDiagnoses+10; i++ {
		c.put(string(rune('A'+i%26))+strings.Repeat("x", i), Result{}, t0.Add(time.Duration(i)*time.Second))
	}
	if len(c.entries) > maxCachedDiagnoses {
		t.Errorf("%d entries", len(c.entries))
	}
}

func post(s *server, handler func(http.ResponseWriter, *http.Request), body string) *httptest.ResponseRecorder {
	rec := httptest.NewRecorder()
	handler(rec, httptest.NewRequest("POST", "/api/diagnose", strings.NewReader(body)))
	return rec
}

func TestDailySpendCapStopsNewDiagnoses(t *testing.T) {
	m := &scripted{replies: []string{reply("end_turn", `[{"type":"text","text":"one"}]`), reply("end_turn", `[{"type":"text","text":"two"}]`)}}
	s := testServer(m)
	s.limit.max = 100
	one, _ := costUSD("m", 100, 20)
	s.dailyCap = one * 1.5 // the first diagnosis fits, and the second can't start after it
	if rec := post(s, s.handleDiagnose, `{"namespace":"a","question":"1"}`); rec.Code != 200 {
		t.Fatalf("first: %d %s", rec.Code, rec.Body)
	}
	if rec := post(s, s.handleDiagnose, `{"namespace":"a","question":"2"}`); rec.Code != 200 {
		t.Fatalf("second should still start while spend is under the cap: %d", rec.Code)
	}
	rec := post(s, s.handleDiagnose, `{"namespace":"a","question":"3"}`)
	if rec.Code != http.StatusTooManyRequests || !strings.Contains(rec.Body.String(), "daily spend cap") {
		t.Errorf("third: %d %s", rec.Code, rec.Body)
	}
	if len(m.sent) != 2 {
		t.Errorf("the model was called %d times", len(m.sent))
	}
}

type blocking struct {
	started chan struct{}
	release chan struct{}
}

func (b blocking) New(ctx context.Context, p anthropic.MessageNewParams) (*anthropic.Message, error) {
	b.started <- struct{}{}
	<-b.release
	var m anthropic.Message
	err := json.Unmarshal([]byte(reply("end_turn", `[{"type":"text","text":"ok"}]`)), &m)
	return &m, err
}

func TestConcurrencyLimitAndTheHourlyAllowance(t *testing.T) {
	b := blocking{make(chan struct{}, 1), make(chan struct{})}
	s := testServer(b)
	s.limit.max = 10
	s.sem = make(chan struct{}, 1)
	var wg sync.WaitGroup
	wg.Add(1)
	go func() { defer wg.Done(); post(s, s.handleDiagnose, `{"namespace":"a","question":"first"}`) }()
	<-b.started // the first diagnosis is running
	rec := post(s, s.handleDiagnose, `{"namespace":"a","question":"second"}`)
	if rec.Code != http.StatusTooManyRequests || !strings.Contains(rec.Body.String(), "too many diagnoses") {
		t.Errorf("second: %d %s", rec.Code, rec.Body)
	}
	if used := s.limit.used(time.Now()); used != 1 {
		t.Errorf("a refused request used up the hourly allowance: %d used", used)
	}
	close(b.release)
	wg.Wait()
	if len(s.sem) != 0 {
		t.Error("the slot wasn't released")
	}
}

func TestRepeatedQuestionsAreAnsweredFromTheCache(t *testing.T) {
	m := &scripted{replies: []string{reply("end_turn", `[{"type":"text","text":"first"}]`), reply("end_turn", `[{"type":"text","text":"second"}]`)}}
	s := testServer(m)
	s.limit.max = 1 // one real diagnosis an hour
	s.answers = diagnosisCache{ttl: time.Minute}
	body := `{"namespace":"shop","pod":"web-1","question":"why"}`

	var first, again Result
	json.Unmarshal(post(s, s.handleDiagnose, body).Body.Bytes(), &first)
	rec := post(s, s.handleDiagnose, body)
	json.Unmarshal(rec.Body.Bytes(), &again)
	if rec.Code != 200 || again.Answer != "first" || !again.Cached || again.CachedAt.IsZero() || first.Cached {
		t.Fatalf("the repeat wasn't cached: %d %+v", rec.Code, again)
	}
	if len(m.sent) != 1 {
		t.Errorf("the model was called %d times", len(m.sent))
	}
	if u := s.spend.snapshot(time.Now()); u.Diagnoses != 1 {
		t.Errorf("a cached answer was counted as spend: %+v", u)
	}
	// A different question isn't a repeat, and the hourly limit is spent.
	if rec := post(s, s.handleDiagnose, `{"namespace":"shop","pod":"web-1","question":"other"}`); rec.Code != http.StatusTooManyRequests {
		t.Errorf("different question: %d", rec.Code)
	}
	// Asking for a fresh one skips the cache, which is a new diagnosis and so needs allowance.
	s.limit.max = 5
	var fresh Result
	json.Unmarshal(post(s, s.handleDiagnose, `{"namespace":"shop","pod":"web-1","question":"why","fresh":true}`).Body.Bytes(), &fresh)
	if fresh.Answer != "second" || fresh.Cached {
		t.Errorf("fresh: %+v", fresh)
	}
}

func TestCachedAnswersStreamAsDone(t *testing.T) {
	m := &scripted{replies: []string{reply("end_turn", `[{"type":"text","text":"answer"}]`)}}
	s := testServer(m)
	s.answers = diagnosisCache{ttl: time.Minute}
	body := `{"namespace":"shop"}`
	post(s, s.handleDiagnose, body)
	rec := httptest.NewRecorder()
	s.handleDiagnoseStream(rec, httptest.NewRequest("POST", "/x", strings.NewReader(body)))
	out := rec.Body.String()
	if !strings.Contains(out, "event: done") || !strings.Contains(out, `"cached":true`) || strings.Contains(out, "event: turn") {
		t.Errorf("stream: %s", out)
	}
}

// A diagnosis that fails still cost what it used before failing.
func TestFailedDiagnosesStillCountTowardsSpend(t *testing.T) {
	m := &scripted{replies: []string{reply("tool_use", `[`+toolUse("t", "list_pods", `{}`)+`]`)}} // then the script runs out
	s := testServer(m, echo("list_pods", "x", nil))
	rec := post(s, s.handleDiagnose, `{"namespace":"a"}`)
	if rec.Code != http.StatusBadGateway {
		t.Fatalf("status %d", rec.Code)
	}
	if u := s.spend.snapshot(time.Now()); u.Tokens != 120 || u.SpentUSD <= 0 {
		t.Errorf("spend after a failure: %+v", u)
	}
	if _, ok := s.cached(diagnoseRequest{Namespace: "a"}, time.Now()); ok {
		t.Error("a failed diagnosis was cached")
	}
}

// A diagnosis that fails before it spends anything, such as with no API key, doesn't use the hourly allowance.
func TestFailureBeforeAnyTokensIsFree(t *testing.T) {
	s := testServer(&scripted{}) // no replies, so the first model call fails
	for i := 0; i < 5; i++ {
		if rec := post(s, s.handleDiagnose, `{"namespace":"a","question":"`+strings.Repeat("x", i+1)+`"}`); rec.Code != http.StatusBadGateway {
			t.Fatalf("attempt %d: status %d", i, rec.Code) // the limit is 2 an hour, and none was used up
		}
	}
	if used := s.limit.used(time.Now()); used != 0 {
		t.Errorf("%d of the hourly allowance used", used)
	}
	if u := s.spend.snapshot(time.Now()); u.Diagnoses != 0 {
		t.Errorf("counted as a diagnosis: %+v", u)
	}
}

func TestUsageEndpoint(t *testing.T) {
	s := testServer(&scripted{})
	s.dailyCap = 5
	s.spend.add(time.Now(), 1.25, 4000)
	s.limit.allow(time.Now())
	rec := httptest.NewRecorder()
	s.handleUsage(rec, httptest.NewRequest("GET", "/api/usage", nil))
	var u Usage
	if err := json.Unmarshal(rec.Body.Bytes(), &u); err != nil {
		t.Fatal(err)
	}
	if u.SpentUSD != 1.25 || u.CapUSD != 5 || u.Diagnoses != 1 || u.Tokens != 4000 || u.HourlyUsed != 1 || u.HourlyLimit != 2 {
		t.Errorf("usage: %+v", u)
	}
}

var _ = errors.New
