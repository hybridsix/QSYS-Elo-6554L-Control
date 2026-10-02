local T = require("helpers")
local Engine = require("engine")
local Protocol = require("protocol")
local Commands = require("commands")
local F = require("frames")

local POWER_ON = F.read(0xD6, 0x00, 0x01)

-- Builds an engine with recording dependencies.
local function setup(options)
  local ctx = { sent = {}, connects = 0, disconnects = 0, states = {}, logs = {}, verified = {} }
  local opts = { Verify = Commands.Queries.power }
  for k, v in pairs(options or {}) do opts[k] = v end
  ctx.engine = Engine.New({
    send = function(data) ctx.sent[#ctx.sent + 1] = data end,
    connect = function() ctx.connects = ctx.connects + 1 end,
    disconnect = function() ctx.disconnects = ctx.disconnects + 1 end,
    log = function(kind, message) ctx.logs[#ctx.logs + 1] = kind .. ":" .. tostring(message) end,
    onState = function(state, detail) ctx.states[#ctx.states + 1] = state .. (detail and (":" .. detail) or "") end,
    onVerified = function(ok, value, raw) ctx.verified[#ctx.verified + 1] = { ok, value, raw } end,
  }, opts)
  return ctx
end

-- Drives the engine to Ready at time 0; the display answers the verification
-- query with "backlight on".
local function ready(options)
  local ctx = setup(options)
  ctx.engine:Start(0)
  ctx.engine:Tick(0)
  ctx.engine:OnConnected()
  ctx.engine:OnData(POWER_ON)
  return ctx
end

local function sentHex(ctx, i) return Protocol.ToHex(ctx.sent[i]) end

T.test("connect, verify, ready", function()
  local ctx = setup()
  ctx.engine:Start(0)
  T.eq(ctx.engine.state, "Disconnected")
  ctx.engine:Tick(0)
  T.eq(ctx.connects, 1)
  T.eq(ctx.engine.state, "Connecting")
  ctx.engine:OnConnected()
  T.eq(ctx.engine.state, "Verifying")
  T.eq(sentHex(ctx, 1), "02 6E 83 FF 01 D6 C7 03")
  ctx.engine:OnData(POWER_ON)
  T.eq(ctx.engine.state, "Ready")
  T.eq(#ctx.verified, 1)
  T.truthy(ctx.verified[1][1])
  T.eq(ctx.verified[1][2], "On")
end)

T.test("the connection is not trusted until a valid frame arrives", function()
  local ctx = setup()
  ctx.engine:Start(0)
  ctx.engine:Tick(0)
  ctx.engine:OnConnected()
  ctx.engine:OnData("hello there")
  T.eq(ctx.engine.state, "Verifying")
  local bad = POWER_ON:sub(1, #POWER_ON - 2) .. "\x00\x03"
  ctx.engine:OnData(bad)
  T.eq(ctx.engine.state, "Verifying")
  ctx.engine:OnData(POWER_ON)
  T.eq(ctx.engine.state, "Ready")
end)

T.test("a display that never answers is dropped and retried", function()
  local ctx = setup()
  ctx.engine:Start(0)
  ctx.engine:Tick(0)
  ctx.engine:OnConnected()
  ctx.engine:Tick(1.9)
  T.eq(ctx.engine.state, "Verifying")
  ctx.engine:Tick(2.0)
  T.eq(ctx.engine.state, "Disconnected")
  T.eq(ctx.disconnects, 1)
  T.eq(ctx.states[#ctx.states], "Disconnected:no response")
  ctx.engine:Tick(6.9)
  T.eq(ctx.connects, 1)
  ctx.engine:Tick(7.0)
  T.eq(ctx.connects, 2)
end)

T.test("a verification reply that cannot be parsed still proves the link", function()
  local ctx = setup()
  ctx.engine:Start(0)
  ctx.engine:Tick(0)
  ctx.engine:OnConnected()
  ctx.engine:OnData(F.read(0xD6, 0x00, 0x02))
  T.eq(ctx.engine.state, "Ready")
  T.falsy(ctx.verified[1][1])
  T.eq(ctx.verified[1][2], "unexpected reply")
  T.truthy(ctx.verified[1][3]:find("D6 00 02", 1, true))
end)

T.test("a connect that never completes times out", function()
  local ctx = setup()
  ctx.engine:Start(0)
  ctx.engine:Tick(0)
  ctx.engine:Tick(9.9)
  T.eq(ctx.engine.state, "Connecting")
  ctx.engine:Tick(10.0)
  T.eq(ctx.engine.state, "Disconnected")
  T.eq(ctx.states[#ctx.states], "Disconnected:connect timeout")
end)

T.test("requests are rejected when not Ready", function()
  local ctx = setup()
  local result
  local queued = ctx.engine:Query("power", Commands.Queries.power, function(ok, reason) result = { ok, reason } end)
  T.falsy(queued)
  T.eq(result[1], false)
  T.eq(result[2], "not connected")
  T.eq(#ctx.sent, 0)
end)

T.test("a query resolves with the parsed value", function()
  local ctx = ready()
  local got
  ctx.engine:Query("temp", Commands.Queries.temperature, function(ok, value, raw) got = { ok, value, raw } end)
  T.eq(sentHex(ctx, 2), "02 6E 83 FF 01 B1 A2 03")
  ctx.engine:OnData(F.read(0xB1, 0x00, 0xFF, 0x00, 0x32))
  T.truthy(got[1])
  T.eq(got[2], 50)
  T.truthy(got[3]:find("B1 00 FF 00 32", 1, true))
end)

T.test("a reply split across socket reads is reassembled", function()
  local ctx = ready()
  local got
  ctx.engine:Query("temp", Commands.Queries.temperature, function(ok, value) got = { ok, value } end)
  local frame = F.read(0xB1, 0x00, 0xFF, 0x00, 0x32)
  ctx.engine:OnData(frame:sub(1, 4))
  T.eq(got, nil)
  ctx.engine:OnData(frame:sub(5, 9))
  T.eq(got, nil)
  ctx.engine:OnData(frame:sub(10))
  T.eq(got[2], 50)
end)

T.test("two replies in one read resolve both requests in order", function()
  local ctx = ready()
  local results = {}
  ctx.engine:Query("power", Commands.Queries.power, function(ok, value) results[#results + 1] = "power=" .. tostring(value) end)
  ctx.engine:Query("temp", Commands.Queries.temperature, function(ok, value) results[#results + 1] = "temp=" .. tostring(value) end)
  -- The first reply frees the wire, the next request is sent, and the second
  -- frame in the same read answers it.
  ctx.engine:OnData(F.read(0xD6, 0x00, 0x05) .. F.read(0xB1, 0x00, 0xFF, 0x00, 0x20))
  T.eq(results[1], "power=Off")
  T.eq(results[2], "temp=32")
end)

T.test("a write acknowledgement resolves ok", function()
  local ctx = ready()
  local got
  ctx.engine:Command(nil, Commands.DisplayOff, function(ok, value) got = { ok, value } end)
  T.eq(sentHex(ctx, 2), "02 6E 85 FF 04 D6 00 05 D1 03")
  ctx.engine:OnData(F.ack(0xD6))
  T.truthy(got[1])
end)

T.test("an unsupported-command reply is reported as E01", function()
  local ctx = ready()
  local got
  ctx.engine:Command(nil, Commands.DisplayOff, function(ok, value, raw) got = { ok, value, raw } end)
  ctx.engine:OnData(F.ack(0xD6, 0x01))
  T.falsy(got[1])
  T.eq(got[2], "E01")
  T.truthy(got[3]:find("01 D6", 1, true))
  T.eq(ctx.engine.state, "Ready", "an error reply is not a communication failure")
end)

T.test("a reply that cannot be parsed fails with the raw frame", function()
  local ctx = ready()
  local got
  ctx.engine:Query("temp", Commands.Queries.temperature, function(ok, value, raw) got = { ok, value, raw } end)
  ctx.engine:OnData(F.read(0xB1, 0x00, 0xFF))
  T.falsy(got[1])
  T.eq(got[2], "unexpected reply")
  T.truthy(got[3])
end)

T.test("a frame for another command is ignored and the request keeps waiting", function()
  local ctx = ready()
  local got
  ctx.engine:Query("temp", Commands.Queries.temperature, function(ok, value) got = { ok, value } end)
  ctx.engine:OnData(F.read(0x62, 0x00, 0x64, 0x00, 0x32))
  T.eq(got, nil)
  ctx.engine:OnData(F.read(0xB1, 0x00, 0xFF, 0x00, 0x32))
  T.eq(got[2], 50)
end)

T.test("only one request is in flight at a time", function()
  local ctx = ready()
  ctx.engine:Query("power", Commands.Queries.power)
  ctx.engine:Query("input", Commands.Queries.input)
  ctx.engine:Query("temp", Commands.Queries.temperature)
  T.eq(#ctx.sent, 2)
  ctx.engine:OnData(POWER_ON)
  T.eq(#ctx.sent, 3)
  T.eq(sentHex(ctx, 3), "02 6E 83 FF 01 60 51 03")
end)

T.test("writes go ahead of queued reads", function()
  local ctx = ready()
  ctx.engine:Query("power", Commands.Queries.power)
  ctx.engine:Query("input", Commands.Queries.input)
  ctx.engine:Query("temp", Commands.Queries.temperature)
  ctx.engine:Command(nil, Commands.DisplayOn)
  ctx.engine:OnData(POWER_ON) -- answers the power query in flight
  T.eq(sentHex(ctx, 3), "02 6E 85 FF 04 D6 00 01 CD 03")
end)

T.test("a keyed read is not queued twice", function()
  local ctx = ready()
  ctx.engine:Query("power", Commands.Queries.power)
  T.falsy(ctx.engine:Query("power", Commands.Queries.power))
  T.eq(ctx.engine:QueueDepth(), 1)
end)

T.test("a newer slider value replaces one still waiting in the queue", function()
  local ctx = ready()
  local results = {}
  ctx.engine:Query("power", Commands.Queries.power) -- occupies the wire
  ctx.engine:Command("Volume", Commands.Volume(10), function(ok, why) results[#results + 1] = "10:" .. tostring(why) end)
  ctx.engine:Command("Volume", Commands.Volume(20), function(ok, why) results[#results + 1] = "20:" .. tostring(ok) end)
  T.eq(results[1], "10:superseded")
  ctx.engine:OnData(POWER_ON)
  T.eq(sentHex(ctx, 3), Protocol.ToHex(Commands.Volume(20).packet))
  ctx.engine:OnData(F.ack(0x62))
  T.eq(results[2], "20:true")
  T.eq(#ctx.sent, 3, "the superseded value was never sent")
end)

T.test("an idempotent write is retried once after a timeout, then fails", function()
  local ctx = ready()
  local got
  ctx.engine:Command(nil, Commands.DisplayOn, function(ok, value) got = { ok, value } end)
  T.eq(#ctx.sent, 2)
  ctx.engine:Tick(1.9)
  T.eq(#ctx.sent, 2)
  ctx.engine:Tick(2.0)
  T.eq(#ctx.sent, 3, "retried")
  T.eq(got, nil)
  ctx.engine:Tick(4.0)
  T.falsy(got[1])
  T.eq(got[2], "timeout")
  T.eq(ctx.engine.state, "Ready")
end)

T.test("repeated timeouts drop the connection and reconnect", function()
  local ctx = ready()
  for i = 1, 3 do ctx.engine:Query("q" .. i, Commands.Queries.temperature) end
  ctx.engine:Tick(2.0) -- 1st timeout, retried
  ctx.engine:Tick(4.0) -- 2nd timeout, request fails
  ctx.engine:Tick(6.0) -- 3rd timeout: link considered dead
  T.eq(ctx.engine.state, "Disconnected")
  T.eq(ctx.disconnects, 1)
  T.eq(ctx.states[#ctx.states], "Disconnected:no response")
end)

T.test("the serial-number query holds the queue for 5 seconds", function()
  local ctx = ready()
  ctx.engine:Query("serial", Commands.Queries.serial)
  ctx.engine:Query("power", Commands.Queries.power)
  T.eq(#ctx.sent, 2)
  ctx.engine:OnData(F.read(0xE2, 0x41, 0x42))
  T.eq(#ctx.sent, 2, "next command must wait")
  ctx.engine:Tick(4.9)
  T.eq(#ctx.sent, 2)
  ctx.engine:Tick(5.0)
  T.eq(#ctx.sent, 3)
  T.eq(sentHex(ctx, 3), "02 6E 83 FF 01 D6 C7 03")
end)

T.test("a raw packet is sent as given and resolves with the reply in hex", function()
  local ctx = ready()
  local got
  local packet = Protocol.ParseHex("02 6E 83 FF 01 B1 A2 03")
  ctx.engine:Raw("custom", packet, function(ok, value, raw) got = { ok, raw } end)
  T.eq(ctx.sent[2], packet)
  ctx.engine:OnData(F.read(0xB1, 0x00, 0xFF, 0x00, 0x32))
  T.truthy(got[1])
  T.truthy(got[2]:find("B1 00 FF 00 32", 1, true))
end)

T.test("a raw packet is never retried", function()
  local ctx = ready()
  local got
  ctx.engine:Raw("custom", "\x02\x03", function(ok, value) got = { ok, value } end)
  ctx.engine:Tick(2.0)
  T.eq(#ctx.sent, 2)
  T.eq(got[2], "timeout")
end)

T.test("closing fails everything pending and clears the receive buffer", function()
  local ctx = ready()
  local reasons = {}
  ctx.engine:Query("power", Commands.Queries.power, function(ok, why) reasons[#reasons + 1] = why end)
  ctx.engine:Query("input", Commands.Queries.input, function(ok, why) reasons[#reasons + 1] = why end)
  ctx.engine:OnData("\x02\x6E") -- half a frame
  ctx.engine:OnClosed("closed")
  T.eq(table.concat(reasons, ","), "closed,closed")
  T.eq(ctx.engine.state, "Disconnected")
  ctx.engine:Tick(5.0)
  T.eq(ctx.connects, 2)
  ctx.engine:OnConnected()
  ctx.engine:OnData(POWER_ON)
  T.eq(ctx.engine.state, "Ready", "stale half-frame must not corrupt the next session")
end)

T.test("reconnect delay doubles up to the maximum and resets after a reply", function()
  local ctx = setup()
  ctx.engine:Start(0)
  ctx.engine:Tick(0)
  ctx.engine:OnClosed("closed")
  T.eq(ctx.engine.nextConnectAt, 5)
  ctx.engine:Tick(5)
  ctx.engine:OnClosed("closed")
  T.eq(ctx.engine.nextConnectAt, 15)
  ctx.engine:Tick(15)
  ctx.engine:OnConnected()
  ctx.engine:OnData(POWER_ON)
  T.eq(ctx.engine.backoff, 5)
end)

T.test("unsolicited frames are logged and ignored", function()
  local ctx = ready()
  ctx.engine:OnData(F.read(0xB1, 0x00, 0xFF, 0x00, 0x32))
  T.eq(ctx.engine.state, "Ready")
  local seen = false
  for _, l in ipairs(ctx.logs) do if l:find("unsolicited", 1, true) then seen = true end end
  T.truthy(seen)
end)

return T.finish()
