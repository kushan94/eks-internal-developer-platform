package main

import (
	"strconv"
	"strings"
)

var quantitySuffixes = []struct {
	suffix string
	factor float64
}{
	{"Ki", 1 << 10}, {"Mi", 1 << 20}, {"Gi", 1 << 30}, {"Ti", 1 << 40}, {"Pi", 1 << 50}, {"Ei", 1 << 60},
	{"n", 1e-9}, {"u", 1e-6}, {"m", 1e-3},
	{"k", 1e3}, {"K", 1e3}, {"M", 1e6}, {"G", 1e9}, {"T", 1e12}, {"P", 1e15}, {"E", 1e18},
}

// parseQuantity turns a Kubernetes quantity such as "250m", "2", "512Mi" or
// "1G" into cores or bytes. It returns 0 for anything it can't read.
func parseQuantity(s string) float64 {
	s = strings.TrimSpace(s)
	if f, err := strconv.ParseFloat(s, 64); err == nil {
		return f
	}
	for _, q := range quantitySuffixes {
		if strings.HasSuffix(s, q.suffix) {
			if f, err := strconv.ParseFloat(strings.TrimSuffix(s, q.suffix), 64); err == nil {
				return f * q.factor
			}
			return 0
		}
	}
	return 0
}
