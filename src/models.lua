-- Model registry plus data shared by design-time and runtime code.
--
-- The Elo 6554L is the only supported model. Everything model specific
-- (identity, default port, input choices and their MDC codes) lives here so
-- another IDS54-family display could be added without touching the engine.
local Models = {
  ById = {},
  Default = "Elo 6554L",
}

Models.ById["Elo 6554L"] = {
  Id = "Elo 6554L",
  Name = "Elo 6554L",
  Model = "ET6554L",
  Family = "IDS54",
  SizeInches = 65,
  DefaultPort = 5000,
  -- Order is the order shown in the Input combo box. Codes are the value
  -- byte of the MDC input command (0x60).
  Inputs = {
    { Label = "HDMI 1", Code = 0x20 },
    { Label = "HDMI 2", Code = 0x10 },
    { Label = "DisplayPort", Code = 0x40 },
    { Label = "USB-C", Code = 0x08 },
  },
}

function Models.Get(id)
  return Models.ById[id] or Models.ById[Models.Default]
end

return Models
