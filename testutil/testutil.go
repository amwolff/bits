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

func NewTestLogger(t *testing.T) *slog.Logger {
	return slog.New(slog.NewTextHandler(logWriter{t: t}, &slog.HandlerOptions{
		AddSource: true,
		Level:     slog.LevelDebug,
	}))
}

func RandomString(n int) string {
	b := make([]byte, n)
	_, err := rand.Read(b)
	if err != nil {
		panic(err)
	}
	return hex.EncodeToString(b)
}
