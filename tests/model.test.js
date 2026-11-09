// Run: node tests/model.test.js
const fs = require("fs"), path = require("path"), vm = require("vm"), assert = require("assert")
const src = fs.readFileSync(path.join(__dirname, "..", "Model.js"), "utf8").replace(/^\.pragma library\s*/, "")
const sandbox = { module: { exports: {} } }
vm.runInNewContext(src, sandbox)
const M0 = sandbox.module.exports
const plain = v => JSON.parse(JSON.stringify(v))
const M = new Proxy(M0, { get: (o, k) => typeof o[k] === "function" ? (...a) => { const r = o[k](...a); return r && typeof r === "object" ? plain(r) : r } : o[k] })

const light = {
  sku: "H6008", device: "AA:BB", name: "Desk", type: "light", online: true,
  capabilities: [
    { type: "devices.capabilities.on_off", instance: "powerSwitch", parameters: {} },
    { type: "devices.capabilities.range", instance: "brightness", parameters: { unit: "unit.percent", range: { min: 1, max: 100, precision: 1 } } },
    { type: "devices.capabilities.color_setting", instance: "colorRgb", parameters: { range: { min: 0, max: 16777215, precision: 1 } } },
    { type: "devices.capabilities.color_setting", instance: "colorTemperatureK", parameters: { range: { min: 2000, max: 9000, precision: 1 } } },
    { type: "devices.capabilities.toggle", instance: "gradientToggle", parameters: {} },
    { type: "devices.capabilities.dynamic_scene", instance: "lightScene", parameters: { options: [] } },
    { type: "devices.capabilities.property", instance: "sensorTemperature", parameters: {} }
  ],
  state: { powerSwitch: 1, brightness: 40, colorRgb: 0xff0000, colorTemperatureK: 0, gradientToggle: 0, sensorTemperature: 21.46 }
}

const kinds = M.controlsFor(light).map(c => c.kind + ":" + (c.instance || ""))
assert.deepStrictEqual(kinds, ["slider:brightness", "color:colorRgb", "slider:colorTemperatureK", "toggle:gradientToggle", "scenes:lightScene", "readout:sensorTemperature"])
assert.strictEqual(M.isOn(light), true)
assert.strictEqual(M.countOn([light, { state: { powerSwitch: 0 } }]), 1)

const bright = M.controlsFor(light)[0]
assert.strictEqual(M.controlValue(bright, 55.6), 56)
assert.strictEqual(M.controlValue(bright, 500), 100)
const ct = M.controlsFor(light)[2]
assert.strictEqual(ct.value, 2000, "zero color temperature falls back to min")
assert.strictEqual(M.controlValue(ct, 4321), 4300)
assert.strictEqual(M.controlValue({ kind: "toggle" }, true), 1)
assert.strictEqual(M.intToHex(0xff0000), "#ff0000")
assert.strictEqual(M.hexToInt("#00ff00"), 0x00ff00)
assert.strictEqual(M.hexToInt("nope"), -1)
assert.strictEqual(M.controlsFor(light)[5].text, "21.5°")

const t = k => ({ "device.on": "On", "device.off": "Off", "device.offline": "Offline", "device.stateUnavailable": "?" })[k]
assert.strictEqual(M.deviceMeta(light, t), "On · 40% · 21.5°")
assert.strictEqual(M.deviceMeta({ ...light, online: false }, t), "Offline")

const next = M.applyLocal([light], "AA:BB", "powerSwitch", 0)
assert.strictEqual(next[0].state.powerSwitch, 0)
assert.strictEqual(light.state.powerSwitch, 1, "applyLocal must not mutate")
assert.strictEqual(M.applyLocal(next, "AA:BB", "colorRgb", 255)[0].state.powerSwitch, 1)

const heater = {
  capabilities: [{
    type: "devices.capabilities.work_mode", instance: "workMode",
    parameters: { fields: [
      { fieldName: "workMode", options: [{ name: "gearMode", value: 1 }, { name: "Fan", value: 9 }] },
      { fieldName: "modeValue", options: [{ name: "gearMode", options: [{ name: "Low", value: 1 }, { name: "High", value: 3 }] }, { name: "Fan", defaultValue: 0 }] }
    ] }
  }, {
    type: "devices.capabilities.temperature_setting", instance: "targetTemperature",
    parameters: { fields: [{ fieldName: "temperature", range: { min: 5, max: 30, precision: 1 } }, { fieldName: "unit", options: [{ name: "Celsius", value: "Celsius" }] }] }
  }],
  state: { workMode: { workMode: 1, modeValue: 3 } }
}
const hc = M.controlsFor(heater)
assert.deepStrictEqual(hc[0].options.map(o => o.label), ["Gear mode · Low", "Gear mode · High", "Fan"])
assert.ok(M.sameValue(hc[0].options[1].value, heater.state.workMode))
assert.deepStrictEqual(JSON.parse(JSON.stringify(M.controlValue(hc[1], 22.4))), { unit: "Celsius", temperature: 22 })

assert.strictEqual(M.humanize("oscillationToggle"), "Oscillation toggle")
const devs = [{ device: "a", state: { powerSwitch: 1 } }, { device: "b", hidden: true, state: { powerSwitch: 1 } }, { device: "c", state: {} }]
assert.deepStrictEqual(M.listed(devs, false).map(d => d.device), ["a", "c"])
assert.deepStrictEqual(M.listed(devs, true).map(d => d.device), ["a", "b", "c"])
assert.strictEqual(M.hiddenCount(devs), 1)
assert.strictEqual(M.countOn(M.active(devs)), 1, "hidden devices do not count as on")
const unhid = M.setHidden(devs, "b", false)
assert.strictEqual(unhid[1].hidden, false)
assert.strictEqual(devs[1].hidden, true, "setHidden must not mutate")
assert.strictEqual(M.hiddenCount(M.setHidden(devs, "a", true)), 2)
const ids = list => list.map(d => d.device).join("")
const five = ["a", "b", "c", "d", "e"].map(id => ({ device: id, hidden: id === "c", state: {} }))
assert.strictEqual(ids(M.moveDevice(five, false, "a", 1)), "bacde", "lands right after b; hidden c keeps its place")
assert.strictEqual(ids(M.moveDevice(five, false, "d", 0)), "dabce")
assert.strictEqual(ids(M.moveDevice(five, false, "e", 1)), "aebcd", "visible list a b d e; e lands before b")
assert.strictEqual(ids(M.moveDevice(five, true, "a", 2)), "bcade", "with hidden shown, c is a real slot")
assert.strictEqual(ids(M.moveDevice(five, false, "a", 99)), "bcdea", "clamped to the end")
assert.strictEqual(ids(M.moveDevice(five, false, "c", 0)), "abcde", "a hidden device can't move while hidden")
assert.strictEqual(ids(five), "abcde", "moveDevice must not mutate")
assert.strictEqual(ids(M.applyOrder(five, ["d", "b"])), "dbace", "unordered devices keep their order after")
console.log("model tests passed")
