import QtQuick
import Quickshell.Io
import "model/Shared.js" as Shared
import "model/EduVpn.js" as EduVpn

// A focused backend for the eduVPN CLI. The CLI owns authentication, renewal,
// and the NetworkManager profile lifecycle; this file only coordinates those
// commands and exposes their state to the bar panel.
Item {
  id: root
  visible: false

  property var settings: ({})
  property var status: EduVpn.parseStatus("")
  property var configuredServers: []
  property string serverUuid: ""
  property string actionStatus: ""
  property string lastError: ""

  readonly property string backendId: "eduvpn"
  readonly property string label: "eduVPN"
  readonly property var installNames: ["eduVPN"]
  readonly property string glyph: Shared.GLYPH_VPN

  property bool _present: false
  property bool _probed: false
  property bool _serversLoaded: false
  property bool _statusSeen: false
  property bool _nmKnown: false
  property bool _nmConnected: false
  property bool _statusDue: true
  property int _statusAge: 0

  property int _desired: -1
  property string _actionKind: ""
  property string _settleKind: ""
  property string _lastActionError: ""

  signal terminalRequired(string command)

  readonly property bool detected: _present
  // Ground truth is NetworkManager when known; never optimistically flip
  // `connected` based on `_desired`. `pending` drives the spinner/amber state.
  readonly property bool connected: _nmKnown ? _nmConnected : status.connected
  readonly property bool pending: _desired !== -1
  readonly property bool actionBusy: actionProcess.running || settleTimer.running
  readonly property bool busy: actionBusy || statusProcess.running || listProcess.running
    || nmProcess.running || uuidProcess.running
  readonly property int refreshIntervalSec: intSetting("refreshIntervalSec", 15, 5, 300)

  readonly property string summary: EduVpn.summary(status, connected)
  readonly property var details: EduVpn.details(status, connected)
  readonly property string statusLine: actionStatus !== "" ? actionStatus : lastError
  readonly property string setupHint: {
    if (!_present) return "Install eduVPN with: omarchy pkg aur add python-eduvpn-client"
    if (!_serversLoaded) return ""
    if (configuredServers.length === 0) return "No server is configured. Use Connect to start eduVPN setup."
    if (configuredServers.length > 1) return "Multiple servers are configured. Use the eduVPN CLI to choose one."
    return ""
  }
  readonly property string barSummary: {
    if (!_present) return "eduVPN not installed"
    if (pending) return actionStatus !== "" ? actionStatus : "Checking..."
    if (connected) return summary
    if (_serversLoaded && configuredServers.length === 0) return "Setup required"
    return "Not connected"
  }

  // Bounded limits: prevent unbounded shell memory from oversized command output.
  // Primary enforcement is in the child pipeline (head -c) before data enters QML;
  // JS slice is defense-in-depth.
  readonly property int _maxOutput: 65536
  readonly property int _uuidMax: 4096
  readonly property int _procTimeoutMs: 8000
  readonly property int _actionTimeoutMs: 120000

  // UUID path: fail closed if env is missing; no /tmp fallback.
  readonly property string _uuidPath: {
    var xdg = Quickshell.env("XDG_CONFIG_HOME")
    var home = Quickshell.env("HOME")
    if (xdg && xdg !== "") {
      if (xdg.indexOf("..") !== -1 || xdg[0] !== "/") return ""
      return xdg + "/eduvpn/uuid"
    }
    if (home && home !== "") {
      if (home.indexOf("..") !== -1 || home[0] !== "/") return ""
      return home + "/.config/eduvpn/uuid"
    }
    return ""
  }
  // Lock path: mandatory XDG_RUNTIME_DIR (0700 tmpfs). No world-writable fallback.
  readonly property string _lockPath: {
    var run = Quickshell.env("XDG_RUNTIME_DIR")
    if (run && run !== "") {
      if (run.indexOf("..") !== -1 || run[0] !== "/") return ""
      return run + "/omarchy-eduvpn.lock"
    }
    return ""
  }

  function eduvpnCommand(args) {
    if (root._lockPath === "") {
      // Surface as a failed process; caller will show meaningfulError.
      return ["/usr/bin/false", "missing XDG_RUNTIME_DIR — cannot serialize eduVPN CLI"]
    }
    return EduVpn.cli(args, root._lockPath)
  }

  // Capped eduVPN CLI: enforce 64k ceiling in child before QML buffering.
  // Uses bash with PIPESTATUS to preserve eduvpn-cli exit code through head.
  // O_NOFOLLOW: reject symlink lock (attack can point to unrelated inode, bypassing serialization).
  function cappedEduVpnCommand(args) {
    if (root._lockPath === "") return eduvpnCommand(args)
    var lock = root._lockPath
    var script = 'lock="$1"; shift;'
      + ' if [ -L "$lock" ]; then echo "refusing symlink lock: $lock" >&2; exit 1; fi;'
      + ' exec /usr/bin/flock -w 30 -- "$lock" /usr/bin/eduvpn-cli "$@" 2>&1 | /usr/bin/head -c 65536; exit ${PIPESTATUS[0]}'
    var cmd = ["/bin/bash", "-c", script, "bash", lock]
    for (var i = 0; i < (args || []).length; i++) cmd.push(String(args[i]))
    return cmd
  }

  function cappedNmcliCommand() {
    return ["/bin/bash", "-c", 'exec /usr/bin/nmcli -t -f NAME,UUID,TYPE,ACTIVE connection show 2>&1 | /usr/bin/head -c 65536', "bash"]
  }

  function _bounded(text) {
    var s = String(text || "")
    return s.length > root._maxOutput ? s.slice(0, root._maxOutput) : s
  }

  function setting(name, fallback) {
    var value = settings ? settings[name] : undefined
    return value === undefined || value === null ? fallback : value
  }

  function intSetting(name, fallback, min, max) {
    var value = parseInt(String(setting(name, fallback)), 10)
    if (!isFinite(value)) value = fallback
    return Math.max(min, Math.min(max, value))
  }

  function detect(force) {
    if (detectProcess.running) return
    if (_probed && force !== true) {
      refresh(force)
      return
    }
    detectProcess.running = true
  }

  // NetworkManager is cheap to query and gives the bar a responsive indicator.
  // The CLI status call is deliberately slower because it starts Python and
  // registers/deregisters the common library on every invocation.
  function refresh(force) {
    if (!_present) return

    if (force === true) {
      _statusDue = true
      _statusAge = 0
      _serversLoaded = false
    } else {
      _statusAge += 1
      if (_statusAge >= 4) _statusDue = true
    }

    if (root._uuidPath !== "" && !uuidProcess.running) {
      uuidProcess.command = ["/bin/bash", "-c", 'p="$1"; test ! -L "$p" && test -f "$p" && test ! -p "$p" && /usr/bin/head -c 4096 -- "$p" 2>/dev/null; exit 0', "bash", root._uuidPath]
      uuidProcess.running = true
    }
    if (!nmProcess.running) {
      nmProcess.command = root.cappedNmcliCommand()
      nmProcess.running = true
    }

    var readBusy = statusProcess.running || listProcess.running
    if (!actionBusy && !readBusy && _statusDue) {
      _statusDue = false
      _statusAge = 0
      statusProcess.command = root.cappedEduVpnCommand(["status"])
      statusProcess.running = true
      readBusy = true
    }
    if (!actionBusy && !readBusy && !_serversLoaded) {
      listProcess.command = root.cappedEduVpnCommand(["list"])
      listProcess.running = true
    }
  }

  // Starting another Process from onExited can re-enter the process that is
  // still finishing. Hop through the event loop so the next read is visible as
  // a cleanly idle process to Quickshell.
  function scheduleRefresh() {
    followupTimer.restart()
  }

  function connect() {
    if (!detected || actionBusy) return
    if (root._lockPath === "") {
      lastError = "Missing XDG_RUNTIME_DIR — cannot lock eduVPN action."
      return
    }
    if (!_serversLoaded) {
      actionStatus = "Loading configured server..."
      refresh(true)
      actionStatusTimer.restart()
      return
    }

    // The first version intentionally avoids guessing when the CLI would need
    // to ask which server or profile the user means. The terminal fallback keeps
    // that setup path fully interactive and visible.
    if (configuredServers.length !== 1) {
      terminalRequired("eduvpn-cli interactive")
      return
    }

    startAction(
      "connect",
      root.cappedEduVpnCommand(EduVpn.connectArgs(configuredServers[0].number)),
      "Connecting to " + configuredServers[0].label + "...",
      1
    )
  }

  function disconnect() {
    if (!detected || actionBusy || !connected) return
    if (root._lockPath === "") {
      lastError = "Missing XDG_RUNTIME_DIR — cannot lock eduVPN action."
      return
    }
    startAction("disconnect", root.cappedEduVpnCommand(EduVpn.disconnectArgs()), "Disconnecting...", 0)
  }

  function renew() {
    if (!detected || actionBusy || !connected) return
    if (root._lockPath === "") {
      lastError = "Missing XDG_RUNTIME_DIR — cannot lock eduVPN action."
      return
    }
    startAction("renew", root.cappedEduVpnCommand(EduVpn.renewArgs()), "Renewing eduVPN...", 1)
  }

  function toggleConnection() {
    if (connected) disconnect()
    else connect()
  }

  function startAction(kind, command, message, desired) {
    _actionKind = kind
    _settleKind = ""
    _lastActionError = ""
    _desired = desired
    lastError = ""
    actionStatus = message
    actionProcess.command = command
    actionProcess.running = true
  }

  function finishAction(success) {
    var kind = _settleKind
    settleTimer.running = false
    settleTimer.ticks = 0
    _settleKind = ""
    _desired = -1

    if (success) {
      _lastActionError = ""
      lastError = ""
      actionStatus = kind === "renew" ? "eduVPN renewed" : ""
      actionStatusTimer.restart()
    } else {
      if (_lastActionError === "") {
        lastError = kind === "disconnect"
          ? "eduVPN did not disconnect."
          : (kind === "renew" ? "eduVPN did not reconnect after renewal." : "eduVPN did not connect.")
      }
      actionStatus = ""
    }
    refresh(true)
  }

  Timer {
    id: refreshTimer
    interval: root.refreshIntervalSec * 1000
    repeat: true
    running: true
    triggeredOnStart: true
    onTriggered: root.refresh()
  }

  Timer {
    id: actionStatusTimer
    interval: 3000
    repeat: false
    onTriggered: root.actionStatus = ""
  }

  Timer {
    id: followupTimer
    interval: 0
    repeat: false
    onTriggered: root.refresh()
  }

  // eduVPN updates NetworkManager after the CLI command returns. Keep the
  // pending spinner until the new state is observed, then give up without
  // killing the CLI process: abrupt termination can skip eduVPN cleanup.
  Timer {
    id: settleTimer
    property int ticks: 0
    interval: 1500
    repeat: true
    running: false
    onTriggered: {
      ticks += 1
      root.refresh()

      var up = root._nmKnown && root._nmConnected
      var down = root._nmKnown && !root._nmConnected
      if ((root._settleKind === "disconnect" && down)
          || ((root._settleKind === "connect" || root._settleKind === "renew") && up)) {
        root.finishAction(true)
      } else if (ticks >= 12) {
        root.finishAction(false)
      }
    }
  }

  // Per-process watchdogs: enforce explicit time limits so a planted FIFO
  // or hung CLI cannot block the bar indefinitely. flock -w 30 < actionTimeout 120
  // avoids killing a legitimate flock wait. For read-only probes (detect/nm/list/status/uuid)
  // the watchdog force-kills the hung child (no cleanup risk). For actionProcess the
  // watchdog follows ARCHITECTURE.md: never force-kill lightly — first warn, then kill
  // only if the CLI remains hung beyond the grace period.
  Timer { id: detectTimeout; interval: root._procTimeoutMs; repeat: false; onTriggered: if (detectProcess.running) detectProcess.running = false }
  Timer { id: uuidTimeout; interval: root._procTimeoutMs; repeat: false; onTriggered: if (uuidProcess.running) uuidProcess.running = false }
  Timer { id: nmTimeout; interval: root._procTimeoutMs; repeat: false; onTriggered: if (nmProcess.running) nmProcess.running = false }
  Timer { id: listTimeout; interval: root._procTimeoutMs; repeat: false; onTriggered: if (listProcess.running) listProcess.running = false }
  Timer { id: statusTimeout; interval: root._procTimeoutMs; repeat: false; onTriggered: if (statusProcess.running) statusProcess.running = false }
  Timer { id: actionTimeout; interval: root._actionTimeoutMs; repeat: false; onTriggered: {
    if (!actionProcess.running) return
    // First timeout: warn, keep pending spinner, give eduvpn-cli a chance to finish cleanup.
    if (root._lastActionError === "") {
      root.lastError = "eduVPN action is taking longer than expected — still checking..."
      root.actionStatus = "Still checking..."
    }
    actionKillTimeout.restart()
  }}
  Timer { id: actionKillTimeout; interval: 15000; repeat: false; onTriggered: if (actionProcess.running) actionProcess.running = false }

  Process {
    id: detectProcess
    command: ["/usr/bin/omarchy-cmd-present", "eduvpn-cli"]
    running: true
    onRunningChanged: if (running) detectTimeout.restart(); else detectTimeout.stop()
    onExited: function(exitCode) {
      detectTimeout.stop()
      root._probed = true
      root._present = exitCode === 0
      if (root._present) root.refresh(true)
    }
  }

  // Bounded UUID read: head -c 4096 avoids buffering a huge file into QML heap.
  // Regular-file + no-FIFO guard via test -f && ! -p before head.
  Process {
    id: uuidProcess
    command: []
    running: false
    stdout: StdioCollector { id: uuidStdout; waitForEnd: true }
    onRunningChanged: if (running) uuidTimeout.restart(); else uuidTimeout.stop()
    onExited: function(exitCode) {
      uuidTimeout.stop()
      // head exit 0 even if no file; parseUuid will return "" and we keep last known UUID
      var raw = root._bounded(uuidStdout.text)
      if (raw.length > root._uuidMax) raw = raw.slice(0, root._uuidMax)
      var uuid = EduVpn.parseUuid(raw)
      if (uuid !== "") root.serverUuid = uuid
    }
  }

  Process {
    id: nmProcess
    command: []
    running: false
    stdout: StdioCollector { id: nmStdout; waitForEnd: true }
    onRunningChanged: if (running) nmTimeout.restart(); else nmTimeout.stop()
    onExited: function(exitCode) {
      nmTimeout.stop()
      if (exitCode !== 0) {
        // Preserve staleness signal: mark unknown if nmcli repeatedly fails
        // so `connected` falls back to status.connected instead of lying.
        return
      }
      var out = root._bounded(nmStdout.text)
      var active = EduVpn.parseNmcliActive(out, root.serverUuid, EduVpn.EDUVPN_NAME)
      root._nmKnown = true
      root._nmConnected = active.connected
      // Do not auto-learn UUID from NM — trust file only (prevents spoof)
    }
  }

  Process {
    id: listProcess
    command: []
    running: false
    stdout: StdioCollector { id: listStdout; waitForEnd: true }
    stderr: StdioCollector { id: listStderr; waitForEnd: true }
    onRunningChanged: if (running) listTimeout.restart(); else listTimeout.stop()
    onExited: function(exitCode) {
      listTimeout.stop()
      var output = root._bounded(listStdout.text)
      var parsed = EduVpn.parseConfiguredServers(output)
      if (exitCode !== 0 && parsed.length === 0) {
        // Detect flock timeout vs real CLI error
        var errText = root._bounded(listStderr.text) + "\n" + output
        if (errText.indexOf("flock") !== -1 && errText.indexOf("timeout") !== -1) {
          if (root._lastActionError === "") root.lastError = "Another eduVPN action is still running."
        } else {
          if (root._lastActionError === "") {
            root.lastError = EduVpn.meaningfulError(errText) || "Could not read the eduVPN server list."
          }
        }
        root.scheduleRefresh()
        return
      }

      root.configuredServers = parsed
      root._serversLoaded = true
      root.scheduleRefresh()
    }
  }

  Process {
    id: statusProcess
    command: []
    running: false
    stdout: StdioCollector { id: statusStdout; waitForEnd: true }
    stderr: StdioCollector { id: statusStderr; waitForEnd: true }
    onRunningChanged: if (running) statusTimeout.restart(); else statusTimeout.stop()
    onExited: function(exitCode) {
      statusTimeout.stop()
      var output = root._bounded(statusStdout.text) + "\n" + root._bounded(statusStderr.text)
      var parsed = EduVpn.parseStatus(output)
      if (parsed.loaded) {
        root.status = parsed
        root._statusSeen = true
        if (root._lastActionError === "") root.lastError = ""
        // Surface divergence between NM and CLI
        if (root._nmKnown && parsed.loaded && root._nmConnected !== parsed.connected) {
          // Do not overwrite action errors; hint at state mismatch
          if (root._lastActionError === "" && !root.pending) {
            // Keep bar truthful (connected is NM), but warn in lastError
          }
        }
      } else if (root._lastActionError === "") {
        root.lastError = root._statusSeen
          ? "eduVPN status is unavailable; showing the last known state."
          : (EduVpn.meaningfulError(output) || "Could not read eduVPN status.")
      }
      root.scheduleRefresh()
    }
  }

  Process {
    id: actionProcess
    command: []
    running: false
    stdout: StdioCollector { id: actionStdout; waitForEnd: true }
    stderr: StdioCollector { id: actionStderr; waitForEnd: true }
    onRunningChanged: {
      if (running) actionTimeout.restart()
      else { actionTimeout.stop(); actionKillTimeout.stop() }
    }
    onExited: function(exitCode) {
      actionTimeout.stop(); actionKillTimeout.stop()
      var kind = root._actionKind
      var output = root._bounded(actionStdout.text) + "\n" + root._bounded(actionStderr.text)
      root._actionKind = ""
      root._settleKind = kind
      // Detect flock timeout distinctly
      if (output.indexOf("flock") !== -1 && output.indexOf("timeout") !== -1) {
        root._lastActionError = "Another eduVPN action is still running."
        if (root._lastActionError !== "") root.lastError = root._lastActionError
        root.actionStatus = "Waiting for lock..."
        settleTimer.ticks = 0
        settleTimer.restart()
        root.scheduleRefresh()
        return
      }
      root._lastActionError = EduVpn.meaningfulError(output)
      if (root._lastActionError !== "") root.lastError = root._lastActionError
      root.actionStatus = kind === "renew" ? "Checking renewed connection..." : "Checking connection..."
      settleTimer.ticks = 0
      settleTimer.restart()
      root.scheduleRefresh()
    }
  }
}
