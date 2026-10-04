package main

import (
	"encoding/xml"
	"os"
	"strings"
	"testing"
)

func TestParseSparkleSignature(t *testing.T) {
	output := `<enclosure sparkle:edSignature="abc123==" length="456789" />`

	signature, length := parseSparkleSignature(output)

	if signature != "abc123==" {
		t.Fatalf("signature = %q, want %q", signature, "abc123==")
	}
	if length != "456789" {
		t.Fatalf("length = %q, want %q", length, "456789")
	}
}

func TestWriteAppcast(t *testing.T) {
	path := t.TempDir() + "/appcast.xml"
	items := []Item{
		{
			Title:              "Version 1.0",
			Version:            "1",
			ShortVersionString: "1.0",
			MinSystemVersion:   minSystemVer,
			PubDate:            "Tue, 12 May 2026 09:30:00 +0000",
			Description:        buildDescription("1.0", []string{"Initial release"}),
			Enclosure: Enclosure{
				URL:         "https://github.com/helson-lin/Screendrop/releases/download/v1.0/Framecho.dmg",
				Type:        "application/octet-stream",
				EdSignature: "sig==",
				Length:      "123",
			},
		},
	}

	if err := writeAppcast(path, items); err != nil {
		t.Fatal(err)
	}

	data, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}

	text := string(data)
	if !strings.Contains(text, "<title>Framecho Updates</title>") {
		t.Fatal("appcast title was not written")
	}
	if !strings.Contains(text, "Run: go run ./cmd/screendrop-release") {
		t.Fatal("release instructions were not written")
	}

	var appcast Appcast
	if err := xml.Unmarshal(data, &appcast); err != nil {
		t.Fatal(err)
	}
	if got := len(appcast.Channel.Items); got != 1 {
		t.Fatalf("item count = %d, want 1", got)
	}
	if appcast.Channel.Items[0].Version != "1" {
		t.Fatalf("version = %q, want 1", appcast.Channel.Items[0].Version)
	}
}

func TestIsTransientSigningFailure(t *testing.T) {
	timestampOutage := `error: exportArchive codesign command failed (/tmp/Framecho.app/Contents/Frameworks/Sparkle.framework/Versions/B: replacing existing signature
/tmp/Framecho.app/Contents/Frameworks/Sparkle.framework/Versions/B: The timestamp service is not available.
)`
	if !isTransientSigningFailure(timestampOutage) {
		t.Fatal("timestamp outage should be retried")
	}

	missingIdentity := `error: No signing certificate "Developer ID Application" found`
	if isTransientSigningFailure(missingIdentity) {
		t.Fatal("missing certificate should not be retried")
	}
}

func TestSigningFailureDetail(t *testing.T) {
	output := strings.Join([]string{
		"CompileSwift normal arm64",
		"/tmp/Sparkle.framework/Versions/B: The timestamp service is not available.",
		"Command CodeSign failed with a nonzero exit code",
		"** ARCHIVE FAILED **",
	}, "\n")

	detail := signingFailureDetail(output)
	if !strings.Contains(detail, "The timestamp service is not available.") {
		t.Fatalf("detail = %q, want the timestamp error", detail)
	}
	if strings.Contains(detail, "CompileSwift") || strings.Contains(detail, "ARCHIVE FAILED") {
		t.Fatalf("detail = %q, want only signing lines", detail)
	}
	if signingFailureDetail("** ARCHIVE FAILED **") != "" {
		t.Fatal("output without signing errors should add no detail")
	}
}

func TestRunSigningCmdRetriesOnlyTimestampFailures(t *testing.T) {
	previousDelay := signingRetryDelay
	signingRetryDelay = 0
	t.Cleanup(func() { signingRetryDelay = previousDelay })

	attempts := 0
	_, err := runSigningCmd(func() { attempts++ }, "sh", "-c", "echo 'The timestamp service is not available.'; exit 1")
	if err == nil || attempts != signingAttempts {
		t.Fatalf("attempts = %d, err = %v; want %d attempts and an error", attempts, err, signingAttempts)
	}

	attempts = 0
	_, err = runSigningCmd(func() { attempts++ }, "sh", "-c", "echo 'No signing certificate'; exit 1")
	if err == nil || attempts != 1 {
		t.Fatalf("attempts = %d, err = %v; want 1 attempt and an error", attempts, err)
	}
}
