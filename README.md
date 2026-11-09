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
4. To hide a device you don't want in the panel, expand it and press **Hide device**, or select it and press **X**.
   Hidden devices are left out of the list, the on count, the bar icon, and "all on/off". The eye button at the bottom
   of the panel shows them again (dimmed) so you can unhide them. The list is kept in
   `~/.config/omarchy/govee/hidden.json` and survives changing or forgetting the API key.
5. To reorder devices, drag one up or down by its icon, or select it and press **Ctrl+↑ / Ctrl+↓**. The order is
   saved in `~/.config/omarchy/govee/order.json`; devices added to your Govee account later appear at the end.

| Input | Action |
|---|---|
| Left click on the bulb | Open the panel |
| Right click on the bulb | Turn all devices on or off |
| Middle click on the bulb | Refresh |
| ↑ / ↓, Enter or Space | Move between devices, expand one |
| P | Toggle power on the selected device |
| Ctrl+↑ / Ctrl+↓ (or Ctrl+K / Ctrl+J) | Move the selected device up or down the list |
| X or Delete | Hide the selected device, or unhide it while hidden devices are shown |
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
