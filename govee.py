#!/usr/bin/env python3
"""Govee helper for the Omarchy Govee shell plugin.

Talks to the Govee Developer Platform API (openapi.api.govee.com) and prints
one JSON object on stdout for every command, so the QML side never has to
parse anything but JSON. All untrusted strings coming back from the API are
bounded before they are printed.

Commands:
  status                          -> {"ok": true, "configured": bool}
  set-key                         (key read from stdin, one line) -> validates and saves it
  clear-key                       -> forgets the saved key
  devices                         -> device list with current state
  control <sku> <device> <type> <instance> <value-json>
  scenes <sku> <device>           -> light scenes for one device
  hide <device> / unhide <device> -> hide a device from the panel, or show it again
  set-order <device>...           -> save the order devices are listed in

The key lives in $XDG_CONFIG_HOME/omarchy/govee/config.json with mode 0600.
Hidden device ids (hidden.json) and the list order (order.json) live beside it,
so forgetting the key keeps them.
GOVEE_API_KEY in the environment overrides the saved key.
"""

import json
import os
import re
import sys
import tempfile
import urllib.error
import urllib.request
import uuid
from concurrent.futures import ThreadPoolExecutor

API_BASE = "https://openapi.api.govee.com/router/api/v1"
TIMEOUT = 10
MAX_RESPONSE_BYTES = 2 * 1024 * 1024
MAX_DEVICES = 100
MAX_CAPABILITIES = 40
MAX_OPTIONS = 200
MAX_STR = 120

CONFIG_DIR = os.path.join(
    os.environ.get("XDG_CONFIG_HOME") or os.path.expanduser("~/.config"), "omarchy", "govee"
)
CONFIG_FILE = os.path.join(CONFIG_DIR, "config.json")
HIDDEN_FILE = os.path.join(CONFIG_DIR, "hidden.json")
ORDER_FILE = os.path.join(CONFIG_DIR, "order.json")
MAX_HIDDEN = 500

SAFE_ID = re.compile(r"^[A-Za-z0-9:._-]{1,64}$")
SAFE_CAP_TYPE = re.compile(r"^devices\.capabilities\.[a-z_]{1,48}$")
SAFE_INSTANCE = re.compile(r"^[A-Za-z0-9_]{1,48}$")


class GoveeError(Exception):
    pass


def out(obj, code=0):
    sys.stdout.write(json.dumps(obj, separators=(",", ":")) + "\n")
    sys.stdout.flush()
    sys.exit(code)


def fail(message, **extra):
    payload = {"ok": False, "error": clip(message, 300)}
    payload.update(extra)
    out(payload, 1)


def clip(value, limit=MAX_STR):
    text = "" if value is None else str(value)
    text = "".join(ch for ch in text if ch == " " or ch.isprintable())
    return text[:limit]


# ----------------------------------------------------------------- config


def load_key():
    env = os.environ.get("GOVEE_API_KEY", "").strip()
    if env:
        return env
    try:
        with open(CONFIG_FILE, "r", encoding="utf-8") as fh:
            data = json.load(fh)
        return str(data.get("apiKey") or "").strip()
    except (OSError, ValueError):
        return ""


def write_private_json(path, data):
    os.makedirs(CONFIG_DIR, mode=0o700, exist_ok=True)
    fd, tmp = tempfile.mkstemp(prefix=".tmp.", dir=CONFIG_DIR)
    try:
        os.fchmod(fd, 0o600)
        with os.fdopen(fd, "w", encoding="utf-8") as fh:
            json.dump(data, fh)
        os.replace(tmp, path)
    except BaseException:
        try:
            os.unlink(tmp)
        except OSError:
            pass
        raise


def save_key(key):
    write_private_json(CONFIG_FILE, {"apiKey": key})


def load_id_list(path, key):
    try:
        with open(path, "r", encoding="utf-8") as fh:
            data = json.load(fh)
    except (OSError, ValueError):
        return []
    ids = data.get(key) if isinstance(data, dict) else None
    if not isinstance(ids, list):
        return []
    return [i for i in ids if isinstance(i, str) and SAFE_ID.match(i)][:MAX_HIDDEN]


def load_hidden():
    return load_id_list(HIDDEN_FILE, "hidden")


def load_order():
    return load_id_list(ORDER_FILE, "order")


def apply_order(devices, order):
    """Saved order first; devices not in it keep Govee's order after them."""
    rank = {dev_id: i for i, dev_id in enumerate(order)}
    indexed = list(enumerate(devices))
    indexed.sort(key=lambda p: (rank.get(p[1]["device"], len(rank) + p[0])))
    return [d for _, d in indexed]


def set_hidden(device, hidden):
    ids = [i for i in load_hidden() if i != device]
    if hidden:
        ids.append(device)
    write_private_json(HIDDEN_FILE, {"hidden": ids[-MAX_HIDDEN:]})
    return ids


def clear_key():
    try:
        os.unlink(CONFIG_FILE)
    except FileNotFoundError:
        pass


# -------------------------------------------------------------------- http


def request(key, method, path, body=None):
    data = None
    headers = {
        "Govee-API-Key": key,
        "Accept": "application/json",
        "User-Agent": "omarchy-govee-plugin/1.0",
    }
    if body is not None:
        data = json.dumps(body).encode("utf-8")
        headers["Content-Type"] = "application/json"
    req = urllib.request.Request(API_BASE + path, data=data, headers=headers, method=method)
    try:
        with urllib.request.urlopen(req, timeout=TIMEOUT) as resp:
            raw = resp.read(MAX_RESPONSE_BYTES + 1)
    except urllib.error.HTTPError as exc:
        if exc.code in (401, 403):
            raise GoveeError("auth")
        if exc.code == 429:
            raise GoveeError("Rate limited by Govee. Try again in a minute.")
        detail = ""
        try:
            detail = json.loads(exc.read(65536) or b"{}").get("message", "")
        except (ValueError, AttributeError, OSError):
            pass
        raise GoveeError("Govee API error %d%s" % (exc.code, (": " + clip(detail)) if detail else ""))
    except urllib.error.URLError as exc:
        raise GoveeError("Network error: %s" % clip(getattr(exc, "reason", exc)))
    except TimeoutError:
        raise GoveeError("Govee API timed out")

    if len(raw) > MAX_RESPONSE_BYTES:
        raise GoveeError("Govee response too large")
    try:
        payload = json.loads(raw.decode("utf-8"))
    except ValueError:
        raise GoveeError("Govee returned invalid JSON")
    if not isinstance(payload, dict):
        raise GoveeError("Govee returned an unexpected response")
    code = payload.get("code")
    if code in (401, 403):
        raise GoveeError("auth")
    if code is not None and code != 200:
        raise GoveeError("Govee: %s" % clip(payload.get("message") or payload.get("msg") or code))
    return payload


# ------------------------------------------------------------- sanitizers


def sanitize_json_value(value, depth=0):
    """Bounded copy of an arbitrary JSON value (used for option values)."""
    if depth > 4:
        return None
    if isinstance(value, bool) or value is None:
        return value
    if isinstance(value, (int, float)):
        return value
    if isinstance(value, str):
        return clip(value, 200)
    if isinstance(value, list):
        return [sanitize_json_value(v, depth + 1) for v in value[:50]]
    if isinstance(value, dict):
        return {clip(k, 48): sanitize_json_value(v, depth + 1) for k, v in list(value.items())[:30]}
    return None


def sanitize_options(options, depth=0):
    result = []
    if not isinstance(options, list):
        return result
    for opt in options[:MAX_OPTIONS]:
        if not isinstance(opt, dict):
            continue
        clean = {"name": clip(opt.get("name"), 80), "value": sanitize_json_value(opt.get("value"))}
        # work_mode puts per-mode sub-options (or a defaultValue) one level down.
        if depth == 0 and isinstance(opt.get("options"), list):
            clean["options"] = sanitize_options(opt.get("options"), depth + 1)
        if "defaultValue" in opt:
            clean["defaultValue"] = sanitize_json_value(opt.get("defaultValue"))
        if isinstance(opt.get("range"), dict):
            clean["range"] = {
                "min": num(opt["range"].get("min"), 0),
                "max": num(opt["range"].get("max"), 100),
                "precision": num(opt["range"].get("precision"), 1),
            }
        result.append(clean)
    return result


def num(value, fallback=None):
    if isinstance(value, bool):
        return fallback
    if isinstance(value, (int, float)):
        return value
    return fallback


def sanitize_parameters(params):
    if not isinstance(params, dict):
        return {}
    clean = {"dataType": clip(params.get("dataType"), 24), "unit": clip(params.get("unit"), 24)}
    rng = params.get("range")
    if isinstance(rng, dict):
        clean["range"] = {
            "min": num(rng.get("min"), 0),
            "max": num(rng.get("max"), 100),
            "precision": num(rng.get("precision"), 1),
        }
    if "options" in params:
        clean["options"] = sanitize_options(params.get("options"))
    fields = params.get("fields")
    if isinstance(fields, list):
        clean["fields"] = []
        for field in fields[:10]:
            if not isinstance(field, dict):
                continue
            clean["fields"].append({
                "fieldName": clip(field.get("fieldName"), 48),
                "options": sanitize_options(field.get("options")),
                "range": sanitize_parameters({"range": field.get("range")}).get("range"),
            })
    return clean


def sanitize_capability(cap):
    if not isinstance(cap, dict):
        return None
    ctype = str(cap.get("type") or "")
    instance = str(cap.get("instance") or "")
    if not SAFE_CAP_TYPE.match(ctype) or not SAFE_INSTANCE.match(instance):
        return None
    return {"type": ctype, "instance": instance, "parameters": sanitize_parameters(cap.get("parameters"))}


def sanitize_device(dev):
    if not isinstance(dev, dict):
        return None
    sku = str(dev.get("sku") or "")
    device = str(dev.get("device") or "")
    if not SAFE_ID.match(sku) or not SAFE_ID.match(device):
        return None
    caps = []
    for cap in (dev.get("capabilities") or [])[:MAX_CAPABILITIES]:
        clean = sanitize_capability(cap)
        if clean:
            caps.append(clean)
    dtype = clip(dev.get("type"), 64)
    return {
        "sku": sku,
        "device": device,
        "name": clip(dev.get("deviceName") or sku, 80),
        "type": dtype.rsplit(".", 1)[-1] if dtype else "",
        "capabilities": caps,
        "state": {},
        "online": None,
    }


# ---------------------------------------------------------------- commands


def require_key():
    key = load_key()
    if not key:
        fail("No Govee API key configured", needsKey=True)
    return key


def fetch_devices(key):
    payload = request(key, "GET", "/user/devices")
    devices = []
    for dev in (payload.get("data") or [])[:MAX_DEVICES]:
        clean = sanitize_device(dev)
        if clean:
            devices.append(clean)
    return devices


def fetch_state(key, dev):
    body = {"requestId": str(uuid.uuid4()), "payload": {"sku": dev["sku"], "device": dev["device"]}}
    try:
        payload = request(key, "POST", "/device/state", body)
    except GoveeError as exc:
        dev["stateError"] = clip(exc, 160)
        return dev
    caps = ((payload.get("payload") or {}).get("capabilities")) or []
    state = {}
    for cap in caps[:MAX_CAPABILITIES]:
        if not isinstance(cap, dict):
            continue
        instance = str(cap.get("instance") or "")
        if not SAFE_INSTANCE.match(instance):
            continue
        value = (cap.get("state") or {}).get("value") if isinstance(cap.get("state"), dict) else None
        state[instance] = sanitize_json_value(value)
        if instance == "online":
            dev["online"] = bool(value) if isinstance(value, bool) else value in (1, "true", "True")
    dev["state"] = state
    return dev


def cmd_devices():
    key = require_key()
    try:
        devices = fetch_devices(key)
    except GoveeError as exc:
        if str(exc) == "auth":
            fail("Govee rejected the API key", needsKey=True)
        fail(str(exc))
    devices = apply_order(devices, load_order())
    hidden = set(load_hidden())
    for dev in devices:
        dev["hidden"] = dev["device"] in hidden
    if devices:
        with ThreadPoolExecutor(max_workers=min(8, len(devices))) as pool:
            devices = list(pool.map(lambda d: fetch_state(key, d), devices))
    out({"ok": True, "devices": devices})


def cmd_set_key():
    key = sys.stdin.readline().strip()
    if not key:
        fail("Enter an API key")
    if len(key) > 128 or not re.match(r"^[A-Za-z0-9_-]+$", key):
        fail("That does not look like a Govee API key")
    try:
        devices = fetch_devices(key)
    except GoveeError as exc:
        if str(exc) == "auth":
            fail("Govee rejected that API key")
        fail(str(exc))
    save_key(key)
    out({"ok": True, "deviceCount": len(devices)})


def cmd_control(args):
    if len(args) != 5:
        fail("usage: control <sku> <device> <type> <instance> <value-json>")
    sku, device, ctype, instance, value_json = args
    if not SAFE_ID.match(sku) or not SAFE_ID.match(device):
        fail("Invalid device id")
    if not SAFE_CAP_TYPE.match(ctype) or not SAFE_INSTANCE.match(instance):
        fail("Invalid capability")
    if len(value_json) > 4096:
        fail("Value too large")
    try:
        value = json.loads(value_json)
    except ValueError:
        fail("Value is not JSON")
    key = require_key()
    body = {
        "requestId": str(uuid.uuid4()),
        "payload": {
            "sku": sku,
            "device": device,
            "capability": {"type": ctype, "instance": instance, "value": value},
        },
    }
    try:
        request(key, "POST", "/device/control", body)
    except GoveeError as exc:
        if str(exc) == "auth":
            fail("Govee rejected the API key", needsKey=True)
        fail(str(exc))
    out({"ok": True, "device": device, "instance": instance, "value": sanitize_json_value(value)})


def cmd_scenes(args):
    if len(args) != 2 or not SAFE_ID.match(args[0]) or not SAFE_ID.match(args[1]):
        fail("usage: scenes <sku> <device>")
    key = require_key()
    body = {"requestId": str(uuid.uuid4()), "payload": {"sku": args[0], "device": args[1]}}
    try:
        payload = request(key, "POST", "/device/scenes", body)
    except GoveeError as exc:
        fail("Govee rejected the API key" if str(exc) == "auth" else str(exc))
    options = []
    for cap in ((payload.get("payload") or {}).get("capabilities") or [])[:10]:
        clean = sanitize_capability(cap)
        if clean and clean["instance"] == "lightScene":
            options.extend(clean["parameters"].get("options") or [])
    out({"ok": True, "device": args[1], "scenes": options[:MAX_OPTIONS]})


def cmd_hide(args, hidden):
    if len(args) != 1 or not SAFE_ID.match(args[0]):
        fail("usage: %s <device>" % ("hide" if hidden else "unhide"))
    set_hidden(args[0], hidden)
    out({"ok": True, "device": args[0], "hidden": hidden})


def cmd_set_order(args):
    if not args or len(args) > MAX_HIDDEN or not all(SAFE_ID.match(a) for a in args):
        fail("usage: set-order <device>...")
    seen = []
    for dev_id in args:
        if dev_id not in seen:
            seen.append(dev_id)
    write_private_json(ORDER_FILE, {"order": seen})
    out({"ok": True, "count": len(seen)})


def main(argv):
    if not argv:
        fail("missing command")
    cmd, args = argv[0], argv[1:]
    try:
        if cmd == "status":
            out({"ok": True, "configured": bool(load_key())})
        elif cmd == "set-key":
            cmd_set_key()
        elif cmd == "clear-key":
            clear_key()
            out({"ok": True})
        elif cmd == "devices":
            cmd_devices()
        elif cmd == "control":
            cmd_control(args)
        elif cmd == "scenes":
            cmd_scenes(args)
        elif cmd == "hide":
            cmd_hide(args, True)
        elif cmd == "unhide":
            cmd_hide(args, False)
        elif cmd == "set-order":
            cmd_set_order(args)
        else:
            fail("unknown command: %s" % clip(cmd, 40))
    except GoveeError as exc:
        fail(str(exc))
    except OSError as exc:
        fail("Local error: %s" % clip(exc, 200))


if __name__ == "__main__":
    main(sys.argv[1:])
