import QtQuick
import Quickshell
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
  readonly property bool connected: _desired === -1
    ? (_nmKnown ? _nmConnected : status.connected)
    : _desired === 1
  readonly property bool actionBusy: actionProcess.running || settleTimer.running
  readonly property bool busy: actionBusy || statusProcess.running || listProcess.running
    || nmProcess.running
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
    if (connected) return summary
    if (_serversLoaded && configuredServers.length === 0) return "Setup required"
    return "Not connected"
  }

  // Bounded limits: prevent unbounded shell memory from oversized command output.
  readonly property int _maxOutput: 65536
  readonly property int _uuidMax: 4096
  readonly property int _procTimeoutMs: 8000
  readonly property int _actionTimeoutMs: 120000

  // Bounded nonblocking regular-file read for the predictable UUID path.
  // FileView fails on FIFO/symlink-to-device instead of blocking like `cat`.
  readonly property string _uuidPath: {
    var xdg = Quickshell.env("XDG_CONFIG_HOME")
    var home = Quickshell.env("HOME")
    if (xdg && xdg !== "") return xdg + "/eduvpn/uuid"
    return (home || "") + "/.config/eduvpn/uuid"
  }
  readonly property string _lockPath: {
    var run = Quickshell.env("XDG_RUNTIME_DIR")
    var home = Quickshell.env("HOME")
    if (run && run !== "") return run + "/omarchy-eduvpn.lock"
    return (home || "/tmp") + "/.cache/omarchy-eduvpn.lock"
  }

  function eduvpnCommand(args) {
    return EduVpn.cli(args, root._lockPath)
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

    uuidFile.reload()
    if (!nmProcess.running) nmProcess.running = true

    var readBusy = statusProcess.running || listProcess.running
    if (!actionBusy && !readBusy && _statusDue) {
      _statusDue = false
      _statusAge = 0
      statusProcess.running = true
      readBusy = true
    }
    if (!actionBusy && !readBusy && !_serversLoaded) listProcess.running = true
  }

  // Starting another Process from onExited can re-enter the process that is
  // still finishing. Hop through the event loop so the next read is visible as
  // a cleanly idle process to Quickshell.
  function scheduleRefresh() {
    followupTimer.restart()
  }

  function connect() {
    if (!detected || actionBusy) return
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
      root.eduvpnCommand(EduVpn.connectArgs(configuredServers[0].number)),
      "Connecting to " + configuredServers[0].label + "...",
      1
    )
  }

  function disconnect() {
    if (!detected || actionBusy || !connected) return
    startAction("disconnect", root.eduvpnCommand(EduVpn.disconnectArgs()), "Disconnecting...", 0)
  }

  function renew() {
    if (!detected || actionBusy || !connected) return
    startAction("renew", root.eduvpnCommand(EduVpn.renewArgs()), "Renewing eduVPN...", 1)
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
  // optimistic switch until the new state is observed, then give up without
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
  // or hung CLI cannot block the bar indefinitely.
  Timer { id: detectTimeout; interval: root._procTimeoutMs; repeat: false; onTriggered: if (detectProcess.running) detectProcess.running = false }
  Timer { id: nmTimeout; interval: root._procTimeoutMs; repeat: false; onTriggered: if (nmProcess.running) nmProcess.running = false }
  Timer { id: listTimeout; interval: root._procTimeoutMs; repeat: false; onTriggered: if (listProcess.running) listProcess.running = false }
  Timer { id: statusTimeout; interval: root._procTimeoutMs; repeat: false; onTriggered: if (statusProcess.running) statusProcess.running = false }
  Timer { id: actionTimeout; interval: root._actionTimeoutMs; repeat: false; onTriggered: if (actionProcess.running) actionProcess.running = false }

  Process {
    id: detectProcess
    command: ["omarchy-cmd-present", "eduvpn-cli"]
    running: true
    onRunningChanged: if (running) detectTimeout.restart(); else detectTimeout.stop()
    onExited: function(exitCode) {
      detectTimeout.stop()
      root._probed = true
      root._present = exitCode === 0
      if (root._present) root.refresh(true)
    }
  }

  FileView {
    id: uuidFile
    path: root._uuidPath
    watchChanges: false
    printErrors: false
    blockLoading: false
    onLoaded: {
      var raw = String(text().slice(0, root._uuidMax) || "")
      var uuid = EduVpn.parseUuid(raw)
      if (uuid !== "") root.serverUuid = uuid
    }
    onLoadFailed: function(error) {}
  }

  Process {
    id: nmProcess
    command: ["nmcli", "-t", "-f", "NAME,UUID,TYPE,ACTIVE", "connection", "show"]
    running: false
    stdout: StdioCollector { id: nmStdout; waitForEnd: true }
    onRunningChanged: if (running) nmTimeout.restart(); else nmTimeout.stop()
    onExited: function(exitCode) {
      nmTimeout.stop()
      if (exitCode !== 0) return
      var out = root._bounded(nmStdout.text)
      var active = EduVpn.parseNmcliActive(out, root.serverUuid, EduVpn.EDUVPN_NAME)
      root._nmKnown = true
      root._nmConnected = active.connected
      if (root.serverUuid === "" && active.uuid !== "") root.serverUuid = active.uuid
    }
  }

  Process {
    id: listProcess
    command: root.eduvpnCommand(["list"])
    running: false
    stdout: StdioCollector { id: listStdout; waitForEnd: true }
    stderr: StdioCollector { id: listStderr; waitForEnd: true }
    onRunningChanged: if (running) listTimeout.restart(); else listTimeout.stop()
    onExited: function(exitCode) {
      listTimeout.stop()
      var output = root._bounded(listStdout.text)
      var parsed = EduVpn.parseConfiguredServers(output)
      if (exitCode !== 0 && parsed.length === 0) {
        if (root._lastActionError === "") {
          root.lastError = EduVpn.meaningfulError(
            root._bounded(listStderr.text) + "\n" + output
          ) || "Could not read the eduVPN server list."
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
    command: root.eduvpnCommand(["status"])
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
    onRunningChanged: if (running) actionTimeout.restart(); else actionTimeout.stop()
    onExited: function(exitCode) {
      actionTimeout.stop()
      var kind = root._actionKind
      var output = root._bounded(actionStdout.text) + "\n" + root._bounded(actionStderr.text)
      root._actionKind = ""
      root._settleKind = kind
      root._lastActionError = EduVpn.meaningfulError(output)
      if (root._lastActionError !== "") root.lastError = root._lastActionError
      root.actionStatus = kind === "renew" ? "Checking renewed connection..." : "Checking connection..."
      settleTimer.ticks = 0
      settleTimer.restart()
      root.scheduleRefresh()
    }
  }
}
