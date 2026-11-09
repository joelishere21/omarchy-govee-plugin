.pragma library

// Pure helpers that turn a Govee device record (as printed by govee.py) into
// the controls the panel draws. Kept free of QML so it can be unit tested
// under plain node (see tests/model.test.js).

var CAP = "devices.capabilities."

function glyph(cp) { return String.fromCodePoint(cp) }

var TYPE_GLYPHS = {
  light: 0xF0335,          // lightbulb
  socket: 0xF06A5,         // power-socket-us
  fan: 0xF0210,            // fan
  heater: 0xF0438,         // radiator
  humidifier: 0xF058E,     // water-percent
  dehumidifier: 0xF058E,
  air_purifier: 0xF0210,
  thermometer: 0xF050F,    // thermometer
  sensor: 0xF050F,
  kettle: 0xF05FA,         // kettle
  aroma_diffuser: 0xF058C, // water
  ice_maker: 0xF0717       // snowflake
}

function typeGlyph(type) {
  return glyph(TYPE_GLYPHS[type] || TYPE_GLYPHS.light)
}

function findCap(dev, type, instance) {
  var caps = (dev && dev.capabilities) || []
  for (var i = 0; i < caps.length; i++) {
    if (caps[i].type === CAP + type && (instance === undefined || caps[i].instance === instance)) return caps[i]
  }
  return null
}

function stateOf(dev, instance) {
  return dev && dev.state ? dev.state[instance] : undefined
}

function hasPower(dev) { return findCap(dev, "on_off", "powerSwitch") !== null }

function isOn(dev) {
  var v = stateOf(dev, "powerSwitch")
  return v === 1 || v === true
}

function isOnline(dev) {
  // Devices that do not report "online" are assumed reachable.
  return !dev || dev.online !== false
}

function humanize(instance) {
  var s = String(instance || "").replace(/([a-z0-9])([A-Z])/g, "$1 $2").replace(/_/g, " ").toLowerCase()
  return s.charAt(0).toUpperCase() + s.slice(1)
}

function clamp(v, lo, hi) { return Math.max(lo, Math.min(hi, v)) }

function rangeOf(cap, fallbackMin, fallbackMax) {
  var r = cap && cap.parameters && cap.parameters.range
  var min = r && isFinite(r.min) ? r.min : fallbackMin
  var max = r && isFinite(r.max) ? r.max : fallbackMax
  var step = r && isFinite(r.precision) && r.precision > 0 ? r.precision : 1
  if (max <= min) max = min + 1
  return { min: min, max: max, step: step }
}

function rgbToInt(r, g, b) {
  return ((clamp(Math.round(r), 0, 255) << 16) | (clamp(Math.round(g), 0, 255) << 8) | clamp(Math.round(b), 0, 255)) >>> 0
}

function intToHex(n) {
  if (typeof n !== "number" || !isFinite(n)) return ""
  var hex = (n >>> 0 & 0xFFFFFF).toString(16)
  while (hex.length < 6) hex = "0" + hex
  return "#" + hex
}

function hexToInt(hex) {
  var m = /^#?([0-9a-fA-F]{6})$/.exec(String(hex || ""))
  return m ? parseInt(m[1], 16) : -1
}

var SWATCHES = ["#ff3b30", "#ff9500", "#ffcc00", "#34c759", "#00c7be", "#007aff", "#5856d6", "#af52de", "#ff2d55", "#ffffff"]

function sameValue(a, b) {
  if (a === b) return true
  if (a === undefined || b === undefined || a === null || b === null) return false
  try { return JSON.stringify(a) === JSON.stringify(b) } catch (e) { return false }
}

function workModeChoices(cap) {
  var fields = (cap.parameters && cap.parameters.fields) || []
  var modes = null, values = null
  for (var i = 0; i < fields.length; i++) {
    if (fields[i].fieldName === "workMode") modes = fields[i].options || []
    else if (fields[i].fieldName === "modeValue") values = fields[i].options || []
  }
  if (!modes) return []
  var choices = []
  for (var m = 0; m < modes.length; m++) {
    var mode = modes[m]
    var sub = null
    for (var v = 0; values && v < values.length; v++) if (values[v].name === mode.name) sub = values[v]
    if (sub && sub.options && sub.options.length > 0) {
      for (var s = 0; s < sub.options.length; s++) {
        choices.push({
          label: humanize(mode.name) + " · " + sub.options[s].name,
          value: { workMode: mode.value, modeValue: sub.options[s].value }
        })
      }
    } else {
      var dv = sub && sub.defaultValue !== undefined ? sub.defaultValue : (sub && sub.range ? sub.range.min : 0)
      choices.push({ label: humanize(mode.name), value: { workMode: mode.value, modeValue: dv } })
    }
  }
  return choices
}

function temperatureControl(cap, dev) {
  var fields = (cap.parameters && cap.parameters.fields) || []
  var range = null, unit = "Celsius"
  for (var i = 0; i < fields.length; i++) {
    if (fields[i].fieldName === "temperature" && fields[i].range) range = fields[i].range
    if (fields[i].fieldName === "unit" && fields[i].options && fields[i].options.length) unit = String(fields[i].options[0].value)
  }
  if (!range) return null
  var current = stateOf(dev, cap.instance)
  var value = current && typeof current === "object" ? current.temperature : current
  return {
    kind: "slider", type: cap.type, instance: cap.instance, label: humanize(cap.instance),
    min: range.min, max: range.max, step: range.precision > 0 ? range.precision : 1,
    value: typeof value === "number" ? value : range.min,
    unit: unit === "Fahrenheit" ? "°F" : "°C",
    wrap: { key: "temperature", extra: { unit: unit } }
  }
}

// Ordered list of controls for the expanded device card. powerSwitch is not
// included: it lives on the device row itself.
function controlsFor(dev) {
  var caps = (dev && dev.capabilities) || []
  var controls = []
  var readouts = []

  for (var i = 0; i < caps.length; i++) {
    var cap = caps[i]
    var kind = cap.type.indexOf(CAP) === 0 ? cap.type.slice(CAP.length) : ""
    var value = stateOf(dev, cap.instance)
    var params = cap.parameters || {}

    if (kind === "on_off") {
      if (cap.instance !== "powerSwitch") controls.push({ kind: "toggle", type: cap.type, instance: cap.instance, label: humanize(cap.instance), value: value === 1 || value === true })
    } else if (kind === "toggle") {
      controls.push({ kind: "toggle", type: cap.type, instance: cap.instance, label: humanize(cap.instance), value: value === 1 || value === true })
    } else if (kind === "range") {
      var r = rangeOf(cap, cap.instance === "brightness" ? 1 : 0, 100)
      controls.push({
        kind: "slider", type: cap.type, instance: cap.instance, label: humanize(cap.instance),
        min: r.min, max: r.max, step: r.step, value: typeof value === "number" ? value : r.min,
        unit: params.unit === "unit.percent" || cap.instance === "brightness" ? "%" : ""
      })
    } else if (kind === "color_setting" && cap.instance === "colorRgb") {
      controls.push({ kind: "color", type: cap.type, instance: cap.instance, label: "Color", value: typeof value === "number" ? value : -1 })
    } else if (kind === "color_setting" && cap.instance === "colorTemperatureK") {
      var t = rangeOf(cap, 2000, 9000)
      controls.push({
        kind: "slider", type: cap.type, instance: cap.instance, label: "Color temperature",
        min: t.min, max: t.max, step: Math.max(t.step, 100), value: typeof value === "number" && value > 0 ? value : t.min, unit: "K",
        warmCool: true
      })
    } else if (kind === "work_mode") {
      var wm = workModeChoices(cap)
      if (wm.length) controls.push({ kind: "choice", type: cap.type, instance: cap.instance, label: "Mode", options: wm, value: value })
    } else if (kind === "mode" || kind === "dynamic_scene") {
      var opts = params.options || []
      if (opts.length) {
        controls.push({
          kind: "choice", type: cap.type, instance: cap.instance, label: humanize(cap.instance),
          options: opts.map(function(o) { return { label: o.name, value: o.value } }), value: value
        })
      } else if (kind === "dynamic_scene" && cap.instance === "lightScene") {
        controls.push({ kind: "scenes", type: cap.type, instance: cap.instance, label: "Scene", options: [], value: value })
      }
    } else if (kind === "temperature_setting") {
      var tc = temperatureControl(cap, dev)
      if (tc) controls.push(tc)
    } else if (kind === "property") {
      if (value !== undefined && value !== null && typeof value !== "object") readouts.push({ kind: "readout", instance: cap.instance, label: humanize(cap.instance.replace(/^sensor/, "")), text: formatReading(cap.instance, value) })
    }
  }

  return controls.concat(readouts)
}

function formatReading(instance, value) {
  if (typeof value !== "number") return String(value)
  if (/humidity/i.test(instance)) return Math.round(value) + "%"
  if (/temperature/i.test(instance)) return (Math.round(value * 10) / 10) + "°"
  return String(value)
}

// The JSON value sent to /device/control for a control at a given raw value.
function controlValue(control, raw) {
  if (control.kind === "toggle") return raw ? 1 : 0
  if (control.kind === "slider") {
    var v = clamp(Math.round(raw / control.step) * control.step, control.min, control.max)
    v = Math.round(v * 1000) / 1000
    if (control.wrap) {
      var obj = {}
      for (var k in control.wrap.extra) obj[k] = control.wrap.extra[k]
      obj[control.wrap.key] = v
      return obj
    }
    return v
  }
  if (control.kind === "color") return typeof raw === "number" ? raw : hexToInt(raw)
  return raw
}

// Short status line under a device's name.
function deviceMeta(dev, t) {
  if (!isOnline(dev)) return t("device.offline")
  if (dev.stateError) return t("device.stateUnavailable")
  var parts = []
  if (hasPower(dev)) parts.push(isOn(dev) ? t("device.on") : t("device.off"))
  var b = stateOf(dev, "brightness")
  if (isOn(dev) && typeof b === "number") parts.push(Math.round(b) + "%")
  var temp = stateOf(dev, "sensorTemperature")
  if (typeof temp === "number") parts.push(formatReading("sensorTemperature", temp))
  var hum = stateOf(dev, "sensorHumidity")
  if (typeof hum === "number") parts.push(formatReading("sensorHumidity", hum))
  if (parts.length === 0) parts.push(dev.sku)
  return parts.join(" · ")
}

function countOn(devices) {
  var n = 0
  for (var i = 0; i < (devices || []).length; i++) if (isOn(devices[i])) n++
  return n
}

// Merge a successful control into the device list without a round trip, so
// the UI reflects the change immediately (Govee state reads can lag).
function applyLocal(devices, deviceId, instance, value) {
  var next = []
  for (var i = 0; i < devices.length; i++) {
    var d = devices[i]
    if (d.device !== deviceId) { next.push(d); continue }
    var copy = {}
    for (var k in d) copy[k] = d[k]
    var state = {}
    for (var s in d.state || {}) state[s] = d.state[s]
    state[instance] = value
    // Picking a color or temperature turns most lights on.
    if ((instance === "colorRgb" || instance === "colorTemperatureK" || instance === "brightness") && hasPower(d)) state.powerSwitch = 1
    copy.state = state
    next.push(copy)
  }
  return next
}

function isHidden(dev) { return !!dev && dev.hidden === true }

// Devices the panel lists: hidden ones only while "show hidden" is on.
function listed(devices, showHidden) {
  return (devices || []).filter(function(d) { return showHidden || !isHidden(d) })
}

// Devices that count toward the summary, the bar icon, and "all on/off".
function active(devices) {
  return (devices || []).filter(function(d) { return !isHidden(d) })
}

function hiddenCount(devices) {
  return (devices || []).length - active(devices).length
}

function setHidden(devices, deviceId, hidden) {
  return (devices || []).map(function(d) {
    if (d.device !== deviceId) return d
    var copy = {}
    for (var k in d) copy[k] = d[k]
    copy.hidden = !!hidden
    return copy
  })
}

// Move a device to position `to` of the list the user sees (hidden devices
// left out unless shown) and return the full, reordered device array. Hidden
// devices the user can't see keep their place relative to their neighbors.
function moveDevice(devices, showHidden, deviceId, to) {
  var all = (devices || []).slice()
  var shown = listed(all, showHidden)
  var from = -1
  for (var i = 0; i < shown.length; i++) if (shown[i].device === deviceId) from = i
  if (from < 0 || shown.length < 2) return all
  to = clamp(to, 0, shown.length - 1)
  if (to === from) return all
  var target = shown[to]
  var moving = all.splice(all.indexOf(shown[from]), 1)[0]
  var at = all.indexOf(target)
  all.splice(to > from ? at + 1 : at, 0, moving)
  return all
}

// Sort by a list of device ids; devices not in it follow in their own order.
function applyOrder(devices, order) {
  var rank = {}
  for (var i = 0; i < (order || []).length; i++) rank[order[i]] = i
  var n = (order || []).length
  return (devices || []).map(function(d, i) { return { d: d, k: rank[d.device] !== undefined ? rank[d.device] : n + i } })
    .sort(function(a, b) { return a.k - b.k })
    .map(function(p) { return p.d })
}

function deviceIds(devices) {
  return (devices || []).map(function(d) { return d.device })
}

if (typeof module !== "undefined") {
  module.exports = {
    typeGlyph: typeGlyph, findCap: findCap, hasPower: hasPower, isOn: isOn, isOnline: isOnline,
    humanize: humanize, controlsFor: controlsFor, controlValue: controlValue, deviceMeta: deviceMeta,
    countOn: countOn, applyLocal: applyLocal, intToHex: intToHex, hexToInt: hexToInt, rgbToInt: rgbToInt,
    sameValue: sameValue, isHidden: isHidden, listed: listed, active: active, hiddenCount: hiddenCount, setHidden: setHidden, moveDevice: moveDevice, applyOrder: applyOrder, deviceIds: deviceIds, workModeChoices: workModeChoices, SWATCHES: SWATCHES
  }
}
