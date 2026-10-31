# Changelog

## Unreleased — 0.1.0

Initial native MarkUp reader implementation: CommonMark/GFM, semantic alerts, language-aware highlighting, independent themes and typography, English/Turkish controls, navigation, persistent annotations, file monitoring, PDF/printing, sandboxed resource handling, and Sparkle distribution preparation.

Code blocks now group their language and icon controls inside a rounded code surface. Long blocks can be limited to a short visual preview or fully expanded; full-source copy and PDF output remain unchanged.

The left minimap now previews actual rendered text, syntax colors, tables and loaded images with uniform scaling, bounded cached tiles and click/drag navigation. Its content is composited at 70% opacity to reduce distraction. Inline code uses appearance-aware red text and softly rounded neutral backgrounds in the reader.

This entry describes development scope, not a published release. Executed checks and outstanding gates are tracked in `docs/VERIFICATION.md`.
