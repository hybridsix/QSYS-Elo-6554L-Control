-- Tests may replace the global print with a mock, so keep the real one.
local print = print

local T = { passed = 0, failed = 0 }

function T.test(name, fn)
  local ok, err = xpcall(fn, function(e) return debug.traceback(tostring(e), 2) end)
  if ok then
    T.passed = T.passed + 1
    print("  ok   " .. name)
  else
    T.failed = T.failed + 1
    print("  FAIL " .. name .. "\n" .. err)
  end
end

function T.eq(actual, expected, msg)
  if actual ~= expected then
    error((msg or "values differ") .. ": expected " .. tostring(expected) .. ", got " .. tostring(actual), 2)
  end
end

function T.truthy(value, msg)
  if not value then error(msg or "expected a truthy value", 2) end
end

function T.falsy(value, msg)
  if value then error(msg or "expected a falsy value", 2) end
end

-- Returns the failure count so the runner can set the exit code.
function T.finish()
  print(string.format("  %d passed, %d failed", T.passed, T.failed))
  return T.failed
end

return T
