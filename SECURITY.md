# Security

Continuum Chat is a self-hosted single-user reference application.

Both Python services bind to loopback by default. If either is configured with a non-loopback bind address, startup requires `CONTINUUM_API_TOKEN`. Configure the same strong random value in Runtime, Memory, and the mobile client.

For use beyond a trusted private network, place the services behind HTTPS and an authentication-aware reverse proxy or secure tunnel. The sample does not implement multi-user authorization, rate limiting, or internet-grade abuse controls.

MCP configuration is administrative: a stdio entry runs a local executable with the full permissions of the Runtime process account. Continuum Chat does not sandbox that process. Only trusted operators should edit MCP configuration or enable commands. The public example is disabled and restricts its filesystem server to `mcp-demo-workspace`; keep that restriction unless you explicitly intend to expose more files.

Do not commit provider keys, bearer tokens, local configs, environment files, signing material, databases, logs, or builds. Run `python3 scripts/privacy_scan.py` before every public release.

Report security issues through a private GitHub security advisory rather than a public issue containing exploit details or credentials.