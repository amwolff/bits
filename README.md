# bits

Go utilities and a [Claude Code plugin](https://code.claude.com/docs/en/plugins) marketplace.

## Install

```
/plugin marketplace add amwolff/bits
/plugin install amwolff-grimoire@bits
```

### Recommended companion plugins

```
/plugin marketplace add ChromeDevTools/chrome-devtools-mcp
/plugin install chrome-devtools-mcp@chrome-devtools-plugins

/plugin install gopls-lsp@claude-plugins-official
```

The grimoire includes a `chrome-devtools-private` MCP server (headless, telemetry-free). After installing `chrome-devtools-mcp`, disable its default server and use the private one instead.

`gopls-lsp` requires [`gopls`](https://pkg.go.dev/golang.org/x/tools/gopls).

## License

MIT
