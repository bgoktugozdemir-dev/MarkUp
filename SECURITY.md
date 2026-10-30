# Security and privacy

MarkUp treats Markdown and every linked resource as untrusted data. Code fences and Mermaid/MDX/script content never execute. The syntax engine only receives code as a JavaScript string argument; it never evaluates document-provided JavaScript. Native HTML handling uses a small allowlist rather than a browser or HTML importer.

There are no accounts, analytics, telemetry, or uploads. Explicit external links open only HTTP(S) in the default browser. Remote images are initially blocked and can disclose your IP address if enabled. Their client uses an ephemeral session without cookies or credentials; unsafe redirects are rejected. Local resources require explicit user-selected roots and resolved symlink containment.

Annotation data lives in an app-specific Application Support directory with private permissions and atomic updates. Recovery preserves corrupt/unknown-version data. Clear All Annotations removes only annotation storage and invalidates old undo/reload epochs. Rendering data is disposable; source Markdown is never written by the reader.

App Sandbox and Hardened Runtime are part of the direct-distribution design. User-selected read/write permission supports explicit PDF/preferences output; it does not authorize automatic source edits. Sparkle requires a valid HTTPS feed and Ed25519 public key; an unconfigured development build contacts no update feed. Release signing and notarization keys belong in protected owner/CI storage, never in this repository.

Reading locally stored Markdown, managing annotations, and exporting PDF do not require Local Network permission. The explicit Print command opens the macOS print panel, which can discover network printers using Bonjour; this may result in a Local Network permission request. Declining that permission preserves these local features but may limit network printing. The sandbox's outbound-network entitlement supports separately enabled HTTPS images and configured updates; it does not itself request Local Network permission. See Apple's [networking overview](https://developer.apple.com/documentation/technologyoverviews/networking-and-communication) and [local network privacy guidance](https://developer.apple.com/documentation/technotes/tn3179-understanding-local-network-privacy).

For a suspected vulnerability, avoid posting an exploit containing private material. Contact the repository owner privately using the repository's security reporting channel once configured. No reporting address is invented in this development repository.
