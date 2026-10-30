# Offline syntax highlighting

MarkUp vendors the unmodified CommonJS core and 21 selected language files from
**highlight.js 11.12.0**, released under **BSD-3-Clause**. The full license is in
`highlight.js-BSD-3-Clause.txt`; `highlight.js-manifest.json` records the exact archive
and per-file SHA-256 hashes. Upstream: https://github.com/highlightjs/highlight.js
API reference: https://highlightjs.readthedocs.io/en/latest/api.html

These JavaScript resources run only in Apple's JavaScriptCore. They have no DOM,
network bridge, file bridge, Node.js runtime, package manager, or document evaluation.
Document source is passed as a function argument. The MarkUp-authored emitter produces
UTF-16 ranges directly; its `toHTML()` returns an empty string. No HTML parsing,
escaping, or source reconstruction is involved in highlighting.

The grammar/emitter interface is pinned, including the upstream `__emitter` extension
interface. Updating upstream requires reviewing that interface and running the
language/source-preservation/adversarial tests. Do not replace individual assets
without also updating the version, archive hash, per-file hashes, and license review.
The app loads the VM on the first recognized code fence and grammar files on demand.
JS/TS/HTML/Markdown load a small explicit HTML/CSS/JS dependency set. Unknown identifiers,
plain text, and Mermaid deliberately remain readable plain code.

Tokenization permits up to 65,536 UTF-16 units per code fence, 16,384 per line,
and 30,000 styled spans. The emitter checks cancellation and a 150 ms elapsed-work
budget at token boundaries. These cooperative checks cannot preempt a single native
regular-expression match; input caps reduce exposure, and oversized or interrupted
blocks retain their exact source with plain styling. Callers must treat these errors
as recoverable styling failures. JavaScriptCore is confined to a background Swift
actor and is released on reader close/memory pressure. There is no theme-specific
tokenization, so changing themes can reuse token ranges.

Theme palettes are original MarkUp definitions inspired by the requested editor
families. Names identify familiar color families and do not imply endorsement or
official affiliation. No third-party stylesheet or theme source is bundled.

## Reproducing the vendored files

Download the archive URL in `highlight.js-manifest.json` and verify its SHA-256.
Extract `package/lib/core.js` as `hljs-core.js` and the listed
`package/lib/languages/<language>.js` as `hljs-<language>.js`, preserving bytes.
Copy `package/LICENSE`. `markup-token-emitter.js` is MarkUp-owned adapter code.
Verify all asset hashes from the manifest and run `swift test --filter HighlightingTests`.
