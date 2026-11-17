package main

import (
	"context"
	"embed"
	"encoding/json"
	"fmt"
	"path"
	"sort"
	"strings"
)

// Runbooks are short guides to common failures, written for this platform:
// what its composition sets, which policies apply, where to look. The
// assistant sees only their names and descriptions at first, and loads the
// full text of one when the symptoms match, so the prompt stays small as the
// set grows.
//
//go:embed runbooks/*.md
var runbookFiles embed.FS

type Runbook struct {
	Name        string
	Description string
	Tools       []string
	Body        string
}

// parseRunbook reads a runbook: a front matter block with name, description
// and tools, then the body.
func parseRunbook(file, text string) (Runbook, error) {
	rest, ok := strings.CutPrefix(text, "---\n")
	if !ok {
		return Runbook{}, fmt.Errorf("%s: no front matter", file)
	}
	front, body, ok := strings.Cut(rest, "\n---\n")
	if !ok {
		return Runbook{}, fmt.Errorf("%s: front matter isn't closed", file)
	}
	rb := Runbook{Body: strings.TrimSpace(body)}
	for _, line := range strings.Split(front, "\n") {
		key, value, ok := strings.Cut(line, ":")
		if !ok {
			continue
		}
		value = strings.TrimSpace(value)
		switch strings.TrimSpace(key) {
		case "name":
			rb.Name = value
		case "description":
			rb.Description = value
		case "tools":
			for _, t := range strings.Split(value, ",") {
				if t = strings.TrimSpace(t); t != "" {
					rb.Tools = append(rb.Tools, t)
				}
			}
		}
	}
	if want := strings.TrimSuffix(path.Base(file), ".md"); rb.Name != want {
		return Runbook{}, fmt.Errorf("%s: name %q doesn't match the file name", file, rb.Name)
	}
	if rb.Description == "" || rb.Body == "" {
		return Runbook{}, fmt.Errorf("%s: needs a description and a body", file)
	}
	return rb, nil
}

// LoadRunbooks reads every runbook built into the binary, sorted by name.
func LoadRunbooks() ([]Runbook, error) {
	entries, err := runbookFiles.ReadDir("runbooks")
	if err != nil {
		return nil, err
	}
	var out []Runbook
	for _, e := range entries {
		text, err := runbookFiles.ReadFile("runbooks/" + e.Name())
		if err != nil {
			return nil, err
		}
		rb, err := parseRunbook(e.Name(), string(text))
		if err != nil {
			return nil, err
		}
		out = append(out, rb)
	}
	sort.Slice(out, func(i, j int) bool { return out[i].Name < out[j].Name })
	return out, nil
}

// RunbookIndex is what the assistant is told about the runbooks up front.
func RunbookIndex(rs []Runbook) string {
	var b strings.Builder
	b.WriteString("Runbooks describe how this platform behaves for common failures: what its composition sets, which policies apply and where to look. When the symptoms match one, load it with load_runbook before you conclude. The evidence from the cluster still decides: if it contradicts a runbook, trust the evidence and say so.\n")
	for _, r := range rs {
		fmt.Fprintf(&b, "- %s: %s\n", r.Name, r.Description)
	}
	return strings.TrimSpace(b.String())
}

// withRunbooks adds the runbook tool and index to an agent's tools and
// system prompt. With enabled false it changes nothing, which is how to
// measure what the runbooks add.
func withRunbooks(tools []Tool, system string, enabled bool) ([]Tool, string, int, error) {
	if !enabled {
		return tools, system, 0, nil
	}
	rs, err := LoadRunbooks()
	if err != nil {
		return nil, "", 0, err
	}
	return append(tools[:len(tools):len(tools)], RunbookTool(rs)), system + "\n\n" + RunbookIndex(rs), len(rs), nil
}

// RunbookTool lets the assistant load a runbook by name.
func RunbookTool(rs []Runbook) Tool {
	names := make([]string, len(rs))
	byName := make(map[string]Runbook, len(rs))
	for i, r := range rs {
		names[i] = r.Name
		byName[r.Name] = r
	}
	return Tool{
		Name:        "load_runbook",
		Description: "Loads a runbook: how this platform behaves for a kind of failure, and where to look. Names and descriptions are in the instructions.",
		Properties:  map[string]any{"name": map[string]any{"type": "string", "enum": names, "description": "Runbook name"}},
		Required:    []string{"name"},
		Run: func(_ context.Context, in json.RawMessage) (string, error) {
			var a struct {
				Name string `json:"name"`
			}
			if err := json.Unmarshal(in, &a); err != nil {
				return "", err
			}
			r, ok := byName[a.Name]
			if !ok {
				return "", fmt.Errorf("there is no runbook named %q; the runbooks are: %s", a.Name, strings.Join(names, ", "))
			}
			return "# Runbook: " + r.Name + "\n\n" + r.Body, nil
		},
	}
}
