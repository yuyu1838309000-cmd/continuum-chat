from __future__ import annotations

import json
import os
from dataclasses import asdict, dataclass
from pathlib import Path
from typing import Any, AsyncIterator
from urllib.parse import urlparse

import httpx


@dataclass(slots=True)
class ProviderConfig:
    base_url: str = "mock://local"
    model: str = "continuum-mock"
    api_key: str = ""
    endpoint: str = "/chat/completions"

    @classmethod
    def load(cls, path: Path) -> "ProviderConfig":
        values: dict[str, Any] = {}
        if path.exists():
            values = json.loads(path.read_text(encoding="utf-8"))
        return cls(
            base_url=os.getenv("CONTINUUM_PROVIDER_BASE_URL")
            or values.get("base_url", "mock://local"),
            model=os.getenv("CONTINUUM_PROVIDER_MODEL")
            or values.get("model", "continuum-mock"),
            api_key=os.getenv("CONTINUUM_PROVIDER_API_KEY", values.get("api_key", "")),
            endpoint=os.getenv("CONTINUUM_PROVIDER_ENDPOINT")
            or values.get("endpoint", "/chat/completions"),
        )

    def validate(self) -> None:
        if not self.model.strip():
            raise ValueError("Provider model is required")
        if not self.endpoint.startswith("/"):
            raise ValueError("Provider endpoint must start with /")
        if self.base_url.startswith("mock://"):
            return
        parsed = urlparse(self.base_url)
        if parsed.scheme not in {"http", "https"} or not parsed.netloc:
            raise ValueError("Provider base URL must be mock:// or an http(s) URL")

    def public_dict(self, include_secret: bool = False) -> dict[str, Any]:
        result = asdict(self)
        if not include_secret:
            result["api_key"] = "" if not self.api_key else "configured"
        return result

    def save(self, path: Path) -> None:
        self.validate()
        path.parent.mkdir(parents=True, exist_ok=True)
        temporary = path.with_suffix(path.suffix + ".tmp")
        temporary.write_text(json.dumps(asdict(self), indent=2) + "\n", encoding="utf-8")
        temporary.chmod(0o600)
        temporary.replace(path)
        path.chmod(0o600)


@dataclass(slots=True)
class ProviderEvent:
    type: str
    data: Any


async def _sse_data(lines: AsyncIterator[str]) -> AsyncIterator[str]:
    data_lines: list[str] = []
    async for line in lines:
        if line == "":
            if data_lines:
                yield "\n".join(data_lines)
                data_lines.clear()
            continue
        if line.startswith("data:"):
            data_lines.append(line[5:].lstrip(" "))
    if data_lines:
        yield "\n".join(data_lines)


def _provider_events(chunk: dict[str, Any]) -> list[ProviderEvent]:
    if error := chunk.get("error"):
        detail = error.get("message") if isinstance(error, dict) else error
        raise RuntimeError(f"Provider stream error: {detail}")

    events: list[ProviderEvent] = []
    if usage := chunk.get("usage"):
        if not isinstance(usage, dict):
            raise RuntimeError("Provider stream returned invalid usage metadata")
        events.append(ProviderEvent("usage", usage))
    choices = chunk.get("choices", [])
    if not isinstance(choices, list):
        raise RuntimeError("Provider stream returned invalid choices")
    for choice in choices:
        if not isinstance(choice, dict) or not isinstance(choice.get("delta", {}), dict):
            raise RuntimeError("Provider stream returned an invalid choice delta")
        delta = choice.get("delta", {})
        if text := delta.get("content"):
            events.append(ProviderEvent("text", text))
        if reasoning := delta.get("reasoning_content") or delta.get("reasoning"):
            events.append(ProviderEvent("reasoning", reasoning))
        if tool_calls := delta.get("tool_calls"):
            events.append(ProviderEvent("tool", tool_calls))
    return events


class ChatProvider:
    def __init__(self, config: ProviderConfig):
        self.config = config

    async def stream(self, messages: list[dict[str, str]]) -> AsyncIterator[ProviderEvent]:
        self.config.validate()
        if self.config.base_url.startswith("mock://"):
            prompt = messages[-1]["content"] if messages else ""
            text = f"Mock response: {prompt.strip()}"
            for word in text.split(" "):
                yield ProviderEvent("text", word + " ")
            yield ProviderEvent(
                "usage",
                {"prompt_tokens": len(prompt.split()), "completion_tokens": len(text.split())},
            )
            return

        url = f"{self.config.base_url.rstrip('/')}/{self.config.endpoint.lstrip('/')}"
        headers = {"Accept": "text/event-stream"}
        if self.config.api_key:
            headers["Authorization"] = f"Bearer {self.config.api_key}"
        payload = {"model": self.config.model, "messages": messages, "stream": True,
                   "stream_options": {"include_usage": True}}
        async with httpx.AsyncClient(timeout=60) as client:
            async with client.stream("POST", url, json=payload, headers=headers) as response:
                response.raise_for_status()
                async for raw in _sse_data(response.aiter_lines()):
                    if raw == "[DONE]":
                        break
                    chunk = json.loads(raw)
                    if not isinstance(chunk, dict):
                        raise RuntimeError("Provider stream returned a non-object event")
                    for event in _provider_events(chunk):
                        yield event