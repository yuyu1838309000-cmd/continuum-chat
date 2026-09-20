# Privacy model

The public repository is designed to stand on its own and starts from fresh Git history rather than relying on deletions from a private history.

## Local-only data

Runtime transcripts, provider usage, memory cards, provider credentials, MCP configuration, bearer tokens, logs, builds, and signing material are runtime state. Git ignore rules exclude their normal locations and file types.

The Android app ships no private server address, provider credential, transcript, or memory database. Connection settings are entered by the user and stored on that device.

## Automated public-release gate

`scripts/privacy_scan.py` scans files Git would track and rejects categories including machine-specific home paths, likely credentials, credential-bearing Git URLs, non-documentation host IPv4 addresses, runtime databases/logs/packages, signing material, and private-data directories. Release-specific names or identifiers can be supplied without committing them: put one marker per line in the ignored `.privacy-denylist` file, or pass a comma-separated `CONTINUUM_PRIVACY_DENYLIST` value.

The scanner is defense in depth, not a substitute for human review. Before publication, inspect `git status`, run the scanner, and review the first commit.