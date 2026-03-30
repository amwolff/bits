// Package testutil provides utility functions for testing.
package testutil

import (
	"crypto/rand"
	"encoding/hex"
	"log/slog"
	"testing"
)

type logWriter struct {
	t *testing.T
}

func (l logWriter) Write(p []byte) (n int, err error) {
	s := string(p)
	l.t.Log(s)
	return len(s), nil
}

// NewTestLogger returns a new slog.Logger that writes to the given testing.T.
func NewTestLogger(t *testing.T) *slog.Logger {
	return slog.New(slog.NewTextHandler(logWriter{t: t}, &slog.HandlerOptions{
		AddSource: true,
		Level:     slog.LevelDebug,
	}))
}

// RandomString returns a random string of the given length.
func RandomString(n int) string {
	b := make([]byte, n)
	_, err := rand.Read(b)
	if err != nil {
		panic(err)
	}
	return hex.EncodeToString(b)
}
