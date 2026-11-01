# Changelog

## Unreleased — 0.1.0

Initial native MarkUp reader implementation: CommonMark/GFM, semantic alerts, language-aware highlighting, independent themes and typography, English/Turkish controls, navigation, persistent annotations, file monitoring, PDF/printing, sandboxed resource handling, and Sparkle distribution preparation.

Code blocks now group their language and icon controls inside a rounded code surface. Long blocks open in a short view by default (configurable in Settings → Code): each shows twelve and a half rows inside its own natively scrolling area, with the cut-off last row fading out while more code remains. A scroll that starts over the block moves the code until its edge; one that starts elsewhere keeps scrolling the page. Blocks can still be fully expanded; full-source copy and PDF output remain unchanged.

The minimap now previews actual rendered text, syntax colors, tables and loaded images with uniform scaling, bounded cached tiles and click/drag navigation. Its content is composited at 70% opacity to reduce distraction. Inline code uses appearance-aware red text and softly rounded neutral backgrounds in the reader.

The outline and minimap now float in the reader's left and right margins instead of narrowing it, so toggling them no longer reflows the document; each is offered only when the window leaves enough room beside the text. A new Preview/Source toggle in the toolbar switches to syntax-colored raw Markdown while keeping the reading position. Changing preferences no longer nudges the document upward. When local images need a folder grant, the status bar offers Grant Folder Access…, opening at the document's folder.

The app icon now uses the owner-supplied blue book artwork; build 2 prepares the first local Developer ID distribution.

Debug builds are now a separate test environment, MarkUp Dev, with its own bundle ID and sandbox data, an orange DEV icon badge and a DEV label in the status bar; it never checks for updates.

This entry describes development scope, not a published release. Executed checks and outstanding gates are tracked in `docs/VERIFICATION.md`.
