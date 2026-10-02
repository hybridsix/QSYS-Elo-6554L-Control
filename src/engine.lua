-- Transport state machine with a serialized request queue.
--
-- The engine is transport-agnostic. It is driven by:
--   Tick(now)            called periodically (seconds, monotonic)
--   OnConnected()        socket connected
--   OnData(bytes)        raw bytes received (any segmentation)
--   OnClosed(reason)     socket closed or errored
-- and talks to the outside through deps:
--   send(bytes), connect(), disconnect(), log(kind, msg), onState(state, detail)
--   onVerified(ok, value, raw)   optional; result of the verification query
--
-- States: Disconnected, Connecting, Verifying, Ready.
--
-- A connection is only trusted after the display answers a lightweight query
-- (options.Verify, a read spec) with a valid MDC frame. Only one request is
-- ever in flight. UI commands go ahead of queued polls. A request may ask for
-- a quiet period afterwards (spec.hold), used after the serial-number query.
local Protocol = require("protocol")

local Engine = {}
Engine.__index = Engine

Engine.Defaults = {
  ResponseTimeout = 2.0, -- seconds to wait for a reply
  ConnectTimeout = 10.0, -- seconds to wait for the socket to connect
  MaxFailures = 3,       -- consecutive timeouts before reconnecting
  MaxQueue = 50,
  ReconnectMin = 5.0,    -- first reconnect delay; doubles up to ReconnectMax
  ReconnectMax = 30.0,
  Verify = nil,          -- read spec sent after connecting
}

function Engine.New(deps, options)
  local self = setmetatable({}, Engine)
  self.deps = deps
  self.opt = {}
  for k, v in pairs(Engine.Defaults) do self.opt[k] = v end
  for k, v in pairs(options or {}) do self.opt[k] = v end
  self.state = "Disconnected"
  self.queue = {}
  self.inflight = nil
  self.failures = 0
  self.now = 0
  self.holdUntil = 0
  self.nextConnectAt = 0
  self.backoff = self.opt.ReconnectMin
  self.enabled = false
  self.session = false
  self.receiver = Protocol.NewReceiver()
  return self
end

function Engine:_log(kind, message)
  if self.deps.log then self.deps.log(kind, message) end
end

function Engine:_setState(state, detail)
  self.state = state
  self.detail = detail
  if self.deps.onState then self.deps.onState(state, detail) end
end

function Engine:IsReady()
  return self.state == "Ready"
end

function Engine:QueueDepth()
  return #self.queue + (self.inflight and 1 or 0)
end

function Engine:Start(now)
  self.enabled = true
  self.now = now or self.now
  self.nextConnectAt = self.now
end

function Engine:Stop()
  self.enabled = false
  if self.session then
    self.deps.disconnect()
    self:_closed("stopped")
  end
end

-- ---------------------------------------------------------------------------
-- Requests
-- ---------------------------------------------------------------------------
function Engine:_resolve(req, ok, value, raw)
  if req.hold then self.holdUntil = self.now + req.hold end
  if req.callback then req.callback(ok, value, raw) end
end

function Engine:_failAll(reason)
  local pending = {}
  if self.inflight then
    pending[#pending + 1] = self.inflight
    self.inflight = nil
  end
  for _, req in ipairs(self.queue) do pending[#pending + 1] = req end
  self.queue = {}
  for _, req in ipairs(pending) do self:_resolve(req, false, reason) end
end

function Engine:_enqueue(req)
  if self.state ~= "Ready" then
    self:_resolve(req, false, "not connected")
    return false
  end
  if req.key then
    if req.coalesce then
      -- A newer value replaces one still waiting in the queue. The replaced
      -- request is resolved as "superseded" so callers can keep their books.
      for _, queued in ipairs(self.queue) do
        if queued.key == req.key then
          local old = queued.callback
          queued.packet = req.packet
          queued.callback = req.callback
          if old then old(false, "superseded") end
          return true
        end
      end
    else
      -- A request with a key is dropped if one with the same key is pending.
      if self.inflight and self.inflight.key == req.key then return false end
      for _, queued in ipairs(self.queue) do
        if queued.key == req.key then return false end
      end
    end
  end
  if #self.queue >= self.opt.MaxQueue then
    self:_resolve(req, false, "queue full")
    return false
  end
  if req.kind == "write" then
    -- Writes go after earlier writes but ahead of queued reads.
    local pos = 1
    while pos <= #self.queue and self.queue[pos].kind == "write" do pos = pos + 1 end
    table.insert(self.queue, pos, req)
  else
    self.queue[#self.queue + 1] = req
  end
  self:_dispatch()
  return true
end

-- spec: { packet = <bytes>, command = 0xNN, idempotent = true, coalesce = false }
-- callback(ok, value, raw): ok=false carries a reason string in `value`;
-- `raw` is the reply frame as hex text when there was one.
function Engine:Command(key, spec, callback)
  return self:_enqueue({
    key = key,
    packet = spec.packet,
    command = spec.command,
    kind = "write",
    retries = spec.idempotent and 1 or 0,
    coalesce = spec.coalesce,
    hold = spec.hold,
    callback = callback,
  })
end

-- spec: { packet = <bytes>, command = 0xNN, parse = function(data) -> value|nil }
function Engine:Query(key, spec, callback)
  return self:_enqueue({
    key = key,
    packet = spec.packet,
    command = spec.command,
    kind = "read",
    parse = spec.parse,
    retries = 1,
    hold = spec.hold,
    callback = callback,
  })
end

-- Sends caller-supplied bytes as they are and resolves with the first valid
-- frame received. Never retried.
function Engine:Raw(key, packet, callback)
  return self:_enqueue({
    key = key,
    packet = packet,
    kind = "raw",
    raw = true,
    retries = 0,
    callback = callback,
  })
end

function Engine:_send(req)
  req.attempts = (req.attempts or 0) + 1
  req.sentAt = self.now
  self.inflight = req
  self:_log("tx", Protocol.ToHex(req.packet))
  self.deps.send(req.packet)
end

function Engine:_dispatch()
  if self.state ~= "Ready" or self.inflight then return end
  if self.now < self.holdUntil then return end
  local req = table.remove(self.queue, 1)
  if not req then return end
  self:_send(req)
end

function Engine:_checkTimeout()
  local req = self.inflight
  if not req or self.now - req.sentAt < self.opt.ResponseTimeout then return end
  self.inflight = nil
  self.failures = self.failures + 1
  self:_log("warn", "timeout waiting for command " .. string.format("%02X", req.command or 0))

  if self.state == "Verifying" then
    self:_resolve(req, false, "timeout")
    self.deps.disconnect()
    self:_closed("no response")
    return
  end
  if self.failures >= self.opt.MaxFailures then
    self:_resolve(req, false, "timeout")
    self.deps.disconnect()
    self:_closed("no response")
    return
  end
  if req.attempts <= req.retries then
    table.insert(self.queue, 1, req)
  else
    self:_resolve(req, false, "timeout")
  end
  self:_dispatch()
end

-- ---------------------------------------------------------------------------
-- Connection lifecycle
-- ---------------------------------------------------------------------------
function Engine:_closed(reason)
  if not self.session then return end
  self.session = false
  self.receiver:Reset()
  self.holdUntil = 0
  self:_setState("Disconnected", reason)
  self:_failAll(reason)
  self.failures = 0
  self.nextConnectAt = self.now + self.backoff
  self:_log("info", string.format("reconnect in %.0fs (%s)", self.backoff, tostring(reason)))
  self.backoff = math.min(self.backoff * 2, self.opt.ReconnectMax)
end

function Engine:_ready()
  self:_setState("Ready")
  self:_dispatch()
end

function Engine:OnConnected()
  self.session = true
  self.failures = 0
  self.receiver:Reset()
  local verify = self.opt.Verify
  if not verify then
    self:_ready()
    return
  end
  -- Connected is only claimed once the display answers a valid MDC frame.
  self:_setState("Verifying")
  self:_send({
    kind = "read",
    packet = verify.packet,
    command = verify.command,
    parse = verify.parse,
    retries = 0,
    callback = function(ok, value, raw)
      if self.deps.onVerified then self.deps.onVerified(ok, value, raw) end
    end,
  })
end

function Engine:OnClosed(reason)
  self:_closed(reason or "closed")
end

function Engine:Tick(now)
  self.now = now
  local state = self.state
  if state == "Disconnected" then
    if self.enabled and now >= self.nextConnectAt then
      self.session = true
      self.connectDeadline = now + self.opt.ConnectTimeout
      self:_setState("Connecting")
      self.deps.connect()
    end
  elseif state == "Connecting" then
    if now >= self.connectDeadline then
      self.deps.disconnect()
      self:_closed("connect timeout")
    end
  elseif state == "Verifying" then
    self:_checkTimeout()
  elseif state == "Ready" then
    self:_checkTimeout()
    self:_dispatch()
  end
end

-- ---------------------------------------------------------------------------
-- Receive path
-- ---------------------------------------------------------------------------
function Engine:OnData(bytes)
  if not self.session then return end
  for _, item in ipairs(self.receiver:Feed(bytes)) do
    if item.ok then
      self:_onFrame(item)
    else
      self:_log("warn", string.format("discarded (%s): %s", item.reason, Protocol.ToHex(item.raw)))
    end
  end
end

function Engine:_onFrame(frame)
  local hex = Protocol.ToHex(frame.raw)
  self:_log("rx", hex)

  local req = self.inflight
  if not req then
    self:_log("warn", "unsolicited frame: " .. hex)
    return
  end

  if req.raw then
    self.inflight = nil
    self.failures = 0
    self.backoff = self.opt.ReconnectMin
    self:_resolve(req, true, nil, hex)
    self:_dispatch()
    return
  end

  local status, detail = Protocol.Interpret(frame.body, req.kind, req.command)
  if status == "mismatch" then
    -- Not the answer to the request in flight; keep waiting for the real one.
    self:_log("warn", "frame for a different command ignored: " .. hex)
    return
  end
  self.inflight = nil

  -- Any reply that answers the request, even an error, proves the link works.
  self.failures = 0
  self.backoff = self.opt.ReconnectMin
  if self.state == "Verifying" then self:_setState("Ready") end

  if status == "ok" then
    if req.parse then
      local value = req.parse(detail)
      if value == nil then
        self:_resolve(req, false, "unexpected reply", hex)
      else
        self:_resolve(req, true, value, hex)
      end
    else
      self:_resolve(req, true, nil, hex)
    end
  elseif status == "error" then
    self:_resolve(req, false, detail, hex)
  else
    self:_resolve(req, false, "unexpected reply", hex)
  end

  self:_dispatch()
end

return Engine
