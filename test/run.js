// Runs test/*_test.lua under fengari (a Lua 5.3 VM written in JavaScript).
// Each test file gets a fresh Lua state. `require` resolves against src/ then
// test/, and __read(path) reads any file relative to the repo root (used to
// load the built bundle).

const fs = require('fs');
const path = require('path');
const { lua, lauxlib, lualib, to_luastring } = require('fengari');
const { build } = require('../build.js');

const ROOT = path.join(__dirname, '..');

const PRELUDE = `
local cache = {}
local function find(name)
  local rel = name:gsub("%.", "/")
  for _, dir in ipairs({ "src/", "test/" }) do
    local p = dir .. rel .. ".lua"
    local s = __read(p)
    if s then return s, p end
  end
end
function require(name)
  if cache[name] ~= nil then return cache[name] end
  local s, p = find(name)
  if not s then error("module not found: " .. name, 2) end
  local f, err = load(s, "@" .. p)
  if not f then error(err, 0) end
  local m = f(name)
  if m == nil then m = true end
  cache[name] = m
  return m
end
`;

function runFile(file) {
  const L = lauxlib.luaL_newstate();
  lualib.luaL_openlibs(L);

  lua.lua_pushjsfunction(L, (L2) => {
    const rel = lua.lua_tojsstring(L2, 1);
    const full = path.join(ROOT, rel);
    if (fs.existsSync(full) && fs.statSync(full).isFile()) {
      lua.lua_pushstring(L2, to_luastring(fs.readFileSync(full, 'utf8')));
    } else {
      lua.lua_pushnil(L2);
    }
    return 1;
  });
  lua.lua_setglobal(L, to_luastring('__read'));

  const load = (source, name) => {
    const buf = to_luastring(source);
    return lauxlib.luaL_loadbuffer(L, buf, buf.length, to_luastring(name));
  };
  const fail = (what) => {
    console.error(`${what}: ${lua.lua_tojsstring(L, -1)}`);
    return 1;
  };

  if (load(PRELUDE, '=prelude') !== 0 || lua.lua_pcall(L, 0, 0, 0) !== 0) return fail('prelude');

  const rel = path.relative(ROOT, file).replace(/\\/g, '/');
  if (load(fs.readFileSync(file, 'utf8'), '@' + rel) !== 0) return fail(rel);
  if (lua.lua_pcall(L, 0, 1, 0) !== 0) return fail(rel);
  return lua.lua_tointeger(L, -1);
}

const built = build();
console.log(`Built ${path.relative(ROOT, built.outPath)}\n`);

const files = fs
  .readdirSync(__dirname)
  .filter((f) => f.endsWith('_test.lua'))
  .sort();

let failures = 0;
for (const f of files) {
  console.log(f);
  failures += runFile(path.join(__dirname, f));
  console.log('');
}

console.log(failures === 0 ? 'All tests passed.' : `${failures} test(s) failed.`);
process.exit(failures === 0 ? 0 : 1);
