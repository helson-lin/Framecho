package main

import (
	"encoding/json"
	"fmt"
	"os/exec"
	"strings"
)

// skipChecks bypasses the pre-release gate. For emergencies only: a release
// cut with failing checks ships whatever they would have caught.
var skipChecks bool

// releaseChecks are the commands that must pass, from the repository root,
// before anything is built, committed or published. They are the same
// checks CI runs on every push.
func releaseChecks() [][]string {
	return [][]string{
		{"scripts/run-checks.sh"},
		{"go", "vet", "./cmd/..."},
		{"go", "test", "./cmd/..."},
	}
}

// ciState is what GitHub Actions reports for the commit being released.
type ciState int

const (
	ciPassed ciState = iota
	ciFailed
	ciPending
	ciMissing
)

type ciRun struct {
	Status     string `json:"status"`
	Conclusion string `json:"conclusion"`
}

// ciVerdict reads `gh run list --json status,conclusion` for one commit,
// newest first. Only the latest run counts: a re-run that passed overrides
// an earlier failure.
func ciVerdict(runs []ciRun) ciState {
	if len(runs) == 0 {
		return ciMissing
	}
	latest := runs[0]
	if latest.Status != "completed" {
		return ciPending
	}
	switch latest.Conclusion {
	case "success":
		return ciPassed
	case "failure", "timed_out", "startup_failure", "action_required":
		return ciFailed
	default:
		// Cancelled or skipped: nothing was verified.
		return ciMissing
	}
}

// runReleaseGate runs every check locally, then asks CI about the commit.
// A local failure or a CI failure stops the release; a commit CI hasn't
// seen yet (unpushed, or still running) only warns, since the same checks
// just passed here.
func runReleaseGate(repoDir string) {
	if skipChecks {
		warn("Skipping checks (-skip-checks): this release isn't verified")
		return
	}

	step("Running checks (skip with -skip-checks)...")
	ensureXcodeDeveloperDir()
	for _, args := range releaseChecks() {
		label := strings.Join(args, " ")
		cmd := exec.Command(args[0], args[1:]...)
		cmd.Dir = repoDir
		out, err := cmd.CombinedOutput()
		if err != nil {
			fail(label + " failed:\n" + lastLines(string(out), 40))
		}
		success(label)
	}

	step("Checking CI for this commit...")
	sha, err := runCmd("git", "-C", repoDir, "rev-parse", "HEAD")
	if err != nil {
		warn("Could not read HEAD: " + err.Error())
		return
	}
	out, err := runCmd("gh", "run", "list", "--workflow", "ci.yml", "--commit", sha,
		"--json", "status,conclusion", "--limit", "1")
	if err != nil {
		warn("Could not ask GitHub about CI: " + lastLines(out, 3))
		return
	}
	var runs []ciRun
	if err := json.Unmarshal([]byte(out), &runs); err != nil {
		warn("Unexpected answer from gh run list: " + lastLines(out, 3))
		return
	}

	short := sha
	if len(short) > 7 {
		short = short[:7]
	}
	switch ciVerdict(runs) {
	case ciPassed:
		success("CI passed for " + short)
	case ciFailed:
		fail(fmt.Sprintf("CI failed for %s. Fix it, or pass -skip-checks to release anyway.", short))
	case ciPending:
		warn("CI is still running for " + short + "; the local checks passed")
	case ciMissing:
		warn("CI hasn't checked " + short + " (not pushed yet?); the local checks passed")
	}
}
