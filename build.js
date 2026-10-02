// Bundles src/ into a single Q-SYS .qplug file.
//
// Q-SYS plugins are one Lua file, so every module under src/ (except
// info.lua and plugin.lua) is wrapped in a function and served by a small
// local require() shim. Module names are the path relative to src/ with "/"
// replaced by ".", for example "models.foo".
//
// Output order: info.lua (PluginInfo), require shim, modules, plugin.lua.

const fs = require('fs');
const path = require('path');

const ROOT = __dirname;
const SRC = path.join(ROOT, 'src');
const DIST = path.join(ROOT, 'dist');
const OUT_NAME = 'Elo6554LControl.qplug';
const RAW_FILES = new Set(['info', 'plugin']);

function listModules(dir, prefix = '') {
  const names = [];
  for (const entry of fs.readdirSync(dir, { withFileTypes: true })) {
    if (entry.isDirectory()) {
      names.push(...listModules(path.join(dir, entry.name), `${prefix}${entry.name}.`));
    } else if (entry.name.endsWith('.lua')) {
      names.push(prefix + entry.name.slice(0, -4));
    }
  }
  return names.sort();
}

function readModule(name) {
  return fs.readFileSync(path.join(SRC, ...name.split('.')) + '.lua', 'utf8');
}

function build() {
  const version = require('./package.json').version;
  const modules = listModules(SRC).filter((n) => !RAW_FILES.has(n));

  const parts = [];
  parts.push(readModule('info').replace(/@VERSION@/g, version));
  parts.push(`
local __modules, __loaded = {}, {}
local function require(name)
  local m = __loaded[name]
  if m ~= nil then return m end
  local f = __modules[name]
  if not f then error("module not found: " .. name, 2) end
  m = f(name)
  if m == nil then m = true end
  __loaded[name] = m
  return m
end
`);
  for (const name of modules) {
    parts.push(`__modules[${JSON.stringify(name)}] = function(...)\n${readModule(name)}\nend\n`);
  }
  parts.push(readModule('plugin'));

  const bundle = parts.join('\n');
  fs.mkdirSync(DIST, { recursive: true });
  fs.writeFileSync(path.join(DIST, OUT_NAME), bundle);
  return { bundle, outPath: path.join(DIST, OUT_NAME), modules };
}

module.exports = { build, OUT_NAME };

if (require.main === module) {
  const { outPath, modules } = build();
  console.log(`Built ${outPath} (${modules.length} modules)`);
}
