from __future__ import annotations

import asyncio
import json
from dataclasses import dataclass
from pathlib import Path
from typing import Any
from urllib.parse import urlparse

import httpx


def _validate_config(config: dict[str, Any]) -> dict[str, Any]:
    if not isinstance(config, dict):
        raise ValueError("MCP config must be a JSON object")
    servers = config.get("servers", {})
    if not isinstance(servers, dict):
        raise ValueError("MCP config must contain a servers object")
    for name, server in servers.items():
        if not isinstance(name, str) or not name.strip():
            raise ValueError("MCP server names must be non-empty strings")
        if not isinstance(server, dict):
            raise ValueError(f"MCP server {name!r} must be an object")
        if not isinstance(server.get("enabled", False), bool):
            raise ValueError(f"MCP server {name!r} enabled must be a boolean")
        transport = server.get("transport")
        if transport == "http":
            url = server.get("url")
            parsed = urlparse(url) if isinstance(url, str) else None
            if parsed is None or parsed.scheme not in {"http", "https"} or not parsed.netloc:
                raise ValueError(f"HTTP MCP server {name!r} requires an http(s) URL")
            headers = server.get("headers", {})
            if not isinstance(headers, dict) or not all(
                isinstance(key, str) and isinstance(value, str)
                for key, value in headers.items()
            ):
                raise ValueError(f"HTTP MCP server {name!r} headers must be strings")
        elif transport == "stdio":
            command = server.get("command")
            args = server.get("args", [])
            if not isinstance(command, str) or not command.strip():
                raise ValueError(f"stdio MCP server {name!r} requires a command")
            if not isinstance(args, list) or not all(isinstance(arg, str) for arg in args):
                raise ValueError(f"stdio MCP server {name!r} args must be strings")
        else:
            raise ValueError(f"Unsupported MCP transport for {name!r}: {transport}")
    return servers


@dataclass(slots=True)
class McpClient:
    config_path: Path

    def load(self) -> dict[str, Any]:
        if not self.config_path.exists():
            return {"servers": {}}
        return json.loads(self.config_path.read_text(encoding="utf-8"))

    def save(self, config: dict[str, Any]) -> None:
        _validate_config(config)
        self.config_path.parent.mkdir(parents=True, exist_ok=True)
        temporary = self.config_path.with_suffix(self.config_path.suffix + ".tmp")
        temporary.write_text(json.dumps(config, indent=2) + "\n", encoding="utf-8")
        temporary.chmod(0o600)
        temporary.replace(self.config_path)
        self.config_path.chmod(0o600)

    async def request(self, server_name: str, method: str, params: dict[str, Any]) -> Any:
        config = _validate_config(self.load()).get(server_name)
        if not config or not config.get("enabled", False):
            raise ValueError(f"MCP server is missing or disabled: {server_name}")
        request = {"jsonrpc": "2.0", "id": 1, "method": method, "params": params}
        transport = config.get("transport")
        try:
            if transport == "http":
                async with httpx.AsyncClient(timeout=20) as client:
                    response = await client.post(
                        config["url"], json=request, headers=config.get("headers", {})
                    )
                    response.raise_for_status()
                    result = response.json()
            else:
                result = await self._stdio_request(
                    config["command"], config.get("args", []), method, params
                )
        except (httpx.HTTPError, OSError, json.JSONDecodeError) as error:
            raise RuntimeError(f"MCP transport failed: {error}") from error
        if not isinstance(result, dict):
            raise RuntimeError("MCP server returned a non-object JSON-RPC response")
        if "error" in result:
            raise RuntimeError(str(result["error"]))
        return result.get("result")

    async def _stdio_request(
        self, command: str, args: list[Any], method: str, params: dict[str, Any]
    ) -> dict[str, Any]:
        process = await asyncio.create_subprocess_exec(
            command,
            *(str(arg) for arg in args),
            stdin=asyncio.subprocess.PIPE,
            stdout=asyncio.subprocess.PIPE,
            stderr=asyncio.subprocess.PIPE,
        )
        assert process.stdin is not None
        assert process.stdout is not None
        assert process.stderr is not None

        async def send(payload: dict[str, Any]) -> None:
            process.stdin.write((json.dumps(payload) + "\n").encode())
            await process.stdin.drain()

        async def receive(response_id: int) -> dict[str, Any]:
            while line := await process.stdout.readline():
                decoded = json.loads(line)
                if decoded.get("id") == response_id:
                    return decoded
            detail = (await process.stderr.read()).decode(errors="replace")[:500]
            raise RuntimeError(detail or "MCP server returned no response")

        try:
            await send(
                {
                    "jsonrpc": "2.0",
                    "id": 1,
                    "method": "initialize",
                    "params": {
                        "protocolVersion": "2025-06-18",
                        "capabilities": {},
                        "clientInfo": {"name": "continuum-chat", "version": "0.1.0"},
                    },
                }
            )
            initialized = await asyncio.wait_for(receive(1), timeout=20)
            if "error" in initialized:
                raise RuntimeError(str(initialized["error"]))
            await send(
                {
                    "jsonrpc": "2.0",
                    "method": "notifications/initialized",
                    "params": {},
                }
            )
            await send(
                {
                    "jsonrpc": "2.0",
                    "id": 2,
                    "method": method,
                    "params": params,
                }
            )
            return await asyncio.wait_for(receive(2), timeout=20)
        finally:
            process.stdin.close()
            if process.returncode is None:
                process.terminate()
                try:
                    await asyncio.wait_for(process.wait(), timeout=2)
                except asyncio.TimeoutError:
                    process.kill()
                    await process.wait()

    async def tools(self) -> list[dict[str, Any]]:
        output: list[dict[str, Any]] = []
        for name, config in _validate_config(self.load()).items():
            if not config.get("enabled", False):
                continue
            result = await self.request(name, "tools/list", {})
            if not isinstance(result, dict) or not isinstance(result.get("tools"), list):
                raise RuntimeError(f"MCP server {name!r} returned an invalid tools list")
            for tool in result["tools"]:
                if not isinstance(tool, dict):
                    raise RuntimeError(f"MCP server {name!r} returned an invalid tool")
                output.append({**tool, "server": name})
        return output