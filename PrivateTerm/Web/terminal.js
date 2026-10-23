(() => {
  'use strict';
  const send = message => window.webkit.messageHandlers.terminal.postMessage(message);
  const term = new Terminal({
    cursorBlink: true,
    cursorStyle: 'block',
    scrollback: 3000,       // In-memory scrollback, never app-written to disk.
    fontSize: 13,
    lineHeight: 1.12,
    fontFamily: 'Menlo, Monaco, monospace',
    allowProposedApi: false,
    theme: {
      background: '#1e1e1e', foreground: '#e1dcdc', cursor: '#e1dcdc',
      selectionBackground: '#3b3b3b', black: '#1e1e1e',
      red: '#f38ba8', green: '#a6e3a1', yellow: '#f9e2af',
      blue: '#89b4fa', magenta: '#cba6f7', cyan: '#94e2d5',
      white: '#cdd6f4'
    }
  });
  const fit = new FitAddon.FitAddon();
  term.loadAddon(fit);
  term.open(document.getElementById('terminal'));

  // No websocket, fetch, CDN, third-party link addon or image addon.
  term.onData(data => send({type: 'input', data}));
  term.onBinary(data => send({type: 'binary', data: btoa(data)}));
  term.onResize(({cols, rows}) => send({type: 'resize', cols, rows}));

  // Let macOS handle ordinary Command-key shortcuts (including copy/paste).
  term.attachCustomKeyEventHandler(event => {
    if (event.metaKey) return false;
    return true;
  });

  function fitTerminal() {
    if (document.getElementById('terminal').clientWidth < 20) return;
    try { fit.fit(); } catch (_) { /* A tab can be hidden during layout. */ }
  }

  const observer = new ResizeObserver(() => fitTerminal());
  observer.observe(document.getElementById('terminal'));

  window.privateTerm = Object.freeze({
    // Native Swift sends only base64-encoded PTY bytes: never evals output.
    receiveBase64(base64, id) {
      const binary = atob(base64);
      const bytes = Uint8Array.from(binary, char => char.charCodeAt(0));
      term.write(bytes, () => {
        if (id !== null) send({type: 'output-drained', id});
      });
    },
    fitAndFocus() {
      fitTerminal();
      term.focus();
      return {cols: term.cols, rows: term.rows};
    },
    clear() {
      term.reset();
    }
  });

  requestAnimationFrame(() => {
    fitTerminal();
    send({type: 'ready', cols: term.cols, rows: term.rows});
    term.focus();
  });
})();
