package main

import (
	"encoding/json"
	"os"
	"path/filepath"
	"regexp"
	"strings"
	"testing"
)

func TestCIVerdict(t *testing.T) {
	cases := []struct {
		name string
		json string
		want ciState
	}{
		{"never ran", `[]`, ciMissing},
		{"passed", `[{"status":"completed","conclusion":"success"}]`, ciPassed},
		{"failed", `[{"status":"completed","conclusion":"failure"}]`, ciFailed},
		{"timed out", `[{"status":"completed","conclusion":"timed_out"}]`, ciFailed},
		{"running", `[{"status":"in_progress","conclusion":""}]`, ciPending},
		{"queued", `[{"status":"queued","conclusion":""}]`, ciPending},
		{"cancelled", `[{"status":"completed","conclusion":"cancelled"}]`, ciMissing},
		// The newest run decides: a passing re-run clears an earlier failure.
		{"re-run passed", `[{"status":"completed","conclusion":"success"},{"status":"completed","conclusion":"failure"}]`, ciPassed},
		{"re-run failed", `[{"status":"completed","conclusion":"failure"},{"status":"completed","conclusion":"success"}]`, ciFailed},
	}
	for _, c := range cases {
		var runs []ciRun
		if err := json.Unmarshal([]byte(c.json), &runs); err != nil {
			t.Fatalf("%s: %v", c.name, err)
		}
		if got := ciVerdict(runs); got != c.want {
			t.Errorf("%s: got %v, want %v", c.name, got, c.want)
		}
	}
}

// The release runs what CI runs: if a check is added to one, the other
// must not silently miss it.
func TestReleaseChecksMatchCI(t *testing.T) {
	workflow, err := os.ReadFile(filepath.Join("..", "..", ".github", "workflows", "ci.yml"))
	if err != nil {
		t.Fatal(err)
	}
	ci := string(workflow)
	for _, args := range releaseChecks() {
		command := strings.Join(args, " ")
		if !strings.Contains(ci, command) {
			t.Errorf("%q runs before a release but not in CI", command)
		}
	}
	for _, line := range regexp.MustCompile(`(?m)^\s*(?:-\s*)?run:\s*(scripts/\S+|go \S+ \S+)\s*$`).FindAllStringSubmatch(ci, -1) {
		found := false
		for _, args := range releaseChecks() {
			if strings.Join(args, " ") == line[1] {
				found = true
			}
		}
		if !found {
			t.Errorf("CI runs %q but a release doesn't", line[1])
		}
	}
}

func TestReleaseChecksExist(t *testing.T) {
	for _, args := range releaseChecks() {
		if strings.HasPrefix(args[0], "scripts/") {
			info, err := os.Stat(filepath.Join("..", "..", args[0]))
			if err != nil {
				t.Errorf("%s: %v", args[0], err)
			} else if info.Mode()&0o111 == 0 {
				t.Errorf("%s isn't executable", args[0])
			}
		}
	}
}
