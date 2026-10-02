-- Runtime wiring: Q-SYS controls <-> engine/poller <-> TCP socket.
--
-- Called once from plugin.lua when `Controls` exists. All display traffic
-- goes through the engine queue; control handlers never write to the socket.
-- Controls show what the display reports, never what was merely requested.
-- Connection state (Connected / Status) is kept separate from the display
-- state (DisplayState / DisplayText): "Online" with the backlight off is a
-- healthy exhibit condition.
return function()
  local Models = require("models")
  local Protocol = require("protocol")
  local Commands = require("commands")
  local Engine = require("engine")
  local Poller = require("poller")

  local TICK = 0.1

  local model = Models.Get(Models.Default)
  local ip = Properties["IP Address"].Value
  local port = Properties["Port"].Value
  local debugMode = Properties["Debug Print"].Value
  local normalPoll = tonumber(Properties["Normal Poll Interval (s)"].Value) or 3
  local highPoll = tonumber(Properties["High Poll Interval (s)"].Value) or 1
  local highTimeout = tonumber(Properties["High Poll Timeout (s)"].Value) or 30

  local function dbg(kind, message)
    if debugMode == "All" or (debugMode == "Tx/Rx" and (kind == "tx" or kind == "rx")) then
      print(string.format("[Elo 6554L %s] %s", kind, tostring(message)))
    end
  end

  -- -------------------------------------------------------------------------
  -- Control helpers. Programmatic changes also fire EventHandlers, so
  -- feedback writes are wrapped to keep them from being sent back out.
  -- -------------------------------------------------------------------------
  local updating = false

  local function setText(control, value)
    if control.String ~= value then control.String = value end
  end

  local function setFlag(control, value)
    updating = true
    control.Boolean = value
    updating = false
  end

  local function setNumber(control, value)
    updating = true
    control.Value = value
    updating = false
  end

  local function setChoice(control, value)
    updating = true
    control.String = value
    updating = false
  end

  local function detail(message)
    setText(Controls.StatusDetail, message or "")
  end

  local function setError(key)
    setText(Controls.LastError, string.format("%s (%s)", Protocol.ErrorText(key), key))
  end

  -- A failed request: show a display-reported error in LastError, anything
  -- else (timeout, unparsable reply) in StatusDetail. The last good value is
  -- never replaced on failure.
  local function failed(label, reason, raw)
    if tostring(reason):match("^E%x%x$") then
      setError(reason)
      detail(label .. " failed: " .. Protocol.ErrorText(reason))
    elseif raw then
      detail(label .. " reply not understood: " .. tostring(raw))
    elseif reason ~= "superseded" then
      detail(label .. " failed: " .. tostring(reason))
    end
  end

  -- -------------------------------------------------------------------------
  -- Engine and socket
  -- -------------------------------------------------------------------------
  local sock = TcpSocket.New()
  sock.ReconnectTimeout = 0 -- reconnects are driven by the engine

  local poller -- assigned below; handlers refer to it
  local known = { brightness = 0, volume = 0 }
  -- Slider changes still waiting for a reply; poll results are ignored while
  -- any are outstanding so a drag does not snap back to an older value.
  local pending = { brightness = 0, volume = 0 }

  -- After a command, the affected key is polled at the high rate until the
  -- display reports the expected value or the high-rate timeout passes.
  local waiting = {}

  local function expect(key, test)
    waiting[key] = test
    poller:Boost(key, highTimeout)
    poller:PollNow(key)
  end

  local function settled(key, value)
    local test = waiting[key]
    if test and test(value) then
      waiting[key] = nil
      poller:EndBoost(key)
    end
  end

  local COMM_ERRORS = { ["no response"] = true, ["connect timeout"] = true, ["socket error"] = true }

  local function showDisplayUnknown()
    setFlag(Controls.DisplayState, false)
    setText(Controls.DisplayText, "Unknown")
  end

  local handlers = {}

  local function onState(state, why)
    if state == "Ready" then
      Controls.Connected.Boolean = true
      Controls.Status.Value = 0
      Controls.Status.String = "OK"
      detail("")
      Log.Message("Elo 6554L connected: " .. tostring(ip))
      return
    end

    Controls.Connected.Boolean = false
    if poller then poller:Reset() end
    showDisplayUnknown()

    if state == "Connecting" then
      Controls.Status.Value = 5
      Controls.Status.String = "Connecting..."
    elseif state == "Verifying" then
      Controls.Status.Value = 5
      Controls.Status.String = "Verifying..."
    elseif COMM_ERRORS[why] then
      Controls.Status.Value = 2
      Controls.Status.String = "Communication error"
      detail(tostring(why))
    else
      Controls.Status.Value = 4
      Controls.Status.String = "Disconnected"
      detail(why and tostring(why) or "")
    end
  end

  local engine = Engine.New({
    send = function(data) sock:Write(data) end,
    connect = function() sock:Connect(ip, port) end,
    disconnect = function() sock:Disconnect() end,
    log = function(kind, message)
      dbg(kind, message)
      if kind == "tx" then setText(Controls.LastCommand, message) end
      if kind == "rx" then setText(Controls.LastResponse, message) end
    end,
    onState = onState,
    -- The reply that proved the link also tells us the display state.
    onVerified = function(ok, value, raw)
      if ok then
        handlers.power(true, value, raw)
      elseif raw then
        failed("Display state", value, raw)
      end
    end,
  }, {
    Verify = Commands.Queries.power,
  })

  -- -------------------------------------------------------------------------
  -- Poll feedback
  -- -------------------------------------------------------------------------
  function handlers.power(ok, value, raw)
    if not ok then
      failed("Display state", value, raw)
      return
    end
    setFlag(Controls.DisplayState, value == "On")
    setText(Controls.DisplayText, value == "On" and "On" or "Backlight Off")
    poller:SetPower(value)
    settled("power", value)
  end

  function handlers.input(ok, value, raw)
    if not ok then
      failed("Input", value, raw)
      return
    end
    local label = Commands.LabelForCode(model.Inputs, value)
    if label then
      setChoice(Controls.Input, label)
    else
      local unknown = string.format("Unknown (0x%02X)", value)
      setChoice(Controls.Input, unknown)
      detail("Unrecognized input reply: " .. unknown)
    end
    settled("input", label or value)
  end

  local function levelHandler(key, controlName, label)
    return function(ok, value, raw)
      if not ok then
        failed(label, value, raw)
        return
      end
      known[key] = value
      if pending[key] > 0 then return end
      setNumber(Controls[controlName], value)
      settled(key, value)
    end
  end

  handlers.brightness = levelHandler("brightness", "Brightness", "Brightness")
  handlers.volume = levelHandler("volume", "Volume", "Volume")

  function handlers.temperature(ok, value, raw)
    if not ok then
      failed("Temperature", value, raw)
      return
    end
    setText(Controls.TemperatureC, tostring(value))
  end

  function handlers.lifetime(ok, value, raw)
    if not ok then
      failed("Usage hours", value, raw)
      return
    end
    setText(Controls.DisplayPowerHours, tostring(value.display))
    setText(Controls.BacklightHours, tostring(value.backlight))
  end

  function handlers.serial(ok, value, raw)
    if not ok then
      failed("Serial number", value, raw)
      return
    end
    setText(Controls.SerialNumber, value)
    detail("")
  end

  poller = Poller.New(engine, handlers, {
    NormalInterval = normalPoll,
    HighRateInterval = highPoll,
  })

  -- -------------------------------------------------------------------------
  -- Socket events
  -- -------------------------------------------------------------------------
  sock.EventHandler = function(_, event, err)
    if event == TcpSocket.Events.Connected then
      engine:OnConnected()
    elseif event == TcpSocket.Events.Data then
      -- TCP is a stream: hand over whatever arrived; the engine reassembles
      -- frames from the length byte.
      local available = sock.BufferLength
      while available and available > 0 do
        local data = sock:Read(available)
        if not data then break end
        engine:OnData(data)
        available = sock.BufferLength
      end
    elseif event == TcpSocket.Events.Closed then
      engine:OnClosed("closed")
    elseif event == TcpSocket.Events.Error or event == TcpSocket.Events.Timeout then
      engine:OnClosed("socket error")
    end
  end

  -- -------------------------------------------------------------------------
  -- Control handlers (enqueue only)
  -- -------------------------------------------------------------------------
  -- Coalescing commands (slider drags) use their name as the queue key.
  local function send(name, spec, after)
    engine:Command(spec.coalesce and name or nil, spec, function(ok, reason, raw)
      if not ok then failed(name, reason, nil) end
      if after then after(ok, reason) end
    end)
  end

  Controls.DisplayOn.EventHandler = function()
    send("Display on", Commands.DisplayOn, function(ok)
      if ok then expect("power", function(v) return v == "On" end) end
    end)
  end
  Controls.DisplayOff.EventHandler = function()
    send("Display off", Commands.DisplayOff, function(ok)
      if ok then expect("power", function(v) return v == "Off" end) end
    end)
  end

  Controls.Input.Choices = Commands.Labels(model.Inputs)
  Controls.Input.EventHandler = function(control)
    if updating then return end
    local wanted = control.String
    local code = Commands.CodeForLabel(model.Inputs, wanted)
    if not code then
      detail("Unknown input: " .. tostring(wanted))
      return
    end
    send("Input", Commands.Input(code), function(ok)
      if ok then expect("input", function(v) return v == wanted end) end
    end)
  end

  local function bindLevel(controlName, key, build, label)
    Controls[controlName].EventHandler = function(control)
      if updating then return end
      local wanted = math.floor((tonumber(control.Value) or 0) + 0.5)
      pending[key] = pending[key] + 1
      send(label, build(wanted), function(ok, reason)
        pending[key] = pending[key] - 1
        if reason == "superseded" then return end
        if ok then
          expect(key, function(v) return v == wanted end)
        elseif pending[key] == 0 then
          setNumber(Controls[controlName], known[key])
        end
      end)
    end
  end

  bindLevel("Brightness", "brightness", Commands.Brightness, "Brightness")
  bindLevel("Volume", "volume", Commands.Volume, "Volume")

  -- Technician action: Elo requires a 5 second pause after this query, which
  -- the engine enforces, so it is not part of the regular poll.
  Controls.ReadSerial.EventHandler = function()
    detail("Reading serial number; the display needs 5 s before the next command")
    engine:Query("serial", Commands.Queries.serial, handlers.serial)
  end

  Controls.CustomCommand.String = Protocol.ToHex(Commands.Queries.temperature.packet)
  Controls.CustomReply.String = "Ready"
  Controls.CustomSend.EventHandler = function()
    local packet, why = Protocol.ParseHex(Controls.CustomCommand.String)
    if not packet then
      setText(Controls.CustomReply, "Invalid hex: " .. tostring(why))
      return
    end
    -- Sent exactly as typed, never retried.
    engine:Raw("custom", packet, function(ok, value, raw)
      if ok then
        setText(Controls.CustomReply, raw or "OK")
      else
        setText(Controls.CustomReply, tostring(value or "Failed"))
      end
    end)
  end

  -- -------------------------------------------------------------------------
  -- Static info and start-up
  -- -------------------------------------------------------------------------
  Controls.Model.String = model.Name
  Controls.IPAddress.String = tostring(ip) .. ":" .. tostring(port)
  Controls.Connected.Boolean = false
  Controls.QueueDepth.String = "0"
  showDisplayUnknown()

  local clock = 0
  local lastDepth = 0
  local ticker = Timer.New()
  ticker.EventHandler = function()
    clock = clock + TICK
    engine:Tick(clock)
    poller:Tick(clock)
    local depth = engine:QueueDepth()
    if depth ~= lastDepth then
      lastDepth = depth
      setText(Controls.QueueDepth, tostring(depth))
    end
  end

  if ip == nil or ip == "" or ip == "0.0.0.0" then
    Controls.Status.Value = 2
    Controls.Status.String = "Set the IP Address property"
    return
  end

  Controls.Status.Value = 4
  Controls.Status.String = "Disconnected"
  engine:Start(clock)
  ticker:Start(TICK)
end
