package progutil

import "testing"

func TestEnvPrefix(t *testing.T) {
	for _, tt := range []struct {
		global, name, want string
	}{
		{"", "my-prog", "MY_PROG_"},
		{"acme", "my-prog", "ACME_MY_PROG_"},
		{"acme-corp", "my-prog", "ACME_CORP_MY_PROG_"},
	} {
		if got := envPrefix(tt.global, tt.name); got != tt.want {
			t.Errorf("envPrefix(%q, %q) = %q, want %q", tt.global, tt.name, got, tt.want)
		}
	}
}
