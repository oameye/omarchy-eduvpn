.pragma library

// Keep glyphs as code points. Raw Nerd Font characters are easy to corrupt when
// a QML file is edited or copied through a terminal.
var GLYPH_VPN = String.fromCodePoint(0xF0582)
var GLYPH_REFRESH = String.fromCodePoint(0xF0450)

function detail(label, value) {
  return { label: label, value: String(value || "") }
}

function elide(text, limit) {
  var value = String(text || "").replace(/\s+/g, " ").trim()
  return value.length > limit ? value.substring(0, limit - 1) + "..." : value
}
