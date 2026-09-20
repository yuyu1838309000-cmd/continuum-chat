# Contributing

Keep changes focused, generic, and safe for a public repository.

Before opening a pull request:

```bash
python3 -m py_compile server/*.py memory/*.py
python3 -m unittest discover -s . -p 'test_*.py'
python3 scripts/privacy_scan.py
git diff --check
cd mobile
dart format --output=none --set-exit-if-changed lib test
flutter analyze
flutter test
```

Never commit local data, credentials, APKs, signing material, logs, or generated runtime configuration. Changes to authentication, MCP transports, provider credential handling, or network defaults require explicit security review.