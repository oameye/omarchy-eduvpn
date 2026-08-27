# Contributing

This repository is a focused eduVPN Omarchy bar widget. Read
[ARCHITECTURE.md](ARCHITECTURE.md) before changing the process or state model.

## Tests

```bash
node tests/run.js
```

The test suite has no dependencies. It loads the pure model files in a Node
realm and runs every `tests/model/*.test.js` file.

When fixing a parser, add the real CLI output that exposed the problem. The
eduVPN CLI emits debug records as well as its human-readable status, and both
streams matter when testing an action failure.

## Validation

After changing the manifest:

```bash
omarchy plugin validate .
```

Lint QML from the directory containing the plugin:

```bash
cd .. && qmllint -I /usr/share/omarchy/shell omarchy-eduvpn/Panel.qml
cd .. && qmllint -I /usr/share/omarchy/shell omarchy-eduvpn/EduVpnBackend.qml
```

After changing a model file, restart the shell:

```bash
omarchy restart shell
```

## Style

Keep `model/*.js` pure and compatible with QML's JavaScript engine. Use `var`
and `function` declarations there, and do not access QML objects from a model.
Use `String.fromCodePoint` for Nerd Font glyphs instead of pasted glyphs.
Comments should explain why a non-obvious CLI workaround exists.

## License

The project is MIT licensed. See [LICENSE](LICENSE).
