/* MarkUp adapter for the pinned highlight.js emitter interface. No document code is evaluated. */
(function () {
  "use strict";
  class RangeEmitter {
    constructor() {
      this.offset = 0;
      this.tokens = [];
      this.scopes = [];
      this.deadline = Date.now() + 150;
    }
    check() {
      if (Date.now() > this.deadline || markupIsCancelled()) throw new Error("MarkUp work limit");
    }
    addText(text) {
      this.check();
      const kind = this.scopes.length ? this.scopes[this.scopes.length - 1] : null;
      if (kind && text.length) this.append(this.offset, text.length, kind);
      this.offset += text.length;
    }
    append(location, length, kind) {
      const last = this.tokens[this.tokens.length - 1];
      if (last && last.kind === kind && last.location + last.length === location) last.length += length;
      else this.tokens.push({ location, length, kind });
      if (this.tokens.length > 30000) throw new Error("MarkUp token limit");
    }
    startScope(scope) { this.check(); this.scopes.push(scope); }
    endScope() { this.scopes.pop(); }
    openNode(scope) { this.startScope(scope); }
    closeNode() { this.endScope(); }
    __addSublanguage(emitter) {
      this.check();
      // Embedded HTML/CSS/JS spans are already offsets into their own original input.
      for (const token of emitter.tokens) this.append(this.offset + token.location, token.length, token.kind);
      this.offset += emitter.offset;
    }
    finalize() { this.scopes.length = 0; return true; }
    toHTML() { return ""; }
  }
  hljs.configure({ __emitter: RangeEmitter });
  // Safe mode would turn an interrupted emitter into an apparently successful plain-text result.
  // Propagate failures so Swift can distinguish cancellation and keep the original source visible.
  hljs.debugMode();
  globalThis.markupTokens = function (code, language) {
    const result = hljs.highlight(code, { language, ignoreIllegals: true });
    if (result._emitter.offset !== code.length) throw new Error("MarkUp source mismatch");
    return JSON.stringify(result._emitter.tokens);
  };
}());
