-- Test helper: builds display reply frames.
local Protocol = require("protocol")

local Frames = {}

-- Builds a display reply from body bytes { slave, rw|error, cmd, data... }.
function Frames.reply(...)
  local body = { ... }
  local covered = { 0x6E, 0x80 + #body }
  for _, b in ipairs(body) do covered[#covered + 1] = b end
  local out = { 0x02 }
  for _, b in ipairs(covered) do out[#out + 1] = b end
  out[#out + 1] = Protocol.Checksum(covered)
  out[#out + 1] = 0x03
  local chars = {}
  for i, b in ipairs(out) do chars[i] = string.char(b) end
  return table.concat(chars)
end

-- Write acknowledgement for `command` (error code 0x04 = no error).
function Frames.ack(command, errorCode)
  return Frames.reply(0x01, errorCode or 0x04, command)
end

-- Read reply for `command` carrying return data bytes.
function Frames.read(command, ...)
  return Frames.reply(0x01, 0x01, command, ...)
end

return Frames
