# Architecture

Continuum Chat has three explicit application components: a Flutter client, a Runtime service, and a Memory service. The mobile UI never owns canonical conversation history.

## Ownership

| Component | Responsibility | Owned state | Entry point |
| --- | --- | --- | --- |
| Flutter Android client | Chat UI, history/analytics views, memory CRUD UI, manual MCP tools, settings | Device-local connection/settings preferences | [`mobile/lib/app.dart`](../mobile/lib/app.dart) |
| Runtime | Chat API, provider streaming, canonical history, context epochs, usage aggregation, MCP transport | Runtime SQLite + ignored provider/MCP config | [`server/app.py`](../server/app.py) |
| Runtime SQLite | Conversations, epochs, messages, provider usage metadata | Canonical transcript/history | [`server/runtime_store.py`](../server/runtime_store.py) |
| Memory | Memory-card CRUD and deterministic lexical recall | Memory SQLite | [`memory/app.py`](../memory/app.py) |
| Memory SQLite | Memory cards and tags | Memory data | [`memory/store.py`](../memory/store.py) |

Memory is deliberately separate from Runtime so its persistence and retrieval strategy can evolve without changing the transcript contract or mobile memory CRUD API.

## Runtime flow

1. Flutter posts a user message to `/chat`.
2. Runtime persists it and loads the active context epoch.
3. Runtime sends that epoch's provider-visible messages to the configured provider.
4. Provider streaming is normalized into text, reasoning, tool, and usage events.
5. Runtime persists the canonical assistant message plus provider usage, then emits its own `done` SSE event.
6. History and calendar analytics are read back from Runtime SQLite.

Context rollover creates a new epoch for future provider context without deleting older persisted messages.

## Memory boundary

Memory cards are independent from the transcript. The baseline uses deterministic lexical overlap ranking so it can run without an embedding service.

The Flutter client talks directly to Memory for CRUD and recall. **Runtime does not automatically recall or inject Memory cards into chat.** The service boundary makes an embedding/reranking adapter possible later without changing the public mobile contract.

## MCP boundary

Runtime implements the MCP lifecycle over stdio. Tools are listed and invoked manually from the Flutter Tools screen; the baseline does **not** implement an automatic model tool-execution loop.

A separate `http` mode posts JSON-RPC payloads directly to a configured endpoint. It is a simple compatibility adapter, **not** a full MCP Streamable HTTP transport: it does not implement MCP HTTP session negotiation or SSE response handling. Use it only with endpoints that explicitly support that simpler contract.

The shipped filesystem example uses stdio, is disabled by default, and restricts access to a repository-local demo directory. MCP configuration is administrative because stdio entries name executables.

## Trade-offs

- **Single-user scope:** shared bearer authentication is intentionally smaller than a multi-tenant identity/authorization system.
- **SQLite:** favors inspectability and low setup cost over horizontal scaling.
- **Lexical memory recall:** favors deterministic offline behavior over semantic recall quality.
- **Manual MCP invocation:** exposes the stdio MCP lifecycle and security boundaries without hiding them inside an autonomous loop.
- **Separate Memory service:** adds one local process but keeps memory strategy replaceable and transcript ownership clear.

## Security boundary

Only health checks are intentionally public. Runtime data/chat/config/history/MCP endpoints and Memory data endpoints enforce the configured bearer token.

Both services default to loopback and reject non-loopback startup when the token is empty. CORS has no wildcard default. TLS, user accounts, rate limiting, multi-user authorization, and internet-grade abuse controls are outside this single-user reference scope.

See [Security](../SECURITY.md) and [Configuration](CONFIGURATION.md).
