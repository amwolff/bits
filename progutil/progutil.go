// Package progutil provides utility functions for running programs.
package progutil

import (
	"context"
	"fmt"
	"io"
	"log/slog"
	"os"
	"os/signal"
	"strconv"
	"strings"

	"github.com/zeebo/clingy"
)

// Global holds global configuration for the program.
type Global struct {
	stdout io.Writer
	Log    *slog.Logger
}

func (w *Global) setup(cmds clingy.Commands) {
	debug := cmds.Flag(
		"debug",
		"enable debug logging",
		false,
		clingy.Transform(strconv.ParseBool),
		clingy.Boolean,
	).(bool)
	json := cmds.Flag(
		"json",
		"enable JSON logging",
		false,
		clingy.Transform(strconv.ParseBool),
		clingy.Boolean,
	).(bool)

	opts := &slog.HandlerOptions{
		AddSource: false,
		Level:     slog.LevelInfo,
	}

	if debug {
		opts.AddSource = true
		opts.Level = slog.LevelDebug
	}

	var h slog.Handler

	if json {
		h = slog.NewJSONHandler(w.stdout, opts)
	} else {
		h = slog.NewTextHandler(w.stdout, opts)
	}

	w.Log = slog.New(h)
}

// Entry is a command or a group of commands.
type Entry interface {
	register(cmds clingy.Commands, g Global)
}

type cmdEntry struct {
	fn func(g Global) (name string, desc string, cmd clingy.Command)
}

func (e cmdEntry) register(cmds clingy.Commands, g Global) {
	cmds.New(e.fn(g))
}

// Cmd returns an Entry for a single command.
func Cmd(fn func(g Global) (name string, desc string, cmd clingy.Command)) Entry {
	return cmdEntry{fn: fn}
}

type groupEntry struct {
	name    string
	desc    string
	entries []Entry
}

func (e groupEntry) register(cmds clingy.Commands, g Global) {
	cmds.Group(e.name, e.desc, func() {
		for _, entry := range e.entries {
			entry.register(cmds, g)
		}
	})
}

// Group returns an Entry for a group of commands.
func Group(name, desc string, entries ...Entry) Entry {
	return groupEntry{name: name, desc: desc, entries: entries}
}

// envName maps a program or flag name to an environment variable name.
func envName(name string) string {
	return strings.ToUpper(strings.ReplaceAll(name, "-", "_"))
}

// Main runs the program with the given name and entries.
func Main(name string, entries ...Entry) {
	if !main(name, entries...) {
		os.Exit(1)
	}
}

func main(name string, entries ...Entry) bool {
	ctx, cancel := signal.NotifyContext(context.Background(), os.Interrupt)
	defer cancel()

	stdout := os.Stdout
	g := Global{stdout: stdout}

	prefix := envName(name) + "_"

	ok, err := clingy.Environment{
		Name:   name,
		Stdout: stdout,
		// Dynamic backs flags the command line does not set with
		// environment variables, e.g. --log-level with MY_PROG_LOG_LEVEL.
		Dynamic: func(flagName string) ([]string, error) {
			if val := os.Getenv(prefix + envName(flagName)); val != "" {
				return []string{val}, nil
			}
			return nil, nil
		},
	}.Run(ctx, func(clingyCommands clingy.Commands) {
		g.setup(clingyCommands)
		for _, entry := range entries {
			entry.register(clingyCommands, g)
		}
	})
	if err != nil {
		if g.Log != nil {
			g.Log.ErrorContext(ctx, "command failed", slog.Any("error", err))
		} else {
			fmt.Fprintf(os.Stderr, "%+v\n", err)
		}
	}

	return ok && err == nil
}
