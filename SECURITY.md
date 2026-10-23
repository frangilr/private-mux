# Security model (prototype)

PrivateMux (pmux) is intended for users who want native clickable terminal tabs
without a browser, updater, account service, or application telemetry. It is
not a formally verified terminal and provides no absolute privacy guarantee.

## Trusted computing base

1. **macOS, AppKit, SwiftUI, WKWebView/WebKit, libc, PTY and SSH.**
2. **Pinned third-party xterm.js and fit addon.** These can see terminal text
   and user keystrokes. **Compromised browser JS can also send arbitrary input
   to the local shell through the message bridge.** A restrictive CSP or the
   absence of direct JavaScript network APIs does not prevent such a payload
   from executing commands (including network commands) via that bridge.
3. **Our Swift/C bridge and PTY management.** Remote processes control terminal
   output; hostile escape sequences and malicious terminal hyperlinks should
   be treated as untrusted data.
4. **Your local shell, startup scripts, SSH setup and remote server tools.**
   The app cannot control what those programs persist or transmit.

## Active restrictions in the source

- `WKWebsiteDataStore.nonPersistent()` avoids *website* persistent storage.
- Only the bundled HTML/CSS/JavaScript assets are loaded.
- CSP: no `connect-src`, remote scripts, forms or frames; denied popups.
- WKWebView navigation only allows the exact bundled terminal page.
- Native JS messaging accepts five fixed message types: `ready`, `input`,
  `binary`, `resize`, and `output-drained`; it does not expose a generic shell execution API,
  arbitrary filesystem functions, credentials, or a networking API. **Input
  messages necessarily can instruct the shell to execute commands.**
- Output goes to a fixed JS function via base64, never string-evaluated.
- Native app includes no intentional terminal history, logs, update service,
  analytics SDK, background socket, cloud APIs, or remote control service.
  App-managed SSH is a child process using the system client; it does not
  expose private-key bytes to application code.

## Residual risks

- Browser/terminal JS supply chain, parser vulnerabilities, and bugs in our
  PTY or message bridge could compromise confidentiality/integrity.
- The app is intentionally **not App Sandboxed** so that arbitrary shell, ssh,
  and other developer tools can run normally. Child-process network access is
  not blocked. No meaningful exfiltration guarantee follows from the source.
- WebKit, macOS, zsh, ssh, tmux, and the environment may persist diagnostics,
  history, clipboard, swap or other metadata; app-level settings cannot
  universally prevent this.
- PTY output reads pause after each 16 KiB chunk until xterm acknowledges it.
  This bounds queued output per tab, but not total WebKit memory or input
  buffering; broader stress testing is still required.
- The app built and passed basic local UI tests on a Mac on October 22, 2026.
  With VPN connected, all three SSH hosts and their tmux 3.2a servers were
  exercised for window discovery, pane input/output, resize, reconnect,
  individual disable/enable, live window changes, and session survival after
  app exit.
  This does not establish security for sensitive use. Review all source and
  locally fetched npm assets before connecting to sensitive servers.

## October 23, 2026 audit notes

- The bundled xterm.js 6.0.0 and fit addon 0.11.0 matched the local npm
  tarballs and the SHA-512 integrity values in `frontend/package-lock.json`.
  Source inspection found no intentional terminal-content telemetry or direct
  network calls in the bundled scripts or app bridge.
- An isolated app copy with no configured hosts showed no app/WebKit network
  sockets in idle snapshots. Harmless markup and OSC 8 hyperlink output rendered
  as terminal text; clipboard-control sequences were not tested. Direct macOS
  SSH to a test host worked, but UI automation could not submit the same command
  through PrivateMux, so that live comparison remains unverified.
- The installed app was ad hoc signed and passed strict signature verification.
  Altering a JavaScript resource in a throwaway signed copy made verification
  fail. This detects bundle changes but does not establish developer identity;
  rebuilding or replacing the app requires signing and verification again.
- No app-written terminal transcript was found in the source. SSH host settings
  persist in UserDefaults; normal shell history, WebKit/Metal caches, and macOS
  diagnostics can also leave disk traces. These checks do not prove zero data
  leakage or equivalence to Terminal.app.

## Verification suggestions

- `grep -RInE 'https?://|URLSession|fetch\(|WebSocket|analytics|telemetry' PrivateTerm`
  (review hits manually; grep alone is not a security audit).
- Pin integrity hashes in `frontend/package-lock.json` after fetching assets.
- Build with Xcode locally from the audited revision.
- Verify there are no unexpected connections at idle; treat expected ssh
  traffic separately when checking firewall/process network activity.
- Consider a dedicated macOS user for high-sensitivity work; don't give this
  prototype elevated privileges or access to critical credentials by default.
