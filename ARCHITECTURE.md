# Architecture

This plugin is intentionally narrower than a general VPN switcher. The
official `eduvpn-cli` remains the source of truth for authentication, server
selection, renewal, and NetworkManager profile cleanup. The widget provides a
small asynchronous UI around those operations.

## Files

| File | Role |
|------|------|
| `manifest.json` | Plugin identity, bar entry point, and refresh setting |
| `Panel.qml` | Bar icon, popup layout, buttons, and IPC surface |
| `EduVpnBackend.qml` | CLI process plumbing, polling, actions, and pending (non-optimistic) state |
| `model/EduVpn.js` | Pure parsers, command builders, and display rows |
| `model/Shared.js` | Small visual and text helpers |
| `tests/model/eduvpn.test.js` | Parser and command-builder regression tests |

The model file contains no QML objects or side effects. It is loaded by the
Node test harness and by QML, so every assumption about CLI output belongs
there rather than inside process callbacks.

## State

NetworkManager is used for the fast connected/disconnected indicator. The
profile UUID is read from `~/.config/eduvpn/uuid`; this avoids confusing another
active WireGuard tunnel with eduVPN. `eduvpn-cli status` is polled less often
for the server, profile, protocol, and validity text.

The CLI status output is human-readable and includes debug records. The parser
matches only its labeled lines. A failed status read keeps the last known
details instead of claiming that the tunnel disappeared.

## Actions

The first version supports one configured server. When exactly one configured
server is found, Connect runs:

```text
eduvpn-cli -y connect -n <number>
```

Disconnect and Renew run the corresponding official CLI commands. If there are
zero or multiple configured servers, Connect opens a floating terminal for the
interactive CLI rather than guessing.

All CLI calls are wrapped in a user-runtime `flock -w 30` (absolute `/usr/bin/flock`
under `$XDG_RUNTIME_DIR`, symlink-checked) and capped to 64kB via `head -c`
before QML buffering (`4096B` for the UUID file, with `test ! -L`/`! -p`
guards). The bar is a singleton (`allowMultiple:false`), and eduVPN shares
state and OAuth token files between invocations.

Action processes are not optimistically marked `connected`; a `pending` spinner
is shown until NetworkManager confirms the state. Probes (`nmcli`/`status`/
`list`/`uuid`) are force-killed after 8s if hung, but `action` follows a
warn-then-kill (120s warn, 15s grace before SIGTERM) because eduVPN cleanup
can be incomplete after an abrupt termination.

eduVPN catches many command failures while still exiting successfully. An
action is therefore considered successful only after a follow-up NetworkManager
poll observes the requested state. The panel displays useful output when the
state never arrives.

## Development

```bash
node tests/run.js
omarchy plugin validate .
```

QML files hot-reload, but `model/*.js` files remain cached until:

```bash
omarchy restart shell
```

Run `qmllint` from the parent directory, not from inside the plugin directory:

```bash
cd .. && qmllint -I /usr/share/omarchy/shell omarchy-eduvpn/Panel.qml
cd .. && qmllint -I /usr/share/omarchy/shell omarchy-eduvpn/EduVpnBackend.qml
```
