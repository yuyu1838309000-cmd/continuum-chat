# Configuration

## Runtime environment

| Variable | Default | Purpose |
| --- | --- | --- |
| `CONTINUUM_BIND` | `127.0.0.1` | Runtime bind address |
| `CONTINUUM_PORT` | `8816` | Runtime port |
| `CONTINUUM_DATA_DIR` | `./data` | Runtime SQLite directory |
| `CONTINUUM_API_TOKEN` | empty | Shared bearer token; required off loopback |
| `CONTINUUM_MEMORY_URL` | `http://127.0.0.1:8820` | Runtime-side Memory URL |
| `CONTINUUM_PROVIDER_CONFIG` | `./config/provider.json` | Ignored provider config |
| `CONTINUUM_MCP_CONFIG` | `./config/mcp.json` | Ignored MCP config |
| `CONTINUUM_CORS_ORIGINS` | empty | Comma-separated allowed origins |

Provider values can be overridden with `CONTINUUM_PROVIDER_BASE_URL`, `CONTINUUM_PROVIDER_MODEL`, `CONTINUUM_PROVIDER_API_KEY`, and `CONTINUUM_PROVIDER_ENDPOINT`.

## Memory environment

`CONTINUUM_MEMORY_BIND` defaults to `127.0.0.1`; `CONTINUUM_MEMORY_PORT` defaults to `8820`; `CONTINUUM_MEMORY_DATA_DIR` defaults to `./data`. Memory uses the same `CONTINUUM_API_TOKEN`.

## Local configuration

Copy `config/provider.example.json` to ignored `config/provider.json`. Copy `examples/mcp_config.example.json` to ignored `config/mcp.json`. Files changed through Runtime are written owner-only.

Stdio MCP entries require a `command` and a string `args` list. Stdio is intentionally powerful: it executes that command with the Runtime process account and has no Continuum Chat sandbox. The repository example is disabled and limits its filesystem server to `mcp-demo-workspace`.

The optional `transport: "http"` mode accepts an `http://` or `https://` `url` plus string-to-string headers and posts JSON-RPC requests directly. It is a simple compatibility adapter, not a full MCP Streamable HTTP implementation: no MCP HTTP session negotiation or SSE response handling is provided. Use it only with endpoints that explicitly support that contract.

Mobile Settings exposes scheme, host, Runtime port, Memory port, bearer token, provider configuration, and MCP JSON. The emulator host default is `10.0.2.2`.

## Physical phone

Both services bind to loopback by default. To expose them to a phone on a trusted LAN or secure tunnel, set a strong shared bearer token and bind both services explicitly:

```bash
export CONTINUUM_BIND=0.0.0.0
export CONTINUUM_MEMORY_BIND=0.0.0.0
export CONTINUUM_API_TOKEN='choose-a-long-random-value'
```

Start Runtime and Memory with the same environment, then enter the host address, ports `8816` / `8820`, and the same token in mobile Settings.

Debug Android builds permit cleartext HTTP for local development. For use outside a trusted private network, prefer HTTPS through a trusted reverse proxy or secure tunnel; production-grade internet exposure is outside this reference application's scope. See [Security](../SECURITY.md).

Never commit generated local configs, environment files, databases, logs, builds, or signing material.

## Windows Android builds on another drive

If the project lives on a different drive from the global Flutter Pub Cache (for example project on D:/E: and cache on C:), Kotlin incremental compilation can fail while compiling Flutter plugins because the source roots are on different drives. The public Android project disables Kotlin incremental compilation in android/gradle.properties so a fresh clone builds reliably across drives. This trades a little incremental build speed for reproducibility; it does not change runtime behavior.