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

// Main runs the program with the given name and commands.
func Main(name string, cmds ...func(g Global) (name string, desc string, cmd clingy.Command)) {
	if !main(name, cmds...) {
		os.Exit(1)
	}
}

func main(name string, cmds ...func(g Global) (name string, desc string, cmd clingy.Command)) bool {
	ctx, cancel := signal.NotifyContext(context.Background(), os.Interrupt)
	defer cancel()

	stdout := os.Stdout
	g := Global{stdout: stdout}

	ok, err := clingy.Environment{
		Name:   name,
		Stdout: stdout,
	}.Run(ctx, func(clingyCommands clingy.Commands) {
		g.setup(clingyCommands)
		for _, cmd := range cmds {
			clingyCommands.New(cmd(g))
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
