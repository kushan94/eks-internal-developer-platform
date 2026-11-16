package main

import (
	"context"
	"encoding/json"
	"errors"
	"io"
	"log/slog"
	"strings"
	"testing"

	"github.com/anthropics/anthropic-sdk-go"
)

// scripted plays back canned model responses and records what it was sent.
type scripted struct {
	replies []string
	sent    []anthropic.MessageNewParams
}

func (s *scripted) New(_ context.Context, p anthropic.MessageNewParams) (*anthropic.Message, error) {
	s.sent = append(s.sent, p)
	if len(s.sent) > len(s.replies) {
		return nil, errors.New("the script ran out")
	}
	var m anthropic.Message
	if err := json.Unmarshal([]byte(s.replies[len(s.sent)-1]), &m); err != nil {
		return nil, err
	}
	return &m, nil
}

func reply(stop string, content string) string {
	return `{"id":"msg_1","type":"message","role":"assistant","model":"m","stop_reason":"` + stop +
		`","content":` + content + `,"usage":{"input_tokens":100,"output_tokens":20}}`
}

func toolUse(id, name, input string) string {
	return `{"type":"tool_use","id":"` + id + `","name":"` + name + `","input":` + input + `}`
}

func agentWith(c Messenger, tools ...Tool) *Agent {
	return &Agent{Model: "m", Client: c, Tools: tools, MaxTurns: 4, MaxTokens: 1000, Log: slog.New(slog.NewTextHandler(io.Discard, nil))}
}

func echo(name string, out string, err error) Tool {
	return Tool{Name: name, Run: func(context.Context, json.RawMessage) (string, error) { return out, err }}
}

func TestAgentRunsToolsThenAnswers(t *testing.T) {
	m := &scripted{replies: []string{
		reply("tool_use", `[`+toolUse("t1", "list_pods", `{"namespace":"demo-dev"}`)+`,`+toolUse("t2", "get_events", `{"namespace":"demo-dev"}`)+`]`),
		reply("end_turn", `[{"type":"text","text":"The container is OOMKilled."}]`),
	}}
	a := agentWith(m, echo("list_pods", "CrashLoopBackOff", nil), echo("get_events", "BackOff", nil))
	res, err := a.Run(context.Background(), "diagnose")
	if err != nil {
		t.Fatal(err)
	}
	if res.Answer != "The container is OOMKilled." || len(res.Steps) != 2 || res.InputTokens != 200 || res.OutputTokens != 40 {
		t.Fatalf("unexpected result: %+v", res)
	}
	// Both results come back together in one user message.
	history, _ := json.Marshal(m.sent[1].Messages)
	var msgs []struct {
		Role    string
		Content []struct {
			Type      string `json:"type"`
			ToolUseID string `json:"tool_use_id"`
		}
	}
	if err := json.Unmarshal(history, &msgs); err != nil {
		t.Fatal(err)
	}
	last := msgs[len(msgs)-1]
	if last.Role != "user" || len(last.Content) != 2 || last.Content[0].Type != "tool_result" || last.Content[1].ToolUseID != "t2" {
		t.Errorf("tool results were not returned in one user message: %s", history)
	}
}

func TestToolFailuresReachTheModelAsErrors(t *testing.T) {
	m := &scripted{replies: []string{
		reply("tool_use", `[`+toolUse("t1", "get_resource", `{"kind":"secrets"}`)+`,`+toolUse("t2", "nope", `{}`)+`]`),
		reply("end_turn", `[{"type":"text","text":"done"}]`),
	}}
	a := agentWith(m, echo("get_resource", "", errors.New(`kind "secrets" can't be read`)))
	res, err := a.Run(context.Background(), "x")
	if err != nil {
		t.Fatal(err)
	}
	if !res.Steps[0].Failed || !res.Steps[1].Failed {
		t.Errorf("failures were not recorded: %+v", res.Steps)
	}
	history, _ := json.Marshal(m.sent[1].Messages)
	if !strings.Contains(string(history), `"is_error":true`) || !strings.Contains(string(history), "There is no tool named") {
		t.Errorf("model was not told about the failures: %s", history)
	}
}

func TestToolOutputIsRedactedAndCapped(t *testing.T) {
	m := &scripted{replies: []string{
		reply("tool_use", `[`+toolUse("t1", "get_pod_logs", `{}`)+`]`),
		reply("end_turn", `[{"type":"text","text":"ok"}]`),
	}}
	a := agentWith(m, echo("get_pod_logs", "password=hunter2 "+strings.Repeat("x", 20000), nil))
	if _, err := a.Run(context.Background(), "x"); err != nil {
		t.Fatal(err)
	}
	history, _ := json.Marshal(m.sent[1].Messages)
	if strings.Contains(string(history), "hunter2") || !strings.Contains(string(history), "truncated") {
		t.Errorf("tool output was not redacted and capped")
	}
}

func TestAgentStopsAtMaxTurns(t *testing.T) {
	loop := reply("tool_use", `[`+toolUse("t", "list_pods", `{}`)+`]`)
	m := &scripted{replies: []string{loop, loop, loop, loop, loop}}
	res, err := agentWith(m, echo("list_pods", "x", nil)).Run(context.Background(), "x")
	if err != nil {
		t.Fatal(err)
	}
	if res.Stopped != "max_turns" || len(m.sent) != 4 {
		t.Errorf("stopped=%q after %d calls", res.Stopped, len(m.sent))
	}
}

func TestRefusalIsReported(t *testing.T) {
	m := &scripted{replies: []string{reply("refusal", `[]`)}}
	res, err := agentWith(m).Run(context.Background(), "x")
	if err != nil || res.Stopped != "refusal" {
		t.Errorf("res=%+v err=%v", res, err)
	}
}

func TestModelErrorsAreReturned(t *testing.T) {
	if _, err := agentWith(&scripted{}).Run(context.Background(), "x"); err == nil {
		t.Error("expected an error")
	}
}

func TestEveryToolHasASchemaAndNoneWrites(t *testing.T) {
	for _, tool := range BuildTools(&Kube{}, nil) {
		if tool.Description == "" || tool.Properties == nil || len(tool.Required) == 0 {
			t.Errorf("tool %s is incomplete", tool.Name)
		}
		if strings.Contains(tool.Name, "delete") || strings.Contains(tool.Name, "apply") || strings.Contains(tool.Name, "exec") {
			t.Errorf("tool %s looks like it writes", tool.Name)
		}
	}
}
