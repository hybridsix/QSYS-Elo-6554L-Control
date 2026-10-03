# Elo 6554L Control - Q-SYS Plugin

**Author:** Michael King / Hybridsix  **Version:** 0.1.1  **Platform:** Q-SYS Designer, Elo 6554L (ET6554L, IDS54 family)

A Q-SYS plugin that gives your Core direct control over an Elo 6554L interactive display on the local network - display on / off, input, brightness, volume, and live status, all from the schematic.

## Features

- Display On / Display Off with live state feedback. "Off" is Elo's reversible **backlight off** state, so the display stays reachable over Ethernet
- Input selection (HDMI 1, HDMI 2, DisplayPort, USB-C) with live feedback
- Brightness (0-100) and volume (0-100)
- Internal temperature, display power hours and backlight hours
- Serial number on demand (technician action)
- Connection status kept separate from display state: "Online" with the backlight off is a healthy exhibit condition
- Configurable poll rate, with a temporary high-rate poll after a command until the status changes
- Raw hex box for sending a documented packet from the schematic and seeing the reply
- Automatic reconnect if the display or network drops

## How it works

```
Q-SYS Core  ---- TCP :5000 ---->  Display
            <--- MDC replies ---
```

The plugin opens one TCP connection to the display and speaks Elo's binary MDC protocol. Packets are raw bytes (never hex text) built with a checksum that is computed, not stored. Incoming TCP data is reassembled into frames using the packet length byte and each frame's checksum is validated, so partial frames and several frames in one read are handled.

All control handlers only queue a request; a single engine sends one request at a time, parses the reply, and updates the controls from what the display actually reports. Feedback is never optimistic.

A connection is only reported as Connected after the display answers a lightweight query (the backlight state) with a valid MDC frame.

## Requirements

Q-SYS Core side:

- Q-SYS Designer with plugin support
- Core must be able to reach the display on TCP port 5000 (same LAN or routed)

Display side (check these first if the plugin cannot talk to the display):

1. Firmware that supports MDC over TCP/IP (introduced with `IDS54_P0.63_SCALER_IOT_1.035.1.028`). Use the current approved firmware.
2. **Energy Saving Mode = Disabled.** Elo states it limits MDC command functionality.
3. **Brightness Sensor = Disabled** if Q-SYS controls brightness.
4. The display has a valid LAN address on the **IoT LAN** RJ45 connector. The second RJ45 is for the optional OSD remote and is not the network port.
5. TCP port 5000 is reachable from the Core.

No username or password is used; raw MDC over TCP has no authentication.

## Installation

### 1. Q-SYS Designer setup

1. Download `Elo6554LControl.qplug` from the latest release, or use the copy in `dist/`
2. Copy it to: `%USERPROFILE%\Documents\QSC\Q-Sys Designer\Plugins\QSYS Elo 6554L Control\`
3. Restart Q-SYS Designer (or use Manage Plugins to reload)
4. Drag Displays -> Elo -> Elo 6554L Control from the component library onto your schematic
5. Open the plugin's Properties panel and fill in:

| Property | Description |
|---|---|
| Name | Optional device name or ID (for example PRJ-201). Shown on the block in the schematic in place of the plugin title. |
| IP Address | The display's IP address |
| Port | Must match the display's MDC port (default 5000) |
| Normal Poll Interval (s) | How often display state and input are polled (default 3) |
| High Poll Interval (s) | Poll interval used right after a command, until the status changes (default 1) |
| High Poll Timeout (s) | Give up on the high-rate poll after this long (default 30) |
| Debug Print | None / Tx/Rx / All - use Tx/Rx when commissioning. Frames are printed as hex. |

## Controls and pins

All pins are available in the Control Pins section of the Properties panel.

| Control | Direction | Type | Description |
|---|---|---|---|
| DisplayOn / DisplayOff | Input | Button | Backlight on (`D6 00 01`) / backlight off (`D6 00 05`) |
| DisplayState | Output | LED | true when the backlight is on |
| DisplayText | Output | Text | On / Backlight Off / Unknown |
| Input | Both | Combo box | HDMI 1 / HDMI 2 / DisplayPort / USB-C |
| Brightness | Both | Knob | 0-100. Drags are coalesced; only the final value is sent. |
| Volume | Both | Knob | 0-100 (absolute volume). Drags are coalesced. |
| TemperatureC | Output | Text | Internal temperature in degrees C |
| DisplayPowerHours / BacklightHours | Output | Text | Accumulated hours |
| SerialNumber, ReadSerial | Output / Input | Text, Button | Reads the serial number on demand |
| Connected | Output | LED | true when the display is reachable and answering |
| Status | Output | Status | Connection state |
| StatusDetail | Output | Text | Details such as an unparsable reply (shown as hex) |
| Model, IPAddress | Output | Text | What this block is talking to |
| LastCommand, LastResponse, LastError, QueueDepth | Output | Text | Diagnostics (packets shown as hex) |
| CustomCommand, CustomSend, CustomReply | Both / Input / Output | Text, Button | Send one hex packet as typed and see the reply. It is never retried. |

## Polling

- Display state: every Normal Poll Interval, always.
- Backlight on: input at the Normal Poll Interval; brightness and volume every 5 s; temperature every 15 s; usage hours every 60 s.
- Backlight off: display state only.
- After a command the affected status is polled at the High Poll Interval until the display reports the expected value or the High Poll Timeout passes.
- The serial number is not polled. Elo requires 5 seconds of quiet after that query, which the plugin enforces before sending anything else.
- An unrecognized or malformed reply keeps the last good value; the raw frame is shown in StatusDetail. An unknown input code is shown as `Unknown (0xNN)`.

## Troubleshooting

| Problem | Fix |
|---|---|
| Status never reaches OK | Ping the display. Check IP Address and Port. Confirm the display firmware supports MDC over TCP/IP and Energy Saving Mode is disabled. |
| Status shows Communication error | The socket connected but the display did not answer a valid MDC frame. Use Debug Print = Tx/Rx and compare with the display. |
| Brightness changes then drifts back | Disable the display's Brightness Sensor. |
| Display Off does nothing | Confirm Energy Saving Mode is disabled. |
| LastError shows Unsupported Command (E01) | The display does not support that command in its current state or firmware. |
| LastError shows Device Error | The display reported an error code; see the hex in LastResponse. |

## Build from source

```powershell
npm install        # once; installs the Lua test VM (fengari)
npm run build      # writes dist/Elo6554LControl.qplug
npm test           # builds, then runs the Lua tests
```

## File reference

| File | Purpose |
|---|---|
| `src/info.lua` | `PluginInfo` (version injected from `package.json`) |
| `src/plugin.lua` | Design-time: properties, controls, layout, pages |
| `src/runtime.lua` | Runtime wiring between controls, engine and socket |
| `src/engine.lua` | Connection state machine, serialized queue, verification, timeouts, reconnect |
| `src/poller.lua` | Conservative polling schedule driven by backlight state |
| `src/protocol.lua` | Packet builder, checksum, receive framing, reply interpretation, error codes |
| `src/commands.lua` | Command definitions and return-data parsers |
| `src/models.lua` | 6554L metadata and input mapping |
| `build.js` | Bundles `src/` into one `.qplug` |
| `test/` | Lua tests, run under fengari (no Lua install needed) |

Q-SYS plugins are a single Lua file, so `build.js` wraps each module and provides a local `require`.

## Design rules

- One shared engine; model data lives in `src/models.lua`.
- Control handlers only enqueue. One request is in flight at a time; writes go ahead of queries.
- Feedback is parsed, never assumed. Last known good values are never overwritten on a parse failure.
- True power-off is never used as the normal Off state.
- Only commands from the supplied Elo references are used.

## Not yet verified on real hardware

Settle these in the lab; each is isolated so the fix is local.

1. **Input query reply** (`60` read): the reply layout is not documented. The plugin takes the last return-data byte as the input code.
2. **Serial number reply** (`E2` read): the reply layout is not documented. The plugin shows the printable characters, or hex if there are none.
3. **Write reply shape**: assumed to be `slave, error code, command` with `04` meaning no error, per the application note.
4. **Reply host/slave address bytes** are not validated.
5. **Brightness / volume replies**: assumed to be 2 bytes maximum then 2 bytes current; the current value is scaled to 0-100 against the reported maximum.
6. **Which queries the display answers while the backlight is off**: only the backlight state is polled in that state.
7. **Knob layout**: confirm the Brightness and Volume faders render and behave correctly in Designer.
8. **Socket reconnect**: the plugin sets `ReconnectTimeout = 0` and reconnects from the engine. Confirm that disables the socket's own reconnect.

## Not in version 1

- Relative volume, touch status, firmware update, alarm decoding and network configuration commands
- RS-232
