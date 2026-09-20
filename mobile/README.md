# Continuum Chat mobile

Flutter Android client for the Continuum Chat Runtime and Memory services.

See the root [README](../README.md) for the full local setup and backend smoke test. The Android emulator defaults to Runtime `10.0.2.2:8816` and Memory `10.0.2.2:8820`; connection, provider, bearer-token, and MCP settings are editable in the app.

## Development

```bash
flutter pub get
flutter analyze
flutter test
flutter build apk --debug
```

CI uses Flutter 3.44.8. Release signing is intentionally not bundled; configure your own signing material before distribution.
