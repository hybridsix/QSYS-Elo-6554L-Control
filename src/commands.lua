-- Elo 6554L MDC command definitions and reply parsers.
--
-- Every command here comes from the Elo 6554L references (see
-- ELO_6554L_COMMAND_REFERENCE.md). Do not add commands unless they are
-- verified against Elo documentation or a real display.
--
-- Packets are built with Protocol, never stored as fixed strings, so the
-- checksum is always computed. Parsers receive the return-data bytes (an
-- array of numbers) and return the decoded value, or nil if the data is not
-- in the documented shape.
local Protocol = require("protocol")
local Models = require("models")

local Commands = {}

-- MDC command bytes.
Commands.Id = {
  Brightness = 0x10,
  Input = 0x60,
  VolumeRelative = 0x61, -- documented but unused; absolute volume is preferred
  Volume = 0x62,
  Temperature = 0xB1,
  Lifetime = 0xC0,
  Power = 0xD6,
  Serial = 0xE2,
}

-- Elo asks for at least 5 seconds of quiet after a serial-number query.
Commands.SerialHold = 5.0

-- Power / backlight data bytes: D6 00 01 = backlight on, D6 00 05 = off.
Commands.BacklightOn = 0x01
Commands.BacklightOff = 0x05

Commands.Inputs = Models.Get(Models.Default).Inputs
Commands.LevelRange = { Min = 0, Max = 100 }

function Commands.Labels(list)
  local labels = {}
  for _, item in ipairs(list) do labels[#labels + 1] = item.Label end
  return labels
end

function Commands.CodeForLabel(list, label)
  for _, item in ipairs(list) do
    if item.Label == label then return item.Code end
  end
  return nil
end

function Commands.LabelForCode(list, code)
  for _, item in ipairs(list) do
    if item.Code == code then return item.Label end
  end
  return nil
end

-- ---------------------------------------------------------------------------
-- Commands. `idempotent` means a retry after a timeout cannot double-trigger
-- anything. `coalesce` means a newer request with the same key replaces one
-- that is still waiting in the queue (used for slider drags).
-- ---------------------------------------------------------------------------
local function clamp(value, range)
  local n = math.floor((tonumber(value) or range.Min) + 0.5)
  if n < range.Min then n = range.Min end
  if n > range.Max then n = range.Max end
  return n
end

local function write(command, ...)
  return {
    packet = Protocol.BuildWrite(command, ...),
    command = command,
    kind = "write",
    idempotent = true,
  }
end

-- "Display On / Off" is the reversible backlight state, never a true power-off.
Commands.DisplayOn = write(Commands.Id.Power, 0x00, Commands.BacklightOn)
Commands.DisplayOff = write(Commands.Id.Power, 0x00, Commands.BacklightOff)

function Commands.Input(code)
  return write(Commands.Id.Input, code)
end

local function level(command, value)
  local spec = write(command, 0x00, clamp(value, Commands.LevelRange))
  spec.coalesce = true
  return spec
end

function Commands.Brightness(value)
  return level(Commands.Id.Brightness, value)
end

function Commands.Volume(value)
  return level(Commands.Id.Volume, value)
end

-- ---------------------------------------------------------------------------
-- Queries
-- ---------------------------------------------------------------------------
local function uint16(data, index)
  return data[index] * 256 + data[index + 1]
end

-- Brightness and volume replies: 2 bytes maximum, 2 bytes current. The
-- current value is normalized to 0-100 against the reported maximum.
local function parseLevel(data)
  if #data ~= 4 then return nil end
  local max, current = uint16(data, 1), uint16(data, 3)
  if max > 0 and max ~= 100 then
    current = math.floor(current * 100 / max + 0.5)
  end
  if current < 0 or current > 100 then return nil end
  return current
end

local function read(command, parse, extra)
  local spec = {
    packet = Protocol.BuildRead(command),
    command = command,
    kind = "read",
    parse = parse,
  }
  for k, v in pairs(extra or {}) do spec[k] = v end
  return spec
end

Commands.Queries = {
  -- 00 01 = backlight on, 00 05 = backlight off. Anything else is not guessed.
  power = read(Commands.Id.Power, function(data)
    if #data < 2 or data[#data - 1] ~= 0x00 then return nil end
    local state = data[#data]
    if state == Commands.BacklightOn then return "On" end
    if state == Commands.BacklightOff then return "Off" end
    return nil
  end),

  -- Returns the input code byte; the runtime maps it to a label and shows an
  -- unrecognized code as-is rather than hiding it.
  input = read(Commands.Id.Input, function(data)
    if #data < 1 then return nil end
    return data[#data]
  end),

  brightness = read(Commands.Id.Brightness, parseLevel),
  volume = read(Commands.Id.Volume, parseLevel),

  -- 00 FF TT TT: temperature in degrees C is the last two bytes, big-endian.
  temperature = read(Commands.Id.Temperature, function(data)
    if #data ~= 4 then return nil end
    return uint16(data, 3)
  end),

  -- 2 bytes display/system-on hours, 2 bytes backlight-on hours, big-endian.
  lifetime = read(Commands.Id.Lifetime, function(data)
    if #data ~= 4 then return nil end
    return { display = uint16(data, 1), backlight = uint16(data, 3) }
  end),

  -- The reply layout is not documented; show the printable characters, or hex
  -- if there are none.
  serial = read(Commands.Id.Serial, function(data)
    if #data < 1 then return nil end
    local chars = {}
    for _, byte in ipairs(data) do
      if byte >= 0x20 and byte <= 0x7E then chars[#chars + 1] = string.char(byte) end
    end
    local text = table.concat(chars)
    if text == "" then
      local hex = {}
      for i, byte in ipairs(data) do hex[i] = string.format("%02X", byte) end
      text = table.concat(hex, " ")
    end
    return text
  end, { hold = Commands.SerialHold }),
}

return Commands
