local T = require("helpers")
local Protocol = require("protocol")
local Commands = require("commands")

local function hex(s) return Protocol.ToHex(s) end

local reply = require("frames").reply

-- ---------------------------------------------------------------------------
-- Builders: every byte sequence published by Elo
-- ---------------------------------------------------------------------------
T.test("display on / off match Elo's published bytes", function()
  T.eq(hex(Commands.DisplayOn.packet), "02 6E 85 FF 04 D6 00 01 CD 03")
  T.eq(hex(Commands.DisplayOff.packet), "02 6E 85 FF 04 D6 00 05 D1 03")
end)

T.test("inputs match Elo's published bytes", function()
  T.eq(hex(Commands.Input(0x20).packet), "02 6E 84 FF 04 60 20 75 03")
  T.eq(hex(Commands.Input(0x10).packet), "02 6E 84 FF 04 60 10 65 03")
  T.eq(hex(Commands.Input(0x40).packet), "02 6E 84 FF 04 60 40 95 03")
  T.eq(hex(Commands.Input(0x08).packet), "02 6E 84 FF 04 60 08 5D 03")
end)

T.test("input labels map to the documented codes", function()
  T.eq(Commands.CodeForLabel(Commands.Inputs, "HDMI 1"), 0x20)
  T.eq(Commands.CodeForLabel(Commands.Inputs, "HDMI 2"), 0x10)
  T.eq(Commands.CodeForLabel(Commands.Inputs, "DisplayPort"), 0x40)
  T.eq(Commands.CodeForLabel(Commands.Inputs, "USB-C"), 0x08)
  T.eq(Commands.LabelForCode(Commands.Inputs, 0x40), "DisplayPort")
  T.eq(Commands.LabelForCode(Commands.Inputs, 0x99), nil)
end)

T.test("brightness matches Elo's published examples", function()
  local expected = {
    [0] = "02 6E 85 FF 04 10 00 00 06 03",
    [5] = "02 6E 85 FF 04 10 00 05 0B 03",
    [10] = "02 6E 85 FF 04 10 00 0A 10 03",
    [25] = "02 6E 85 FF 04 10 00 19 1F 03",
    [50] = "02 6E 85 FF 04 10 00 32 38 03",
    [75] = "02 6E 85 FF 04 10 00 4B 51 03",
    [80] = "02 6E 85 FF 04 10 00 50 56 03",
    [90] = "02 6E 85 FF 04 10 00 5A 60 03",
    [100] = "02 6E 85 FF 04 10 00 64 6A 03",
  }
  for level, bytes in pairs(expected) do
    T.eq(hex(Commands.Brightness(level).packet), bytes, "brightness " .. level)
  end
end)

T.test("absolute volume matches Elo's published example", function()
  T.eq(hex(Commands.Volume(90).packet), "02 6E 85 FF 04 62 00 5A B2 03")
end)

T.test("levels are clamped to 0-100 and rounded", function()
  T.eq(hex(Commands.Volume(150).packet), hex(Commands.Volume(100).packet))
  T.eq(hex(Commands.Volume(-5).packet), hex(Commands.Volume(0).packet))
  T.eq(hex(Commands.Brightness(49.6).packet), hex(Commands.Brightness(50).packet))
end)

T.test("read packets match the reference", function()
  T.eq(hex(Commands.Queries.temperature.packet), "02 6E 83 FF 01 B1 A2 03")
  T.eq(hex(Commands.Queries.power.packet), "02 6E 83 FF 01 D6 C7 03")
  T.eq(hex(Commands.Queries.brightness.packet), "02 6E 83 FF 01 10 01 03")
  T.eq(hex(Commands.Queries.volume.packet), "02 6E 83 FF 01 62 53 03")
  T.eq(hex(Commands.Queries.input.packet), "02 6E 83 FF 01 60 51 03")
  T.eq(hex(Commands.Queries.lifetime.packet), "02 6E 83 FF 01 C0 B1 03")
end)

T.test("relative volume builder matches the published bytes", function()
  T.eq(hex(Protocol.BuildWrite(0x61, 0x00, 0x01)), "02 6E 85 FF 04 61 00 01 58 03")
  T.eq(hex(Protocol.BuildWrite(0x61, 0x01, 0x01)), "02 6E 85 FF 04 61 01 01 59 03")
  T.eq(hex(Protocol.BuildWrite(0x61, 0x01, 0x05)), "02 6E 85 FF 04 61 01 05 5D 03")
end)

T.test("packets are raw bytes, not hex text", function()
  local packet = Commands.DisplayOn.packet
  T.eq(#packet, 10)
  T.eq(packet:byte(1), 0x02)
  T.eq(packet:byte(10), 0x03)
end)

T.test("write commands are idempotent and sliders coalesce", function()
  T.truthy(Commands.DisplayOn.idempotent)
  T.truthy(Commands.Volume(10).coalesce)
  T.truthy(Commands.Brightness(10).coalesce)
  T.falsy(Commands.DisplayOn.coalesce)
end)

-- ---------------------------------------------------------------------------
-- Hex helpers
-- ---------------------------------------------------------------------------
T.test("ParseHex accepts spaces, commas and 0x prefixes", function()
  local packet = Protocol.ParseHex("02 6E 83 FF 01 B1 A2 03")
  T.eq(packet, Commands.Queries.temperature.packet)
  T.eq(Protocol.ParseHex("0x02,0x6E"), "\x02\x6E")
  T.eq(Protocol.ParseHex("026e"), "\x02\x6E")
end)

T.test("ParseHex rejects bad input", function()
  T.eq(Protocol.ParseHex(""), nil)
  T.eq(Protocol.ParseHex("ZZ"), nil)
  T.eq(Protocol.ParseHex("026"), nil)
end)

-- ---------------------------------------------------------------------------
-- Receive framing
-- ---------------------------------------------------------------------------
T.test("a complete frame is returned with its body", function()
  local r = Protocol.NewReceiver()
  local items = r:Feed(reply(0x01, 0x04, 0xD6))
  T.eq(#items, 1)
  T.truthy(items[1].ok)
  T.eq(table.concat(items[1].body, ","), "1,4,214")
end)

T.test("a frame split across reads is reassembled", function()
  local r = Protocol.NewReceiver()
  local frame = reply(0x01, 0x01, 0xD6, 0x00, 0x01)
  for i = 1, #frame - 1 do
    T.eq(#r:Feed(frame:sub(i, i)), 0, "frame completed early at byte " .. i)
  end
  local items = r:Feed(frame:sub(#frame))
  T.eq(#items, 1)
  T.truthy(items[1].ok)
end)

T.test("several frames in one read are all returned", function()
  local r = Protocol.NewReceiver()
  local items = r:Feed(reply(0x01, 0x04, 0xD6) .. reply(0x01, 0x04, 0x60) .. reply(0x01, 0x04, 0x10))
  T.eq(#items, 3)
  T.eq(items[3].body[3], 0x10)
end)

T.test("a 0x03 inside return data does not end the frame", function()
  local r = Protocol.NewReceiver()
  local items = r:Feed(reply(0x01, 0x01, 0xB1, 0x00, 0x03, 0x03, 0x03))
  T.eq(#items, 1)
  T.truthy(items[1].ok)
  T.eq(#items[1].body, 7)
end)

T.test("a bad checksum is reported and the stream resyncs", function()
  local r = Protocol.NewReceiver()
  local bad = reply(0x01, 0x04, 0xD6)
  bad = bad:sub(1, #bad - 2) .. string.char((bad:byte(#bad - 1) + 1) % 256) .. "\x03"
  local items = r:Feed(bad .. reply(0x01, 0x04, 0x60))
  local good = 0
  local rejected
  for _, item in ipairs(items) do
    if item.ok then good = good + 1 else rejected = rejected or item.reason end
  end
  T.eq(good, 1)
  T.eq(rejected, "bad checksum")
end)

T.test("noise before a frame is discarded", function()
  local r = Protocol.NewReceiver()
  local items = r:Feed("\xFF\xFE" .. reply(0x01, 0x04, 0xD6))
  T.falsy(items[1].ok)
  T.truthy(items[2].ok)
end)

T.test("a nonsense length byte does not stall the buffer", function()
  local r = Protocol.NewReceiver()
  local items = r:Feed("\x02\x6E\x10" .. reply(0x01, 0x04, 0xD6))
  local good = 0
  for _, item in ipairs(items) do if item.ok then good = good + 1 end end
  T.eq(good, 1)
end)

-- ---------------------------------------------------------------------------
-- Reply interpretation
-- ---------------------------------------------------------------------------
T.test("a write reply with 0x04 is success", function()
  local status = Protocol.Interpret({ 0x01, 0x04, 0xD6 }, "write", 0xD6)
  T.eq(status, "ok")
end)

T.test("write error codes are mapped", function()
  local status, key = Protocol.Interpret({ 0x01, 0x01, 0xD6 }, "write", 0xD6)
  T.eq(status, "error")
  T.eq(key, "E01")
  T.eq(Protocol.ErrorText("E01"), "Unsupported Command")
  local _, other = Protocol.Interpret({ 0x01, 0x02, 0xD6 }, "write", 0xD6)
  T.eq(Protocol.ErrorText(other), "Device Error")
end)

T.test("a read reply returns the data bytes", function()
  local status, data = Protocol.Interpret({ 0x01, 0x01, 0xB1, 0x00, 0xFF, 0x00, 0x32 }, "read", 0xB1)
  T.eq(status, "ok")
  T.eq(table.concat(data, ","), "0,255,0,50")
end)

T.test("a reply for another command is a mismatch", function()
  T.eq((Protocol.Interpret({ 0x01, 0x04, 0x60 }, "write", 0xD6)), "mismatch")
end)

T.test("a short or odd-shaped reply is malformed", function()
  T.eq((Protocol.Interpret({ 0x01, 0x04 }, "write", 0xD6)), "malformed")
  T.eq((Protocol.Interpret({ 0x01, 0x04, 0xD6, 0x00 }, "write", 0xD6)), "malformed")
end)

-- ---------------------------------------------------------------------------
-- Return-data parsers
-- ---------------------------------------------------------------------------
T.test("power parser: 00 01 on, 00 05 backlight off, anything else nil", function()
  local parse = Commands.Queries.power.parse
  T.eq(parse({ 0x00, 0x01 }), "On")
  T.eq(parse({ 0x00, 0x05 }), "Off")
  T.eq(parse({ 0x00, 0x02 }), nil)
  T.eq(parse({ 0x01 }), nil)
end)

T.test("temperature parser reads the last two bytes big-endian", function()
  local parse = Commands.Queries.temperature.parse
  T.eq(parse({ 0x00, 0xFF, 0x00, 0x32 }), 50)
  T.eq(parse({ 0x00, 0xFF, 0x01, 0x00 }), 256)
  T.eq(parse({ 0x00, 0xFF }), nil)
end)

T.test("lifetime parser returns display and backlight hours", function()
  local value = Commands.Queries.lifetime.parse({ 0x01, 0x2C, 0x00, 0x64 })
  T.eq(value.display, 300)
  T.eq(value.backlight, 100)
  T.eq(Commands.Queries.lifetime.parse({ 0x01 }), nil)
end)

T.test("brightness and volume parsers use the current value, normalized to 0-100", function()
  T.eq(Commands.Queries.brightness.parse({ 0x00, 0x64, 0x00, 0x32 }), 50)
  T.eq(Commands.Queries.volume.parse({ 0x00, 0x64, 0x00, 0x5A }), 90)
  T.eq(Commands.Queries.volume.parse({ 0x00, 0xC8, 0x00, 0x64 }), 50, "scaled against a 200 maximum")
  T.eq(Commands.Queries.volume.parse({ 0x00, 0x64 }), nil)
  T.eq(Commands.Queries.volume.parse({ 0x00, 0x64, 0x00, 0xFF }), nil)
end)

T.test("input parser returns the code byte", function()
  T.eq(Commands.Queries.input.parse({ 0x20 }), 0x20)
  T.eq(Commands.Queries.input.parse({ 0x00, 0x40 }), 0x40)
  T.eq(Commands.Queries.input.parse({}), nil)
end)

T.test("serial parser shows printable characters, else hex", function()
  T.eq(Commands.Queries.serial.parse({ 0x41, 0x42, 0x31 }), "AB1")
  T.eq(Commands.Queries.serial.parse({ 0x01, 0x02 }), "01 02")
  T.eq(Commands.Queries.serial.hold, 5.0)
end)

return T.finish()
