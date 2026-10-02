-- Elo MDC protocol over TCP: packet builder, receive framing, checksum and
-- reply interpretation.
--
-- Wire format (from the Elo IDS04/54 MDC application note), all raw bytes:
--   host -> display : 02 6E <LEN> FF <R/W> <CMD> [data...] <CS> 03
--   display -> host : 02 <host> <LEN> <slave> <R/W | error> <CMD> [data...] <CS> 03
-- LEN = 0x80 + number of bytes between LEN and CS. CS = sum of every byte
-- between START and CS (exclusive), modulo 256. A TCP read is not a frame:
-- Receiver reassembles frames from arbitrary segments using LEN.
--
-- Everything is a Lua string of raw bytes. Hex text is for logs only and is
-- never sent.
local Protocol = {}

Protocol.START = 0x02
Protocol.HOST = 0x6E
Protocol.TARGET = 0xFF
Protocol.READ = 0x01
Protocol.WRITE = 0x04
Protocol.STOP = 0x03
Protocol.MAX_BODY = 32 -- largest LEN-0x80 accepted; guards against garbage

-- ---------------------------------------------------------------------------
-- Checksum and builders
-- ---------------------------------------------------------------------------
function Protocol.Checksum(bytes)
  local sum = 0
  for _, value in ipairs(bytes) do sum = (sum + value) % 256 end
  return sum
end

local function toString(bytes)
  local out = {}
  for i, value in ipairs(bytes) do out[i] = string.char(value) end
  return table.concat(out)
end

-- rw: Protocol.READ or Protocol.WRITE. data: array of bytes (may be nil).
-- Returns the packet as a raw byte string.
function Protocol.Build(rw, command, data)
  data = data or {}
  local length = 0x80 + 3 + #data
  local body = { Protocol.HOST, length, Protocol.TARGET, rw, command }
  for _, value in ipairs(data) do body[#body + 1] = value end
  local packet = { Protocol.START }
  for _, value in ipairs(body) do packet[#packet + 1] = value end
  packet[#packet + 1] = Protocol.Checksum(body)
  packet[#packet + 1] = Protocol.STOP
  return toString(packet)
end

function Protocol.BuildRead(command)
  return Protocol.Build(Protocol.READ, command)
end

-- Variadic data bytes: BuildWrite(0xD6, 0x00, 0x01).
function Protocol.BuildWrite(command, ...)
  return Protocol.Build(Protocol.WRITE, command, { ... })
end

-- ---------------------------------------------------------------------------
-- Hex helpers (logging and the raw-command box only)
-- ---------------------------------------------------------------------------
function Protocol.ToHex(text)
  local out = {}
  for i = 1, #text do out[i] = string.format("%02X", text:byte(i)) end
  return table.concat(out, " ")
end

-- Turns "02 6E 83 FF 01 B1 A2 03" (spaces, commas and 0x prefixes allowed)
-- into a raw byte string. Returns nil and a reason on bad input.
function Protocol.ParseHex(text)
  local cleaned = tostring(text or ""):gsub("0[xX]", ""):gsub("[%s,]+", "")
  if cleaned == "" then return nil, "empty" end
  if not cleaned:match("^%x+$") then return nil, "not hexadecimal" end
  if #cleaned % 2 ~= 0 then return nil, "odd number of digits" end
  if #cleaned > 128 then return nil, "too long" end
  local out = {}
  for pair in cleaned:gmatch("%x%x") do out[#out + 1] = string.char(tonumber(pair, 16)) end
  return table.concat(out)
end

-- ---------------------------------------------------------------------------
-- Receive framing
-- ---------------------------------------------------------------------------
local Receiver = {}
Receiver.__index = Receiver

function Protocol.NewReceiver()
  return setmetatable({ buffer = "" }, Receiver)
end

function Receiver:Reset()
  self.buffer = ""
end

-- Appends `chunk` and returns every complete item found, in order:
--   { ok = true,  raw = <frame>, body = { slave, rw|error, cmd, data... } }
--   { ok = false, raw = <bytes discarded>, reason = <text> }
-- Incomplete data stays buffered for the next call.
function Receiver:Feed(chunk)
  local items = {}
  self.buffer = self.buffer .. (chunk or "")
  while true do
    local buf = self.buffer
    local start = buf:find("\2", 1, true)
    if not start then
      if #buf > 0 then items[#items + 1] = { ok = false, raw = buf, reason = "no start byte" } end
      self.buffer = ""
      break
    end
    if start > 1 then
      items[#items + 1] = { ok = false, raw = buf:sub(1, start - 1), reason = "bytes before start" }
      buf = buf:sub(start)
      self.buffer = buf
    end
    if #buf < 3 then break end

    local n = buf:byte(3) - 0x80
    if n < 1 or n > Protocol.MAX_BODY then
      items[#items + 1] = { ok = false, raw = buf:sub(1, 1), reason = "bad length" }
      self.buffer = buf:sub(2)
    else
      local size = n + 5 -- START HOST LEN <n bytes> CS STOP
      if #buf < size then break end
      local frame = buf:sub(1, size)
      local sum = 0
      for i = 2, n + 3 do sum = (sum + frame:byte(i)) % 256 end
      if frame:byte(size) ~= Protocol.STOP then
        items[#items + 1] = { ok = false, raw = frame:sub(1, 1), reason = "bad stop byte" }
        self.buffer = buf:sub(2)
      elseif frame:byte(size - 1) ~= sum then
        items[#items + 1] = { ok = false, raw = frame:sub(1, 1), reason = "bad checksum" }
        self.buffer = buf:sub(2)
      else
        local body = {}
        for i = 4, n + 3 do body[#body + 1] = frame:byte(i) end
        items[#items + 1] = { ok = true, raw = frame, body = body }
        self.buffer = buf:sub(size + 1)
      end
    end
  end
  return items
end

-- ---------------------------------------------------------------------------
-- Reply interpretation
-- ---------------------------------------------------------------------------
-- Write replies carry an error code (0x04 = no error); error codes other than
-- 0x04 mean the command failed. The code is shown to the operator as "E<hex>".
Protocol.ERR_NONE = 0x04

Protocol.Errors = {
  E01 = "Unsupported Command",
  E00 = "Device Error",
  E02 = "Device Error",
  E03 = "Device Error",
  E05 = "Device Error",
}

function Protocol.ErrorKey(code)
  return string.format("E%02X", code)
end

function Protocol.ErrorText(key)
  local text = Protocol.Errors[key] or "Device Error"
  return text
end

-- body = { slave, rw|error, cmd, data... } from Receiver:Feed.
-- Returns one of:
--   "ok", data                  data = array of return bytes (empty for writes)
--   "error", errorKey           display reported an error for this command
--   "mismatch"                  frame answers a different command
--   "malformed"                 frame shape does not fit the request
function Protocol.Interpret(body, kind, command)
  if #body < 3 then return "malformed" end
  if body[3] ~= command then return "mismatch" end
  local flag = body[2]

  if kind == "read" then
    if #body >= 4 and flag == Protocol.READ then
      local data = {}
      for i = 4, #body do data[#data + 1] = body[i] end
      return "ok", data
    end
    if #body == 3 then return "error", Protocol.ErrorKey(flag) end
    return "malformed"
  end

  if #body ~= 3 then return "malformed" end
  if flag == Protocol.ERR_NONE then return "ok", {} end
  return "error", Protocol.ErrorKey(flag)
end

return Protocol
