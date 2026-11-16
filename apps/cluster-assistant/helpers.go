package main

import (
	"fmt"
	"regexp"
	"sort"
)

func sortedStrings(s []string) []string { sort.Strings(s); return s }

// sortBy sorts by index so a slice of structs can be sorted without a copy.
func sortBy(n int, less func(i, j int) bool, swap func(i, j int)) {
	sort.Sort(&byIndex{n, less, swap})
}

type byIndex struct {
	n    int
	less func(i, j int) bool
	swap func(i, j int)
}

func (b *byIndex) Len() int           { return b.n }
func (b *byIndex) Less(i, j int) bool { return b.less(i, j) }
func (b *byIndex) Swap(i, j int)      { b.swap(i, j) }

// Text from the cluster goes to a model, so credentials are removed first.
var secretPatterns = []*regexp.Regexp{
	regexp.MustCompile(`AKIA[0-9A-Z]{16}`),
	regexp.MustCompile(`(?i)(ghp|gho|ghs|github_pat)_[A-Za-z0-9_]{20,}`),
	regexp.MustCompile(`eyJ[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}`),
	regexp.MustCompile(`(?i)bearer\s+[A-Za-z0-9._~+/=-]{16,}`),
	regexp.MustCompile(`(?i)(postgres(?:ql)?|mysql|amqp|redis)://[^:/\s@]+:[^@\s]+@`),
	regexp.MustCompile(`(?i)\b(password|passwd|secret|token|api[_-]?key)\b("?\s*[=:]\s*)("[^"]*"|'[^']*'|\S+)`),
}

func redact(s string) string {
	for i, re := range secretPatterns {
		switch i {
		case 4:
			s = re.ReplaceAllString(s, "${1}://[redacted]@")
		case 5:
			s = re.ReplaceAllString(s, "${1}${2}[redacted]")
		default:
			s = re.ReplaceAllString(s, "[redacted]")
		}
	}
	return s
}

const maxResultBytes = 12000

func truncate(s string) string {
	if len(s) <= maxResultBytes {
		return s
	}
	return s[:maxResultBytes] + fmt.Sprintf("\n[truncated %d more bytes]", len(s)-maxResultBytes)
}
