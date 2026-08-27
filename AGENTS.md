# Agent Notes

This is an Omarchy Quickshell bar widget specialized for the official
`eduvpn-cli` client.

## Commands

```bash
node tests/run.js
omarchy plugin validate .
```

Run `qmllint` from the parent directory with the Omarchy shell import path:

```bash
cd .. && qmllint -I /usr/share/omarchy/shell omarchy-eduvpn/Panel.qml
cd .. && qmllint -I /usr/share/omarchy/shell omarchy-eduvpn/EduVpnBackend.qml
```

## Rules

- Keep parsing and command decisions in `model/EduVpn.js` so they remain tested.
- Do not use `eduvpn-cli` output or exit codes as the sole action result; verify
  the requested state through NetworkManager afterward.
- Keep all eduVPN CLI invocations serialized because the shell can instantiate
  the widget once per monitor.
- Do not force-kill an active eduVPN action; it may leave its NetworkManager
  cleanup incomplete.
- Restart the shell after changing a model file.
- Use ASCII source and `String.fromCodePoint` for Nerd Font characters.
