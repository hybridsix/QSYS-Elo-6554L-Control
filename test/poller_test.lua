local T = require("helpers")
local Poller = require("poller")

-- A stand-in engine that records queries instead of sending them.
local function fakeEngine()
  local e = { ready = true, queries = {}, callbacks = {} }
  function e:IsReady() return self.ready end
  function e:Query(key, _, cb)
    self.queries[#self.queries + 1] = key
    self.callbacks[key] = cb
    return true
  end
  function e:drain()
    local q = self.queries
    self.queries = {}
    return table.concat(q, ",")
  end
  return e
end

T.test("with unknown state only power is polled, at the normal interval", function()
  local e = fakeEngine()
  local p = Poller.New(e, {}, { NormalInterval = 3 })
  p:Tick(0)
  T.eq(e:drain(), "power")
  p:Tick(2.9)
  T.eq(e:drain(), "")
  p:Tick(3.0)
  T.eq(e:drain(), "power")
end)

T.test("becoming On makes every item due and then paces them", function()
  local e = fakeEngine()
  local p = Poller.New(e, {}, { NormalInterval = 3 })
  p:Tick(0)
  e:drain()
  p:SetPower("On")
  p:Tick(1) -- power was just polled at 0, so it is not due yet
  T.eq(e:drain(), "input,brightness,volume,temperature,lifetime")
  p:Tick(3)
  T.eq(e:drain(), "power")
  p:Tick(4)
  T.eq(e:drain(), "input")
  p:Tick(6)
  T.eq(e:drain(), "power,brightness,volume")
  p:Tick(16)
  T.truthy(e:drain():find("temperature", 1, true))
  p:Tick(61)
  T.truthy(e:drain():find("lifetime", 1, true))
end)

T.test("with the backlight off only power is polled", function()
  local e = fakeEngine()
  local p = Poller.New(e, {}, { NormalInterval = 3 })
  p:SetPower("Off")
  p:Tick(0)
  T.eq(e:drain(), "power")
  p:Tick(30)
  T.eq(e:drain(), "power")
end)

T.test("the normal interval is configurable", function()
  local e = fakeEngine()
  local p = Poller.New(e, {}, { NormalInterval = 5 })
  p:SetPower("On")
  p:Tick(0)
  e:drain()
  p:Tick(4.9)
  T.eq(e:drain(), "")
  p:Tick(5)
  T.eq(e:drain(), "power,input,brightness,volume")
end)

T.test("a boosted key is polled at the high-rate interval until it ends", function()
  local e = fakeEngine()
  local p = Poller.New(e, {}, { NormalInterval = 5, HighRateInterval = 1 })
  p:SetPower("On")
  p:Tick(0)
  e:drain()
  p:Boost("volume", 30)
  p:Tick(1)
  T.truthy(e:drain():find("volume", 1, true))
  p:Tick(2)
  T.truthy(e:drain():find("volume", 1, true))
  p:EndBoost("volume")
  p:Tick(3)
  T.falsy(e:drain():find("volume", 1, true))
end)

T.test("a boost expires after its timeout", function()
  local e = fakeEngine()
  local p = Poller.New(e, {}, { NormalInterval = 5, HighRateInterval = 1 })
  p:SetPower("On")
  p:Tick(0)
  e:drain()
  p:Boost("input", 3)
  p:Tick(3)
  T.truthy(p:IsBoosted("input"))
  p:Tick(3.5)
  T.falsy(p:IsBoosted("input"))
end)

T.test("nothing is polled while the engine is not ready", function()
  local e = fakeEngine()
  e.ready = false
  local p = Poller.New(e, {})
  p:Tick(0)
  p:PollNow("power")
  T.eq(e:drain(), "")
end)

T.test("Reset forgets the power state", function()
  local e = fakeEngine()
  local p = Poller.New(e, {})
  p:SetPower("On")
  p:Tick(0)
  e:drain()
  p:Reset()
  p:Tick(10)
  T.eq(e:drain(), "power")
end)

return T.finish()
