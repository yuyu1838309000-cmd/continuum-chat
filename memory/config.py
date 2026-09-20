from __future__ import annotations

import os
import ipaddress
from dataclasses import dataclass, field
from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parent.parent


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
        default_factory=lambda: Path(
            os.getenv("CONTINUUM_MEMORY_DATA_DIR", str(REPO_ROOT / "data"))
        )
    )
    port: int = field(
        default_factory=lambda: int(os.getenv("CONTINUUM_MEMORY_PORT", "8820"))
    )
    bind: str = field(
        default_factory=lambda: os.getenv("CONTINUUM_MEMORY_BIND", "127.0.0.1")
    )
    api_token: str = field(
        default_factory=lambda: os.getenv("CONTINUUM_API_TOKEN", "")
    )

    def validate(self) -> None:
        if not _is_loopback(self.bind) and not self.api_token:
            raise RuntimeError(
                "CONTINUUM_API_TOKEN is required when CONTINUUM_MEMORY_BIND is not loopback"
            )
        self.data_dir.mkdir(parents=True, exist_ok=True)