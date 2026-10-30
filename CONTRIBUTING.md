# Contributing

Start with a focused issue describing the behavior and a small, anonymous reproduction. Do not attach employer documents, private URLs, personal annotation text, signing material, or credentials.

Use Swift 6 concurrency checking and retain macOS 14 and Universal compatibility. UI objects stay on the main actor; parsing, tokenization, file work, and annotation matching belong off it. Do not suppress concurrency warnings without documenting and testing an actual invariant.

Run `swift test`, native service checks, localization validation, and the relevant app tests before a pull request. Keep parser and resource boundary tests adversarial. Keep public fixtures original and deterministic. Use `swift format lint --recursive Sources Tests` for style review; format only files you change.

Explain the concrete before/after behavior and verification. Security, persistence, update trust, and migration changes need independent review. Dependency upgrades require real version locks, license review, and action SHA verification. Never add runtime engines for deferred features or silently broaden sandbox access.
