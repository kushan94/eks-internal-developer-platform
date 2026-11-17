package main

import (
	"context"
	"encoding/json"
	"regexp"
	"strings"
	"testing"
)

func TestEveryRunbookIsWellFormed(t *testing.T) {
	rs, err := LoadRunbooks()
	if err != nil {
		t.Fatal(err)
	}
	if len(rs) < 9 {
		t.Errorf("only %d runbooks", len(rs))
	}
	kebab := regexp.MustCompile(`^[a-z]+(-[a-z]+)+$`)
	seen := map[string]bool{}
	for _, r := range rs {
		if !kebab.MatchString(r.Name) || seen[r.Name] {
			t.Errorf("name %q is not kebab-case or is repeated", r.Name)
		}
		seen[r.Name] = true
		// The descriptions are always in the prompt, so they stay short. A body is loaded on
		// demand, and kept to about a thousand tokens.
		if len(r.Description) > 200 {
			t.Errorf("%s: description is %d characters", r.Name, len(r.Description))
		}
		if len(r.Body) > 5000 {
			t.Errorf("%s: body is %d bytes", r.Name, len(r.Body))
		}
		if !strings.Contains(r.Body, "**Fix:**") && !strings.Contains(r.Body, "**Fix") {
			t.Errorf("%s: says nothing about the fix", r.Name)
		}
		if len(r.Tools) == 0 {
			t.Errorf("%s: names no tools", r.Name)
		}
	}
}

func TestRunbooksNameOnlyRealTools(t *testing.T) {
	real := map[string]bool{}
	for _, tool := range BuildTools(&Kube{}, nil) {
		real[tool.Name] = true
	}
	rs, _ := LoadRunbooks()
	for _, r := range rs {
		for _, name := range r.Tools {
			if !real[name] {
				t.Errorf("%s names the tool %q, which doesn't exist", r.Name, name)
			}
		}
		// Anything written as a tool call in the text must exist too.
		for _, m := range regexp.MustCompile("`((?:list|get|query|load)_[a-z_]+)").FindAllStringSubmatch(r.Body, -1) {
			if !real[m[1]] && m[1] != "load_runbook" {
				t.Errorf("%s mentions the tool %q, which doesn't exist", r.Name, m[1])
			}
		}
	}
}

func TestParseRunbookRejectsBadInput(t *testing.T) {
	for name, text := range map[string]string{
		"a-b.md": "no front matter",
		"c-d.md": "---\nname: c-d\ndescription: x\n",
		"e-f.md": "---\nname: wrong-name\ndescription: x\ntools: list_pods\n---\nbody",
		"g-h.md": "---\nname: g-h\ndescription:\ntools: list_pods\n---\nbody",
		"i-j.md": "---\nname: i-j\ndescription: x\ntools: list_pods\n---\n",
	} {
		if _, err := parseRunbook(name, text); err == nil {
			t.Errorf("%s was accepted", name)
		}
	}
	rb, err := parseRunbook("k-l.md", "---\nname: k-l\ndescription: A thing: with a colon\ntools: list_pods, get_events\n---\n# Title\nbody\n")
	if err != nil || rb.Description != "A thing: with a colon" || len(rb.Tools) != 2 || rb.Body != "# Title\nbody" {
		t.Errorf("%+v %v", rb, err)
	}
}

func TestIndexListsEveryRunbook(t *testing.T) {
	rs, _ := LoadRunbooks()
	index := RunbookIndex(rs)
	for _, r := range rs {
		if !strings.Contains(index, "- "+r.Name+": "+r.Description) {
			t.Errorf("the index is missing %s", r.Name)
		}
	}
	if !strings.Contains(index, "trust the evidence") {
		t.Error("the index doesn't tell the model that evidence beats a runbook")
	}
}

func TestRunbookToolLoadsAndRefuses(t *testing.T) {
	rs, _ := LoadRunbooks()
	tool := RunbookTool(rs)
	if enum := tool.Properties["name"].(map[string]any)["enum"].([]string); len(enum) != len(rs) {
		t.Errorf("enum has %d names for %d runbooks", len(enum), len(rs))
	}
	out, err := tool.Run(context.Background(), json.RawMessage(`{"name":"crash-or-oom"}`))
	if err != nil || !strings.HasPrefix(out, "# Runbook: crash-or-oom") || !strings.Contains(out, "256Mi") {
		t.Errorf("%q %v", out[:min(len(out), 60)], err)
	}
	if _, err := tool.Run(context.Background(), json.RawMessage(`{"name":"nope"}`)); err == nil || !strings.Contains(err.Error(), "crash-or-oom") {
		t.Errorf("an unknown name should list the real ones: %v", err)
	}
}

func TestWithRunbooksIsOptional(t *testing.T) {
	base := []Tool{{Name: "list_pods"}}
	tools, system, n, err := withRunbooks(base, "SYSTEM", true)
	if err != nil || n < 9 || len(tools) != 2 || tools[1].Name != "load_runbook" || !strings.HasPrefix(system, "SYSTEM\n\n") || !strings.Contains(system, "crash-or-oom") {
		t.Fatalf("on: %d tools, %d runbooks, %v", len(tools), n, err)
	}
	if len(base) != 1 {
		t.Error("the caller's tools were modified")
	}
	tools, system, n, err = withRunbooks(base, "SYSTEM", false)
	if err != nil || n != 0 || len(tools) != 1 || system != "SYSTEM" {
		t.Errorf("off: %d tools, %q", len(tools), system)
	}
}

// The model reads the index, loads a runbook, and the runbook text reaches it.
func TestAssistantCanLoadARunbook(t *testing.T) {
	tools, system, _, _ := withRunbooks(nil, systemPrompt, true)
	m := &scripted{replies: []string{
		reply("tool_use", `[`+toolUse("t1", "load_runbook", `{"name":"blocked-traffic"}`)+`]`),
		reply("end_turn", `[{"type":"text","text":"allowInternet is missing"}]`),
	}}
	a := agentWith(m, tools...)
	a.System = system
	res, err := a.Run(context.Background(), "x")
	if err != nil || res.Answer != "allowInternet is missing" || len(res.Steps) != 1 || res.Steps[0].Failed {
		t.Fatalf("%+v %v", res, err)
	}
	first, second := sentJSON(m, 0), sentJSON(m, 1)
	if !strings.Contains(first, "- blocked-traffic: ") || !strings.Contains(first, `"name":"load_runbook"`) {
		t.Errorf("the first request lacks the index or the tool")
	}
	if !strings.Contains(second, "Both sides must agree") {
		t.Errorf("the runbook text didn't reach the model: %.300s", second)
	}
}
