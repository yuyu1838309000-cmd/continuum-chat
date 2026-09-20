from __future__ import annotations

import ipaddress
import os
from dataclasses import dataclass, field
from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parent.parent


def _env(name: str, default: str) -> str:
    return os.getenv(f"CONTINUUM_{name}", default)


def _is_loopback(host: str) -> bool:
    if host.lower() == "localhost":
        return True
    try:
        return ipaddress.ip_address(host).is_loopback
    except ValueError:
        return False


@dataclass(frozen=True, slots=True)
class Settings:
    data_dir: Path = field(
        default_factory=lambda: Path(_env("DATA_DIR", str(REPO_ROOT / "data")))
    )
    bind: str = field(default_factory=lambda: _env("BIND", "127.0.0.1"))
    port: int = field(default_factory=lambda: int(_env("PORT", "8816")))
    memory_url: str = field(
        default_factory=lambda: _env("MEMORY_URL", "http://127.0.0.1:8820")
    )
    provider_config: Path = field(
        default_factory=lambda: Path(
            _env("PROVIDER_CONFIG", str(REPO_ROOT / "config" / "provider.json"))
        )
    )
    mcp_config: Path = field(
        default_factory=lambda: Path(
            _env("MCP_CONFIG", str(REPO_ROOT / "config" / "mcp.json"))
        )
    )
    api_token: str = field(default_factory=lambda: _env("API_TOKEN", ""))
    cors_origins: tuple[str, ...] = field(
        default_factory=lambda: tuple(
            value.strip()
            for value in _env("CORS_ORIGINS", "").split(",")
            if value.strip()
        )
    )

    def validate(self) -> None:
        if not _is_loopback(self.bind) and not self.api_token:
            raise RuntimeError(
                "CONTINUUM_API_TOKEN is required when CONTINUUM_BIND is not loopback"
            )
        self.data_dir.mkdir(parents=True, exist_ok=True)