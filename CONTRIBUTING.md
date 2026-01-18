# Contributing to Peyk-D

We welcome contributions that strengthen resiliency, correct protocol handling, or improve documentation.

## Getting started

1. Fork and clone this repo.  
2. Run the Go server (`go run server/main.go`) and Flutter client (`flutter run` with your device).  
3. Reproduce the issue or implement the feature in a feature branch.

## Standards

- Keep DNS packets RFC-compliant (no invalid label lengths).  
- Preserve compatibility with legacy frames while extending the protocol.  
- Document new settings/error states in `README.md`.  
- Run `go test ./...` and `flutter test`/`flutter analyze` before pushing.

## Styling

- Go files: `gofmt` before committing.  
- Dart files: `dart format`.  
- Markdown: keep ASCII characters; explain new features/settings.

## Pull requests

1. Open PR against `main`.  
2. Include changelog entry if user-visible (settings, UI, API).  
3. Link related issues or tickets.  
4. Mention tests run (`go test`, `flutter analyze`, etc.).

## Security

Handle secrets via env variables or `--dart-define`; do not commit plaintext passphrases or domains.
