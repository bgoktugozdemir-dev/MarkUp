#!/usr/bin/env python3
"""Generate original public fixtures; never reads private examples."""
from pathlib import Path
import struct
import zlib

root = Path(__file__).resolve().parent.parent / "Fixtures"
root.mkdir(exist_ok=True)
images = root / "images"
images.mkdir(exist_ok=True)

def png(path, color):
    width, height = 240, 120
    raw = b"".join(b"\0" + bytes(color) * width for _ in range(height))
    def chunk(kind, payload):
        return struct.pack(">I", len(payload)) + kind + payload + struct.pack(">I", zlib.crc32(kind + payload) & 0xffffffff)
    path.write_bytes(b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">2I5B", width, height, 8, 2, 0, 0, 0)) + chunk(b"IDAT", zlib.compress(raw)) + chunk(b"IEND", b""))

png(images / "blue.png", (70, 130, 200))
png(images / "green.png", (80, 170, 120))
lines = []
for section in range(96):
    lines += [f"## {section + 1:02d} · Reading section — Bölüm", "", "This original example explores clear documentation, reliable navigation, and careful reading. Unicode stays intact: Türkçe İı Şş Ğğ, 日本語, العربية, 😀, é.", ""]
    if section < 90:
        language = "swift" if section < 72 else ("bash" if section < 78 else "json" if section < 84 else "text")
        snippets = {
            "swift": ["@Observable", f"final class Chapter{section} {{", '    var title = "A quiet place to read"', "    let values: [String: Int] = [:]", "    func render<T>(_ value: T) -> String {", '        // Selection must preserve the original indentation.', '        return "Value: \\(value)"', "    }", "}"],
            "bash": ["#!/bin/bash", "set -euo pipefail", 'printf "%s\\n" "Hello, documentation"'],
            "json": ['{', '  "name": "MarkUp",', '  "reader": true', '}'],
            "text": ["Plain source is never executed.", "Long blocks remain readable and selectable."]}
        lines += [f"```{language}"] + snippets[language] + ["```", ""]
    if section < 35:
        lines += ["| Feature | Behavior | Result |", "| :--- | :---: | ---: |", "| `Reader<T>` | **Native** text | 42 |", "| Escaped \\| pipe | [Example](https://example.com) | ✓ |", ""]
    if section < 11:
        lines += ["![Original color sample](images/blue.png)", ""]
    if section == 11:
        lines += ["| Side by side | Two local images |", "| --- | --- |", "| ![Blue](images/blue.png) | ![Green](images/green.png) |", ""]
    lines += ["> [!NOTE]", "> Read at your own pace. The source remains unchanged.", "", "- A short list", "  - Nested context", "- [x] Read-only completed task", "- [ ] Read-only pending task", ""]
# Add independent prose bytes without changing the required line count/structure.
for index, line in enumerate(lines):
    if line.startswith("This original example"):
        lines[index] += " Clear documentation supports careful review, predictable navigation, and faithful text selection." * 7
while len(lines) < 2499:
    lines.append("A measured reading experience retains context during resizing, theme changes, and live reload.")
lines.append("END-OF-REPRESENTATIVE-DOCUMENT — Son satır.")
(root / "long-reading.md").write_text("\n".join(lines) + "\n")
(root / "review.md").write_text('''# Review fixture

## `Sources/Modules/Rendering/VeryLongPath/File.swift` and `<Widget type="sample">`

| Area | Owner | State | Input | Output | Notes |
| --- | --- | --- | --- | --- | --- |
| Reader | Example | Ready | `a\\|b` | **Native** | [Guide](#guide) |

> Suggested review, never applied:
>
> ```suggestion
> let result = "read only"
> ```

## Guide

END-OF-REVIEW
''')
alerts = []
for kind in ["NOTE", "TIP", "IMPORTANT", "WARNING", "CAUTION"]:
    alerts += [f"> [!{kind}]", "> **Formatted** alert with [link](https://example.com).", ">", "> Second paragraph.", "> - Nested list", ">   - Child", ">", "> ```swift", '> let safe = "source"', "> ```", ""]
(root / "alerts.md").write_text("\n".join(alerts))
(root / "compatibility.md").write_text('''---
title: Original compatibility fixture
tags: [reader, example]
---
# Café Türkçe 日本語 😀
# Duplicate
# Duplicate

Setext heading
--------------

*Emphasis* **strong** ~~strike~~ `inline` [reference][ref] <https://example.com>

1. Ordered
   - Nested
     > Normal quote
2. Another item

A footnote[^one].

[^one]: A useful footnote with **formatting**.

<details><summary>More information</summary>
<kbd>⌘</kbd><br>H<sub>2</sub>O and x<sup>2</sup>
</details>

<script>alert("Never execute")</script>
<img src="images/blue.png" alt="Safe local image" width="120" onerror="never()">

![Missing](missing.png)
![Remote](https://example.com/never-load-until-consent.png)

```mermaid
graph LR
  A --> B
```

[ref]: https://example.com
''')
generated = root / "generated"
generated.mkdir(exist_ok=True)
for count in [10000, 50000]:
    with (generated / f"stress-{count}.md").open("w") as file:
        for i in range(count - 1):
            file.write((f"## Heading {i // 100}" if i % 100 == 0 else f"Line {i}: bounded original stress input with Unicode 😀 Türkçe.") + "\n")
        file.write(f"END-OF-STRESS-{count}\n")
(generated / "long-line.md").write_text("# Long line\n\n" + "longword" * 10000 + "\nEND\n")
(generated / "long-code.md").write_text("# Long code\n\n```text\n" + "".join(f"Line {index}: original bounded code sample\n" for index in range(50000)) + "```\n\nEND-OF-LONG-CODE\n")
(generated / "invalid-utf8.md").write_bytes(b"\xff\x00\xcc")
print(f"Generated public fixtures: representative {len(lines)} lines, {len((root / 'long-reading.md').read_bytes())} bytes")
