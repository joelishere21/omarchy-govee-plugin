# Govee for Omarchy

An Omarchy shell bar widget that controls every device on your Govee account through the
[Govee Developer API](https://developer.govee.com/).

## Install

```bash
./install.sh
```

This copies the plugin to `~/.config/omarchy/plugins/govee` and adds it to the right side of the bar.

## Use

1. Get an API key: in the Govee Home app open **Profile → Settings → Apply for API Key**. Govee emails it to you.
2. Click the bulb in the bar, paste the key, and press **Save**. The key is checked against Govee before it is saved
   to `~/.config/omarchy/govee/config.json` (mode 0600). `GOVEE_API_KEY` in the environment overrides the saved key.
3. Each device shows a power switch. Click a device to expand it and get the controls it supports: brightness,
   color, color temperature, toggles, modes, scenes, target temperature, and sensor readings.

| Input | Action |
|---|---|
| Left click on the bulb | Open the panel |
| Right click on the bulb | Turn all devices on or off |
| Middle click on the bulb | Refresh |
| ↑ / ↓, Enter | Move between devices, expand one |
| P or Space | Toggle power on the selected device |
| R | Refresh |

IPC: `omarchy-shell govee {open|close|toggle|refresh|allOn|allOff|status}`.

## Settings

Set these in the widget's settings (stored in `shell.json`):

- `refreshIntervalSec` (default 30): how often state refreshes while the panel is open.
- `backgroundRefresh` (default off): keep polling while the panel is closed so the bar icon shows whether anything is on.
- `backgroundRefreshSec` (default 300): how often the background refresh runs.

A refresh makes one request for the device list plus one per device. Govee allows 10,000 requests a day per account.

## Develop

```bash
node tests/model.test.js
python3 -I tests/test_govee.py
```
