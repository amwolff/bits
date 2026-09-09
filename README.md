# bits

Environment bootstrap, Go utilities and a [Claude Code plugin](https://code.claude.com/docs/en/plugins) marketplace.

## Setup

```
curl -fsSL https://raw.githubusercontent.com/amwolff/bits/main/setup.sh | bash -s -- \
  --name "<name>" \
  --email <email> \
  --auth-key "ssh-ed25519 AAAA... <comment>" \
  --signing-key "ssh-ed25519 AAAA..."
```

Idempotent — `--dry-run` shows what would change.
`--mode devcontainer --target .` writes a `.devcontainer/` that runs it on create instead.
The `packages` and `awscli` modules install through `sudo`.
See `setup.sh --help` for the rest.

The lists it installs — `setup/aliases.sh` and `setup/packages.txt` — are read from a checkout, else fetched at `--ref`.
Per-machine additions go in `~/.config/bits/aliases.local.sh`, which bits never touches.

## Install

```
/plugin marketplace add amwolff/bits
/plugin install amwolff-grimoire@bits
```

### Recommended extras

- **gopls-lsp** — `/plugin install gopls-lsp@claude-plugins-official` (requires [`gopls`](https://pkg.go.dev/golang.org/x/tools/gopls))
- **[Playwright CLI](https://github.com/microsoft/playwright-cli)** — browser automation for coding agents
  ```
  npm install -g @playwright/cli@latest
  cd && playwright-cli install-browser --with-deps --only-shell && playwright-cli install --skills
  ```

## License

MIT
