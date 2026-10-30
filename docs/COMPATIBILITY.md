# V1 compatibility

The execution matrix and remaining validation gates are in [VERIFICATION.md](VERIFICATION.md). Support in this table describes implementation, not execution on every supported OS.

| Content or operation | Behavior |
| --- | --- |
| CommonMark | Swift Markdown/cmark parser; headings, emphasis, links, nested lists/quotes, fenced/indented code and thematic breaks |
| GFM | Tables, strikethrough, read-only task markers and autolinks |
| GitHub alerts | NOTE, TIP, IMPORTANT, WARNING and CAUTION with labels/icons; nested content retained |
| Footnotes | Readable references, definitions and internal destinations |
| YAML frontmatter | Visible metadata block; never executed as configuration |
| HTML/details | Readable safe fallback; no browser, scripts, event handlers or embedded applications |
| Mermaid, math and MDX | Readable source; no execution/diagram engine |
| Code | Offline language grammars; unknown languages remain copyable plain text; integrated rounded panels with per-block wrap, line numbers, horizontal scrolling and an optional height limit |
| Themes | Six families / nine original palettes; independent from application appearance |
| Images | Platform-decoded bounded raster data; local resources need explicit folder access; remote loading is opt-in; double-click loaded images for a resizable preview |
| Wide tables | Local horizontal scrolling on screen; print pipeline wraps/flows long rows and repeats labels |
| Copy | One native selection surface across prose/code/tables; line numbers and control labels are excluded |
| Annotations | Local durable highlights/underlining, undo/redo, conservative reattachment and explicit orphan recovery |
| PDF | Selectable native text, A4/Letter, margins/orientation, opt-in personal marks, links/bookmarks, cancellation and atomic final write |
| Printing | Native print dialog after shared asynchronous PDF preparation; no silent printer submission |
| Languages | English first launch; explicit persisted Turkish; document content/font/language identifiers unchanged |
| Files | `.md` / `.markdown`; UTF-8 with optional BOM, BOM-marked UTF-16 LE/BE, preserved CRLF/LF; invalid/binary input rejected |

## Deliberate limits

A source file is limited to 16 MiB and parser nesting to 32. Syntax work falls back to plain text beyond 65,536 characters per block or 16,384 characters per line; source and copy remain intact. Images have transfer/decode/cache limits and a document-wide budget; unavailable images keep descriptive alt text. Search displays at most 10,000 matches. These limits protect untrusted input and are not truncation of the source file.

System-owned controls, the print dialog and Sparkle supply their own accessibility and localization. Restart after switching app language when a system-owned menu/dialog retains its old language. MarkUp never changes the system language.

The application targets macOS 14+ and includes both arm64 and x86_64. The native toolbar adopts current system materials. No unguarded macOS 26 custom-glass API is used. Older OS and physical Intel runtime checks require additional machines; a Universal build alone does not establish them.
