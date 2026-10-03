local T = require("helpers")
local Protocol = require("protocol")
local F = require("frames")

local BUNDLE_PATH = "dist/Elo6554LControl.qplug"

local function loadBundle()
  local source = __read(BUNDLE_PATH)
  T.truthy(source, "bundle not built")
  local fn, err = load(source, "@bundle")
  if not fn then error(err, 0) end
  fn()
end

-- ---------------------------------------------------------------------------
-- Design time (Controls is nil)
-- ---------------------------------------------------------------------------
loadBundle()

local function propsFromDefaults(overrides)
  local props = {}
  for _, p in ipairs(GetProperties()) do props[p.Name] = { Value = p.Value } end
  for name, value in pairs(overrides or {}) do props[name].Value = value end
  return props
end

T.test("PluginInfo is complete", function()
  T.eq(PluginInfo.Name, "Hybridsix Software~Displays~Elo~Elo 6554L Control")
  T.truthy(PluginInfo.Id:match("^%x+%-%x+%-%x+%-%x+%-%x+$"))
  T.truthy(PluginInfo.Version:match("^%d+%.%d+%.%d+$"), "version placeholder not replaced")
end)
T.test("the Name property replaces the block title when set", function()
  local props = propsFromDefaults()
  T.truthy(GetPrettyName(props):find("Control", 1, true))
  props["Name"].Value = "PRJ 201"
  local label = GetPrettyName(props)
  T.truthy(label:find("PRJ\xC2\xA0201", 1, true))
  T.falsy(label:find("Control", 1, true))
  props["Name"].Value = "  "
  T.truthy(GetPrettyName(props):find("Control", 1, true))
end)

T.test("property names are unique and defaults are valid", function()
  local seen = {}
  for _, p in ipairs(GetProperties()) do
    T.falsy(seen[p.Name], "duplicate property " .. p.Name)
    seen[p.Name] = true
    if p.Type == "enum" then
      local found = false
      for _, c in ipairs(p.Choices) do if c == p.Value then found = true end end
      T.truthy(found, p.Name .. " default is not a choice")
    end
  end
  for _, name in ipairs({ "IP Address", "Port", "Normal Poll Interval (s)", "High Poll Interval (s)",
    "High Poll Timeout (s)", "Debug Print" }) do
    T.truthy(seen[name], "missing property " .. name)
  end
  T.falsy(seen["Username"], "Elo MDC over TCP has no authentication")
  T.falsy(seen["Password"], "Elo MDC over TCP has no authentication")
end)

T.test("the port defaults to 5000", function()
  for _, p in ipairs(GetProperties()) do
    if p.Name == "Port" then T.eq(p.Value, 5000) end
  end
end)

T.test("every laid-out control is defined, with no duplicates", function()
  local props = propsFromDefaults()
  local defined = {}
  for _, c in ipairs(GetControls(props)) do
    T.falsy(defined[c.Name], "duplicate control " .. c.Name)
    defined[c.Name] = true
  end
  local layout, graphics = GetControlLayout(props)
  for name in pairs(layout) do
    T.truthy(defined[name], "layout has undefined control " .. name)
  end
  for name in pairs(defined) do
    T.truthy(layout[name], "control missing from layout: " .. name)
  end
  T.truthy(#graphics > 0)
  T.eq(#GetPages(props), 1)
  T.truthy(GetPrettyName(props):find("Elo\xC2\xA06554L", 1, true))
end)

T.test("the version 1 controls exist", function()
  local defined = {}
  for _, c in ipairs(GetControls(propsFromDefaults())) do defined[c.Name] = true end
  for _, name in ipairs({ "Connected", "Status", "StatusDetail", "DisplayOn", "DisplayOff", "DisplayState",
    "Input", "Brightness", "Volume", "TemperatureC", "DisplayPowerHours", "BacklightHours", "LastError" }) do
    T.truthy(defined[name], "missing control " .. name)
  end
end)

T.test("level controls carry the documented range", function()
  local byName = {}
  for _, c in ipairs(GetControls(propsFromDefaults())) do byName[c.Name] = c end
  T.eq(byName.Brightness.Min, 0)
  T.eq(byName.Brightness.Max, 100)
  T.eq(byName.Volume.Min, 0)
  T.eq(byName.Volume.Max, 100)
end)

-- ---------------------------------------------------------------------------
-- Runtime, against a mocked Q-SYS environment
-- ---------------------------------------------------------------------------
local mocks = {}

local function installMocks(overrides)
  mocks.printed, mocks.timers, mocks.logs, mocks.socket = {}, {}, {}, nil

  Properties = propsFromDefaults(overrides)

  Controls = setmetatable({}, {
    __index = function(t, name)
      -- Like Q-SYS, assigning a new Boolean/String/Value fires EventHandler,
      -- including when the plugin itself does the assigning.
      local raw = { Name = name, Boolean = false, String = "", Value = 0, Choices = {} }
      local control = setmetatable({}, {
        __index = raw,
        __newindex = function(self, key, value)
          local old = raw[key]
          raw[key] = value
          local watched = key == "Boolean" or key == "String" or key == "Value"
          if watched and old ~= value and raw.EventHandler then raw.EventHandler(self) end
        end,
      })
      rawset(t, name, control)
      return control
    end,
  })

  TcpSocket = {
    Events = { Connected = "Connected", Reconnect = "Reconnect", Data = "Data", Closed = "Closed", Error = "Error", Timeout = "Timeout" },
    New = function()
      local s = { written = {}, rx = "", connectCalls = 0, disconnectCalls = 0 }
      function s:Connect(ip, port) self.connectCalls = self.connectCalls + 1; self.ip, self.port = ip, port end
      function s:Disconnect() self.disconnectCalls = self.disconnectCalls + 1 end
      function s:Write(data) self.written[#self.written + 1] = data end
      function s:Read(n)
        if #self.rx == 0 then return nil end
        local chunk = self.rx:sub(1, n)
        self.rx = self.rx:sub(n + 1)
        return chunk
      end
      setmetatable(s, { __index = function(t, k) if k == "BufferLength" then return #rawget(t, "rx") end end })
      mocks.socket = s
      return s
    end,
  }

  Timer = {
    New = function()
      local t = { running = false }
      function t:Start(interval) self.running, self.interval = true, interval end
      function t:Stop() self.running = false end
      mocks.timers[#mocks.timers + 1] = t
      return t
    end,
  }

  Log = {
    Message = function(m) mocks.logs[#mocks.logs + 1] = m end,
    Error = function(m) mocks.logs[#mocks.logs + 1] = "ERROR " .. m end,
  }

  mocks.realPrint = mocks.realPrint or print
  print = function(...) mocks.printed[#mocks.printed + 1] = table.concat({ ... }, " ") end

  loadBundle()
end

local function removeMocks()
  Controls, Properties, TcpSocket, Timer, Log = nil, nil, nil, nil, nil
  print = mocks.realPrint
end

local function mainTimer()
  for _, t in ipairs(mocks.timers) do
    if t.interval == 0.1 then return t end
  end
end

local function tick(n)
  for _ = 1, n or 1 do mainTimer().EventHandler() end
end

-- Delivers bytes to the plugin the way the socket does: into the receive
-- buffer, then a Data event.
local function feed(bytes)
  local sock = mocks.socket
  sock.rx = sock.rx .. bytes
  sock.EventHandler(sock, TcpSocket.Events.Data)
end

local function lastWritten()
  local w = mocks.socket.written
  return w[#w]
end

local function lastWrittenHex()
  return Protocol.ToHex(lastWritten())
end

local function wasSent(hex)
  for _, packet in ipairs(mocks.socket.written) do
    if Protocol.ToHex(packet) == hex then return true end
  end
  return false
end

local POWER_ON = F.read(0xD6, 0x00, 0x01)
local POWER_OFF = F.read(0xD6, 0x00, 0x05)

-- Connects and answers the verification query with the given power reply.
local function connect(powerReply)
  tick(1)
  local sock = mocks.socket
  T.eq(sock.connectCalls, 1)
  sock.EventHandler(sock, TcpSocket.Events.Connected)
  T.eq(Protocol.ToHex(sock.written[1]), "02 6E 83 FF 01 D6 C7 03")
  feed(powerReply or POWER_ON)
  mocks.answered = #sock.written
end

-- A simulated display: answers every request the plugin sends.
local ANSWERS = {
  [0xD6] = F.read(0xD6, 0x00, 0x01),
  [0x60] = F.read(0x60, 0x10),
  [0x10] = F.read(0x10, 0x00, 0x64, 0x00, 0x28),
  [0x62] = F.read(0x62, 0x00, 0x64, 0x00, 0x46),
  [0xB1] = F.read(0xB1, 0x00, 0xFF, 0x00, 0x2A),
  [0xC0] = F.read(0xC0, 0x00, 0x0A, 0x00, 0x05),
  [0xE2] = F.read(0xE2, 0x45, 0x4C, 0x4F, 0x31, 0x32, 0x33),
}

local function pump(ticks, answers)
  answers = answers or ANSWERS
  for _ = 1, ticks do
    tick(1)
    while mocks.answered < #mocks.socket.written do
      mocks.answered = mocks.answered + 1
      local packet = mocks.socket.written[mocks.answered]
      local rw, command = packet:byte(5), packet:byte(6)
      if rw == Protocol.WRITE then
        feed(F.ack(command))
      elseif answers[command] then
        feed(answers[command])
      end
    end
  end
end

T.test("connects to the configured address on port 5000", function()
  installMocks({ ["IP Address"] = "10.1.2.3" })
  tick(1)
  T.eq(mocks.socket.ip, "10.1.2.3")
  T.eq(mocks.socket.port, 5000)
  T.eq(Controls.Status.String, "Connecting...")
  removeMocks()
end)

T.test("the connection is only reported after a valid reply to the verification query", function()
  installMocks()
  tick(1)
  mocks.socket.EventHandler(mocks.socket, TcpSocket.Events.Connected)
  T.falsy(Controls.Connected.Boolean)
  T.eq(Controls.Status.String, "Verifying...")
  feed(POWER_ON)
  T.truthy(Controls.Connected.Boolean)
  T.eq(Controls.Status.String, "OK")
  T.eq(Controls.Status.Value, 0)
  removeMocks()
end)

T.test("connection state is separate from display state", function()
  installMocks()
  connect(POWER_OFF)
  T.truthy(Controls.Connected.Boolean)
  T.eq(Controls.Status.String, "OK")
  T.falsy(Controls.DisplayState.Boolean)
  T.eq(Controls.DisplayText.String, "Backlight Off")
  removeMocks()
end)

T.test("the backlight-on reply sets the display state", function()
  installMocks()
  connect(POWER_ON)
  T.truthy(Controls.DisplayState.Boolean)
  T.eq(Controls.DisplayText.String, "On")
  removeMocks()
end)

T.test("polling feeds back input, brightness, volume, temperature and hours", function()
  installMocks()
  connect()
  pump(700)
  T.eq(Controls.Input.String, "HDMI 2")
  T.eq(Controls.Brightness.Value, 40)
  T.eq(Controls.Volume.Value, 70)
  T.eq(Controls.TemperatureC.String, "42")
  T.eq(Controls.DisplayPowerHours.String, "10")
  T.eq(Controls.BacklightHours.String, "5")
  removeMocks()
end)

T.test("Display Off sends the reversible backlight-off packet", function()
  installMocks()
  connect()
  Controls.DisplayOff.EventHandler()
  T.eq(lastWrittenHex(), "02 6E 85 FF 04 D6 00 05 D1 03")
  removeMocks()
end)

T.test("Display On sends the backlight-on packet", function()
  installMocks()
  connect(POWER_OFF)
  Controls.DisplayOn.EventHandler()
  T.eq(lastWrittenHex(), "02 6E 85 FF 04 D6 00 01 CD 03")
  removeMocks()
end)

T.test("the display state follows the reply, not the request", function()
  installMocks()
  connect()
  Controls.DisplayOff.EventHandler()
  -- Sending the command alone does not change the state; the reply does.
  T.truthy(Controls.DisplayState.Boolean)
  local answers = {}
  for k, v in pairs(ANSWERS) do answers[k] = v end
  answers[0xD6] = POWER_OFF
  pump(10, answers)
  T.falsy(Controls.DisplayState.Boolean)
  T.eq(Controls.DisplayText.String, "Backlight Off")
  removeMocks()
end)

T.test("selecting an input sends its code", function()
  installMocks()
  connect()
  local expected = {
    ["HDMI 1"] = "02 6E 84 FF 04 60 20 75 03",
    ["HDMI 2"] = "02 6E 84 FF 04 60 10 65 03",
    ["DisplayPort"] = "02 6E 84 FF 04 60 40 95 03",
    ["USB-C"] = "02 6E 84 FF 04 60 08 5D 03",
  }
  local codes = { ["HDMI 1"] = 0x20, ["HDMI 2"] = 0x10, ["DisplayPort"] = 0x40, ["USB-C"] = 0x08 }
  for label, bytes in pairs(expected) do
    Controls.Input.String = label
    -- The simulated display reports the selected input once it has switched.
    local answers = {}
    for k, v in pairs(ANSWERS) do answers[k] = v end
    answers[0x60] = F.read(0x60, codes[label])
    pump(5, answers)
    T.truthy(wasSent(bytes), label .. " packet not sent")
  end
  T.eq(table.concat(Controls.Input.Choices, ","), "HDMI 1,HDMI 2,DisplayPort,USB-C")
  removeMocks()
end)

T.test("an unknown input code is shown, not hidden", function()
  installMocks()
  connect()
  local answers = {}
  for k, v in pairs(ANSWERS) do answers[k] = v end
  answers[0x60] = F.read(0x60, 0x77)
  pump(30, answers)
  T.eq(Controls.Input.String, "Unknown (0x77)")
  removeMocks()
end)

T.test("brightness and volume send absolute values", function()
  installMocks()
  connect()
  Controls.Brightness.Value = 80
  T.eq(lastWrittenHex(), "02 6E 85 FF 04 10 00 50 56 03")
  pump(5)
  Controls.Volume.Value = 90
  pump(5)
  T.truthy(wasSent("02 6E 85 FF 04 62 00 5A B2 03"), "volume packet not sent")
  removeMocks()
end)

T.test("a failed brightness write puts the control back to the last known value", function()
  installMocks()
  connect()
  pump(80)
  T.eq(Controls.Brightness.Value, 40)
  Controls.Brightness.Value = 90
  feed(F.ack(0x10, 0x01))
  T.eq(Controls.Brightness.Value, 40)
  T.truthy(Controls.LastError.String:find("Unsupported Command", 1, true))
  removeMocks()
end)

T.test("an unparsable reply keeps the last good value", function()
  installMocks()
  connect()
  pump(80)
  T.eq(Controls.TemperatureC.String, "42")
  local answers = {}
  for k, v in pairs(ANSWERS) do answers[k] = v end
  answers[0xB1] = F.read(0xB1, 0x00)
  pump(200, answers)
  T.eq(Controls.TemperatureC.String, "42")
  T.truthy(Controls.StatusDetail.String:find("B1 00", 1, true), "raw frame should be shown in the detail")
  removeMocks()
end)

T.test("Read Serial queries E2 and shows the reply", function()
  installMocks()
  connect()
  Controls.ReadSerial.EventHandler()
  T.eq(lastWrittenHex(), "02 6E 83 FF 01 E2 D3 03")
  feed(ANSWERS[0xE2])
  T.eq(Controls.SerialNumber.String, "ELO123")
  removeMocks()
end)

T.test("the raw hex box sends the bytes as typed", function()
  installMocks()
  connect()
  Controls.CustomCommand.String = "02 6E 83 FF 01 B1 A2 03"
  Controls.CustomSend.EventHandler()
  T.eq(lastWrittenHex(), "02 6E 83 FF 01 B1 A2 03")
  T.eq(#lastWritten(), 8)
  feed(ANSWERS[0xB1])
  T.truthy(Controls.CustomReply.String:find("B1 00 FF 00 2A", 1, true))
  removeMocks()
end)

T.test("the raw hex box rejects bad input without sending", function()
  installMocks()
  connect()
  local before = #mocks.socket.written
  Controls.CustomCommand.String = "not hex"
  Controls.CustomSend.EventHandler()
  T.eq(#mocks.socket.written, before)
  T.truthy(Controls.CustomReply.String:find("Invalid hex", 1, true))
  removeMocks()
end)

T.test("a closed socket marks the display disconnected and unknown", function()
  installMocks()
  connect()
  mocks.socket.EventHandler(mocks.socket, TcpSocket.Events.Closed)
  T.falsy(Controls.Connected.Boolean)
  T.eq(Controls.Status.String, "Disconnected")
  T.eq(Controls.DisplayText.String, "Unknown")
  removeMocks()
end)

T.test("a display that never answers shows a communication error", function()
  installMocks()
  tick(1)
  mocks.socket.EventHandler(mocks.socket, TcpSocket.Events.Connected)
  tick(30)
  T.falsy(Controls.Connected.Boolean)
  T.eq(Controls.Status.String, "Communication error")
  removeMocks()
end)

T.test("an empty IP address does not start the connection", function()
  installMocks({ ["IP Address"] = "" })
  T.eq(Controls.Status.String, "Set the IP Address property")
  T.falsy(mainTimer() and mainTimer().running)
  removeMocks()
end)

T.test("Tx/Rx debug prints hex and nothing else", function()
  installMocks({ ["Debug Print"] = "Tx/Rx" })
  connect()
  local text = table.concat(mocks.printed, "\n")
  T.truthy(text:find("tx] 02 6E 83 FF 01 D6 C7 03", 1, true))
  T.truthy(text:find("rx]", 1, true))
  removeMocks()
end)

return T.finish()

