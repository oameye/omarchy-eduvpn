.pragma library
.import "Shared.js" as Shared

// eduVPN's CLI is intentionally human-readable rather than JSON. The parser
// therefore keys off the labels, while ignoring the debug records the CLI also
// writes to stdout during normal startup and shutdown.

var EDUVPN_NAME = "eduVPN"
var CLI_LOCK_FALLBACK = "/tmp/omarchy-eduvpn.lock"
var MAX_FIELD_LEN = 120
var MAX_SERVERS = 32
var MAX_LINES = 2000
var MAX_RAW_LEN = 65536

function sanitizeField(value) {
  var v = String(value || "")
  // Strip control chars and bidi overrides that can spoof UI layout.
  v = v.replace(/[\x00-\x1F\x7F]/g, "").replace(/[\u202A-\u202E\u2066-\u2069]/g, "")
  v = v.trim()
  if (v.length > MAX_FIELD_LEN) v = Shared.elide(v, MAX_FIELD_LEN)
  return v
}

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
  var input = String(raw || "")
  if (input.length > MAX_RAW_LEN) input = input.slice(0, MAX_RAW_LEN)
  var lines = input.split("\n")
  if (lines.length > MAX_LINES) lines = lines.slice(0, MAX_LINES)

  for (var i = 0; i < lines.length; i++) {
    var line = lines[i].trim()
    if (line === "") continue

    var connected = line.match(/^Connected to:\s*"([^"]*)"\s*(?:\(([^)]*)\))?/i)
    if (connected) {
      result.loaded = true
      result.connected = true
      result.server = sanitizeField(connected[1])
      result.category = sanitizeField(connected[2] || "")
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
    var value = sanitizeField(line.substring(separator + 1).trim())
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
  var input = String(raw || "")
  if (input.length > MAX_RAW_LEN) input = input.slice(0, MAX_RAW_LEN)
  var lines = input.split("\n")
  if (lines.length > MAX_LINES) lines = lines.slice(0, MAX_LINES)

  for (var i = 0; i < lines.length; i++) {
    if (servers.length >= MAX_SERVERS) break
    var match = lines[i].trim().match(/^\[(\d+)\]:\s*(.+?)\s*$/)
    if (!match) continue

    var n = parseInt(match[1], 10)
    if (!isFinite(n) || n < 1 || n > 9999 || n !== Math.floor(n)) continue
    // parseInt overflow / precision guard
    if (String(n) !== match[1].replace(/^0+/, "") && match[1] !== "0") {
      // allow leading zeros but verify numeric string round-trips; reject overflowed
      if (n > 9007199254740991) continue
    }
    var label = sanitizeField(match[2])
    // sanitizeField already caps at 120; further elide for server list
    if (label === "") continue
    servers.push({ number: n, label: label })
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
  // When no UUID is known, do not fall back to name match — that would let
  // any local user create a fake `eduVPN` connection and spoof `connected`.
  if (wantedUuid === "") return result

  var input = String(raw || "")
  if (input.length > MAX_RAW_LEN) input = input.slice(0, MAX_RAW_LEN)
  var lines = input.split("\n")
  if (lines.length > MAX_LINES) lines = lines.slice(0, MAX_LINES)

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
    // Require TYPE == wireguard unconditionally
    if (fields[2] !== "wireguard") continue
    if (fields[1] !== wantedUuid) continue

    result.connected = true
    result.uuid = fields[1]
    return result
  }
  return result
}

function parseUuid(raw) {
  var input = String(raw || "")
  if (input.length > 4096) input = input.slice(0, 4096)
  var lines = input.split("\n")
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
  if (status && status.server !== "") parts.push(sanitizeField(status.server))
  if (status && status.profile !== "") parts.push(sanitizeField(status.profile))
  return parts.length > 0 ? parts.join(" - ") : "Connected"
}

function details(status, connected) {
  if (!connected || !status) return []

  var rows = [
    Shared.detail("Server", sanitizeField(status.server)),
    Shared.detail("Profile", sanitizeField(status.profile)),
    Shared.detail("Protocol", sanitizeField(status.protocol)),
    Shared.detail("Validity", sanitizeField(status.validity)),
    Shared.detail("Location", sanitizeField(status.location))
  ]
  return rows.filter(function(row) { return row.value !== "" })
}

// eduVPN catches most command failures and still exits successfully. Keep only
// user-facing lines, leaving debug records and progress messages out of the bar.
function meaningfulError(raw) {
  var input = String(raw || "")
  if (input.length > MAX_RAW_LEN) input = input.slice(0, MAX_RAW_LEN)
  var candidates = []
  var lines = input.split("\n")
  if (lines.length > MAX_LINES) lines = lines.slice(0, MAX_LINES)

  for (var i = 0; i < lines.length; i++) {
    var line = lines[i].trim()
    if (line === "") continue
    if (/^Authorization needed\./i.test(line)) continue
    if (/^Disconnecting and renewing\.\.\.$/i.test(line)) continue

    // Do not blindly drop time= lines — they may contain the actual error.
    // Only drop pure debug lines that contain no error keyword.
    if (/^time=.*level=/i.test(line)) {
      if (!/(error|failed|failure|refused|expired)/i.test(line)) continue
    }

    if (/^(error|an error|please |you are |no |could not|unable|failed|failure)/i.test(line)
        || /(error|failed|failure|refused|expired)/i.test(line)) {
      candidates.push(line)
    }
  }
  // Keep first meaningful error, not last — attacker appending benign error would mask real one.
  return candidates.length > 0 ? Shared.elide(candidates[0], 160) : ""
}

// There can be one widget instance per monitor. Serializing all CLI calls also
// protects the shared eduVPN state and OAuth token files from overlapping
// registration/deregistration cycles.
function cli(args, lockPath) {
  var lock = String(lockPath || "")
  if (lock === "") {
    // Fail closed: no lock path means no serialization — refuse to run.
    // EduVpnBackend will surface this as a user-visible error.
    return ["/usr/bin/false", "missing lock path"]
  }
  return ["/usr/bin/flock", "-w", "30", lock, "/usr/bin/eduvpn-cli"].concat(args || [])
}

function connectArgs(serverNumber) {
  var n = Number(serverNumber)
  if (!isFinite(n) || Math.floor(n) !== n || n < 1 || n > 9999) throw new Error("invalid serverNumber")
  return ["-y", "connect", "-n", String(n)]
}

function disconnectArgs() {
  return ["-y", "disconnect"]
}

function renewArgs() {
  return ["-y", "renew"]
}
