#!/usr/bin/env python3
from __future__ import annotations

import ipaddress
import os
import re
import subprocess
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent

PRIVATE_DENYLIST = ROOT / ".privacy-denylist"
REPO_TOKEN_PREFIX = "github_" + "pat_"

TEXT_SUFFIXES = {
    ".py", ".dart", ".kt", ".kts", ".java", ".json", ".yaml", ".yml", ".md",
    ".txt", ".xml", ".gradle", ".properties", ".sh", ".toml", ".lock",
}
TEXT_NAMES = {
    ".gitignore", ".env.example", "LICENSE", "README.md", "SECURITY.md",
    "CONTRIBUTING.md", "requirements.txt",
}
FORBIDDEN_SUFFIXES = {
    ".sqlite", ".sqlite3", ".db", ".log", ".apk", ".aab", ".jks", ".keystore",
    ".pem", ".p12", ".pfx", ".key",
}
FORBIDDEN_DIRS = {"data", "backups", "private", "secrets", "build", ".dart_tool"}

ALLOWED_IPV4 = (
    ipaddress.ip_network("127.0.0.0/8"),
    ipaddress.ip_network("192.0.2.0/24"),
    ipaddress.ip_network("198.51.100.0/24"),
    ipaddress.ip_network("203.0.113.0/24"),
)
IPV4_RE = re.compile(r"(?<!\d)(?:\d{1,3}\.){3}\d{1,3}(?!\d)")
PROVIDER_SECRET_RE = re.compile(r"(?<![A-Za-z0-9])sk-[A-Za-z0-9_-]{20,}")
CRED_GIT_RE = re.compile(
    r"https?://[^/\s:@]+:[^@\s/]+@(?:github\.com|gitlab\.com|bitbucket\.org)",
    re.I,
)
MACHINE_PATH_RE = re.compile(
    r"(?<![A-Za-z0-9_.-])(?:/home/[A-Za-z0-9_.-]+|/Users/[A-Za-z0-9_.-]+|"
    r"[A-Za-z]:\\\\Users\\\\[A-Za-z0-9_.-]+)(?:[/\\\\]|$)"
)
ASSIGN_RE = re.compile(
    r"""(?ix)["']?(api[_-]?key|access[_-]?token|auth[_-]?token|password|secret)["']?
    \s*[:=]\s*["']([^"']{8,})["']"""
)
PLACEHOLDERS = {
    "configured", "example", "example-token", "test-token", "changeme",
    "replace-me", "your-token", "your-api-key", "choose-a-long-random-value",
}


def private_markers() -> tuple[str, ...]:
    """Load release-specific markers without storing them in the repository."""
    values = os.getenv("CONTINUUM_PRIVACY_DENYLIST", "").split(",")
    if PRIVATE_DENYLIST.exists():
        values.extend(PRIVATE_DENYLIST.read_text(encoding="utf-8").splitlines())
    return tuple(
        value.strip().casefold()
        for value in values
        if value.strip() and not value.lstrip().startswith("#")
    )


def candidates() -> list[Path]:
    result = subprocess.run(
        ["git", "ls-files", "-co", "--exclude-standard", "-z"],
        cwd=ROOT,
        check=True,
        stdout=subprocess.PIPE,
    )
    files: list[Path] = []
    for raw in result.stdout.split(b"\0"):
        if not raw:
            continue
        path = ROOT / raw.decode("utf-8", "surrogateescape")
        if path.is_file():
            files.append(path)
    return files


def is_text(path: Path) -> bool:
    return path.suffix.lower() in TEXT_SUFFIXES or path.name in TEXT_NAMES


def allowed_ip(value: str) -> bool:
    try:
        ip = ipaddress.ip_address(value)
    except ValueError:
        return True
    if ip.is_unspecified or ip == ipaddress.ip_address("10.0.2.2"):
        return True
    return any(ip in network for network in ALLOWED_IPV4)


def main() -> int:
    files = candidates()
    banned = private_markers()
    issues: list[str] = []
    for path in files:
        rel = path.relative_to(ROOT)
        parts = {part.casefold() for part in rel.parts}
        suffix = path.suffix.lower()
        if rel.name == ".env" or suffix in FORBIDDEN_SUFFIXES:
            issues.append(f"forbidden artifact: {rel}")
            continue
        if parts & FORBIDDEN_DIRS:
            issues.append(f"forbidden tracked directory: {rel}")
            continue
        if not is_text(path):
            continue

        text = path.read_text(encoding="utf-8", errors="ignore")
        folded = text.casefold()

        if any(marker in folded for marker in banned):
            issues.append(f"private identifier: {rel}")
        if MACHINE_PATH_RE.search(text):
            issues.append(f"machine-specific path: {rel}")
        if REPO_TOKEN_PREFIX in text:
            issues.append(f"repository token prefix: {rel}")
        if PROVIDER_SECRET_RE.search(text):
            issues.append(f"provider secret pattern: {rel}")
        if CRED_GIT_RE.search(text):
            issues.append(f"credential-bearing git URL: {rel}")

        for match in ASSIGN_RE.finditer(text):
            value = match.group(2).strip().casefold()
            if value and value not in PLACEHOLDERS and not value.startswith(
                ("example-", "test-", "your-")
            ):
                issues.append(f"credential-like literal assignment: {rel}")
                break

        for match in IPV4_RE.finditer(text):
            value = match.group(0)
            if not allowed_ip(value):
                issues.append(f"non-documentation IPv4 address {value}: {rel}")
                break
    if issues:
        print("Privacy scan FAILED:")
        for issue in sorted(set(issues)):
            print(f" - {issue}")
        return 1

    print(f"Privacy scan passed: {len(files)} public/trackable files checked.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())