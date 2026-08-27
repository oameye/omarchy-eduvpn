const { test, eq, EduVpn } = require("../harness.js")

test("parseStatus ignores debug output and reads a connected profile", () => {
  const status = EduVpn.parseStatus([
    "time=2026-08-27T14:42:40+02:00 level=DEBUG msg=Client registered",
    'Connected to: "University Konstanz" (Institute Access Server)',
    "Valid for: 29d 23h 29m 55s",
    "Current profile: Remote Access VPN",
    "VPN Protocol: WireGuard",
  ].join("\n"))

  eq(status, {
    loaded: true,
    connected: true,
    server: "University Konstanz",
    category: "Institute Access Server",
    validity: "29d 23h 29m 55s",
    profile: "Remote Access VPN",
    location: "",
    protocol: "WireGuard",
    statusText: "Connected",
  })
})

test("parseStatus accepts the disconnected stderr message", () => {
  eq(EduVpn.parseStatus("You are currently not connected to a server"), {
    loaded: true,
    connected: false,
    server: "",
    category: "",
    validity: "",
    profile: "",
    location: "",
    protocol: "",
    statusText: "Not connected",
  })
})

test("parseConfiguredServers reads the numbered configured server list", () => {
  eq(EduVpn.parseConfiguredServers([
    "============================",
    "Institute Access Servers",
    "============================",
    "[1]: University Konstanz",
    "[2]: Another University",
    "The number for the server is in [brackets]",
  ].join("\n")), [
    { number: 1, label: "University Konstanz" },
    { number: 2, label: "Another University" },
  ])
})

test("parseNmcliActive matches the eduVPN UUID, not another active tunnel", () => {
  const raw = [
    "Mullvad\\: wg:11111111-1111-4111-8111-111111111111:wireguard:yes",
    "eduVPN:22222222-2222-4222-8222-222222222222:wireguard:yes",
  ].join("\n")

  eq(EduVpn.parseNmcliActive(raw, "22222222-2222-4222-8222-222222222222", "eduVPN"), {
    connected: true,
    uuid: "22222222-2222-4222-8222-222222222222",
  })
  eq(EduVpn.parseNmcliActive(raw, "33333333-3333-4333-8333-333333333333", "eduVPN"), {
    connected: false,
    uuid: "",
  })
})

test("parseNmcliActive does not fall back to name without a UUID", () => {
  eq(EduVpn.parseNmcliActive(
    "eduVPN:22222222-2222-4222-8222-222222222222:wireguard:yes",
    "",
    "eduVPN"
  ), {
    connected: false,
    uuid: "",
  })
})

test("parseNmcliActive requires TYPE wireguard", () => {
  eq(EduVpn.parseNmcliActive(
    "eduVPN:22222222-2222-4222-8222-222222222222:ethernet:yes",
    "22222222-2222-4222-8222-222222222222",
    "eduVPN"
  ), {
    connected: false,
    uuid: "",
  })
})

test("meaningfulError drops debug and progress lines", () => {
  eq(EduVpn.meaningfulError([
    "time=2026-08-27T14:42:40+02:00 level=DEBUG msg=Client registered",
    "Disconnecting and renewing...",
    "Error renewing: authorization was rejected",
  ].join("\n")), "Error renewing: authorization was rejected")
})

test("action argument builders use the configured server number", () => {
  eq(EduVpn.connectArgs(1), ["-y", "connect", "-n", "1"])
  eq(EduVpn.disconnectArgs(), ["-y", "disconnect"])
  eq(EduVpn.renewArgs(), ["-y", "renew"])
})
