.pragma library
.import "Shared.js" as Shared

// eduVPN's CLI is intentionally human-readable rather than JSON. The parser
// therefore keys off the labels, while ignoring the debug records the CLI also
// writes to stdout during normal startup and shutdown.

var EDUVPN_NAME = "eduVPN"
var CLI_LOCK = "${XDG_RUNTIME_DIR:-$HOME/.cache}/omarchy-eduvpn.lock"

function emptyStatus() {
  return {
    loaded: false,
    connected: false,
    server: "",
    category: "",
    validity: "",
    profile: "",
    location: "",
    protocol: "",
    statusText: "Unknown"
  }
}

function parseStatus(raw) {
  var result = emptyStatus()
  var lines = String(raw || "").split("\n")

  for (var i = 0; i < lines.length; i++) {
    var line = lines[i].trim()
    if (line === "") continue

    var connected = line.match(/^Connected to:\s*"([^"]*)"\s*(?:\(([^)]*)\))?/i)
    if (connected) {
      result.loaded = true
      result.connected = true
      result.server = connected[1].trim()
      result.category = connected[2] ? connected[2].trim() : ""
      continue
    }

    if (/^You are currently not connected to a server/i.test(line)) {
      result.loaded = true
      result.connected = false
      continue
    }

    var separator = line.indexOf(":")
    if (separator < 0) continue

    var key = line.substring(0, separator).trim().toLowerCase()
    var value = line.substring(separator + 1).trim()
    if (value === "") continue

    if (key === "valid for") result.validity = value
    else if (key === "current profile") result.profile = value
    else if (key === "current location") result.location = value
    else if (key === "vpn protocol") result.protocol = value
  }

  if (result.connected) result.statusText = "Connected"
  else if (result.loaded) result.statusText = "Not connected"
  return result
}

// `eduvpn-cli list` numbers configured servers in the exact form used by
// `connect -n`. Headings and debug output do not match this expression.
function parseConfiguredServers(raw) {
  var servers = []
  var lines = String(raw || "").split("\n")

  for (var i = 0; i < lines.length; i++) {
    var match = lines[i].trim().match(/^\[(\d+)\]:\s*(.+?)\s*$/)
    if (!match) continue

    servers.push({ number: parseInt(match[1], 10), label: match[2] })
  }
  return servers
}

// `nmcli -t` escapes colons and backslashes. Split one field at a time so an
// interface or connection name containing a colon cannot shift the columns.
function splitNmcliField(text) {
  var value = String(text || "")
  for (var i = 0; i < value.length; i++) {
    if (value[i] === "\\") {
      i++
      continue
    }
    if (value[i] === ":") return [unescapeNmcli(value.substring(0, i)), unescapeNmcli(value.substring(i + 1))]
  }
  return [unescapeNmcli(value), ""]
}

function unescapeNmcli(value) {
  return String(value || "").replace(/\\(.)/g, "$1")
}

// The CLI owns the profile lifecycle, but NetworkManager is the fast and
// reliable source for the bar indicator. The UUID file prevents another
// WireGuard profile from being mistaken for eduVPN.
function parseNmcliActive(raw, expectedUuid, expectedName) {
  var result = { connected: false, uuid: "" }
  var wantedUuid = String(expectedUuid || "").trim()
  var wantedName = String(expectedName || EDUVPN_NAME)
  var lines = String(raw || "").split("\n")

  for (var i = 0; i < lines.length; i++) {
    var line = lines[i]
    if (line.trim() === "") continue

    var fields = []
    var rest = line
    for (var f = 0; f < 3; f++) {
      var pair = splitNmcliField(rest)
      fields.push(pair[0])
      rest = pair[1]
    }
    fields.push(unescapeNmcli(rest))
    if (fields.length < 4 || fields[3] !== "yes") continue
    if (wantedUuid !== "" && fields[1] !== wantedUuid) continue
    if (wantedUuid === "" && fields[0] !== wantedName) continue

    result.connected = true
    result.uuid = fields[1]
    return result
  }
  return result
}

function parseUuid(raw) {
  var lines = String(raw || "").split("\n")
  for (var i = 0; i < lines.length; i++) {
    var value = lines[i].trim()
    if (/^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i.test(value)) return value
  }
  return ""
}

function summary(status, connected) {
  if (!connected) {
    return status && status.validity.toLowerCase() === "expired"
      ? "Not connected - validity expired"
      : "Not connected"
  }

  var parts = []
  if (status && status.server !== "") parts.push(status.server)
  if (status && status.profile !== "") parts.push(status.profile)
  return parts.length > 0 ? parts.join(" - ") : "Connected"
}

function details(status, connected) {
  if (!connected || !status) return []

  var rows = [
    Shared.detail("Server", status.server),
    Shared.detail("Profile", status.profile),
    Shared.detail("Protocol", status.protocol),
    Shared.detail("Validity", status.validity),
    Shared.detail("Location", status.location)
  ]
  return rows.filter(function(row) { return row.value !== "" })
}

// eduVPN catches most command failures and still exits successfully. Keep only
// user-facing lines, leaving debug records and progress messages out of the bar.
function meaningfulError(raw) {
  var candidates = []
  var lines = String(raw || "").split("\n")

  for (var i = 0; i < lines.length; i++) {
    var line = lines[i].trim()
    if (line === "" || /^time=.*level=/i.test(line)) continue
    if (/^Authorization needed\./i.test(line)) continue
    if (/^Disconnecting and renewing\.\.\.$/i.test(line)) continue

    if (/^(error|an error|please |you are |no |could not|unable|failed|failure)/i.test(line)
        || /(error|failed|failure|refused|expired)/i.test(line)) {
      candidates.push(line)
    }
  }
  return candidates.length > 0 ? Shared.elide(candidates[candidates.length - 1], 160) : ""
}

// There can be one widget instance per monitor. Serializing all CLI calls also
// protects the shared eduVPN state and OAuth token files from overlapping
// registration/deregistration cycles.
function cli(args) {
  return [
    "sh", "-c",
    'exec flock -w 120 "' + CLI_LOCK + '" eduvpn-cli "$@"',
    "eduvpn-cli"
  ].concat(args || [])
}

function connectArgs(serverNumber) {
  return ["-y", "connect", "-n", String(serverNumber)]
}

function disconnectArgs() {
  return ["-y", "disconnect"]
}

function renewArgs() {
  return ["-y", "renew"]
}
