-- Finds the .uproject, the engine it belongs to, and the project's build targets.
local util = require("ue.util")
local config = require("ue.config")

local M = {}

local cache = {}

local function find_uproject(start)
  local root = vim.fs.root(start, function(name) return name:match("%.uproject$") ~= nil end)
  if not root then return nil end
  for name, kind in vim.fs.dir(root) do
    if kind == "file" and name:match("%.uproject$") then
      return util.norm(root .. "/" .. name), util.norm(root)
    end
  end
end

--- Source builds register a GUID under HKCU\Software\Epic Games\Unreal Engine\Builds.
local function engine_from_registry(assoc)
  if not util.is_win then return nil end
  local out = vim.fn.system({ "reg", "query", [[HKCU\Software\Epic Games\Unreal Engine\Builds]], "/v", assoc })
  if vim.v.shell_error ~= 0 then return nil end
  local path = out:match("REG_SZ%s+([^\r\n]+)")
  return path and util.norm(vim.trim(path)) or nil
end

--- Launcher installs are listed in LauncherInstalled.dat.
local function engine_from_launcher(assoc)
  local dat = util.is_win and "C:/ProgramData/Epic/UnrealEngineLauncher/LauncherInstalled.dat"
    or vim.fn.expand("~/.config/Epic/UnrealEngineLauncher/LauncherInstalled.dat")
  local data = util.read_json(dat)
  if not data or not data.InstallationList then return nil end
  for _, item in ipairs(data.InstallationList) do
    if item.AppName == "UE_" .. assoc then return util.norm(item.InstallLocation) end
  end
end

local function resolve_engine(uproject_dir, assoc)
  local opt = config.options.engine_path
  if type(opt) == "function" then opt = opt(assoc) end
  if opt and opt ~= "" then return util.norm(opt) end

  if assoc == nil or assoc == "" then
    -- Project lives inside a source engine tree: walk up to the folder holding Engine/.
    local root = vim.fs.root(uproject_dir, "Engine")
    if root then return util.norm(root) end
    return nil
  end
  if assoc:match("^[%./\\]") or assoc:match("^%a:") then
    return util.norm(vim.fn.fnamemodify(uproject_dir .. "/" .. assoc, ":p"))
  end
  local found = engine_from_launcher(assoc) or engine_from_registry(assoc)
  if found then return found end
  local default = util.is_win and ("C:/Program Files/Epic Games/UE_" .. assoc) or nil
  if default and util.exists(default) then return default end
end

local function scan_targets(root)
  local targets = {}
  local src = root .. "/Source"
  if not util.exists(src) then return targets end
  -- class LyraServerEOSTarget : LyraServerTarget  -> inherits Type from its base.
  local info = {}
  for name, kind in vim.fs.dir(src) do
    local tname = kind == "file" and name:match("^(.+)%.Target%.cs$")
    if tname then
      local text = util.read_file(src .. "/" .. name) or ""
      info[tname .. "Target"] = {
        name = tname,
        type = text:match("Type%s*=%s*TargetType%.(%a+)"),
        base = text:match("class%s+[%w_]+%s*:%s*([%w_]+)"),
      }
    end
  end
  local function resolve(cls, depth)
    local t = info[cls]
    if not t or depth > 8 then return nil end
    return t.type or (t.base and resolve(t.base, depth + 1))
  end
  for cls, t in pairs(info) do
    local ttype = resolve(cls, 0)
    if not ttype then
      ttype = t.name:match("Editor$") and "Editor" or t.name:match("Server") and "Server"
        or t.name:match("Client") and "Client" or "Game"
    end
    table.insert(targets, { name = t.name, type = ttype })
  end
  table.sort(targets, function(a, b)
    local order = { Editor = 1, Game = 2, Client = 3, Server = 4, Program = 5 }
    local oa, ob = order[a.type] or 9, order[b.type] or 9
    if oa ~= ob then return oa < ob end
    return a.name < b.name
  end)
  return targets
end

--- Returns the project for a buffer (or cwd), or nil when not inside a UE project.
---@return table|nil
function M.get(bufnr)
  local start = vim.api.nvim_buf_get_name(bufnr or 0)
  if start == "" or start:match("^%a+://") then start = vim.uv.cwd() end
  local uproject, root = find_uproject(start)
  if not uproject then return nil end
  if cache[uproject] then return cache[uproject] end

  local desc = util.read_json(uproject) or {}
  local engine = resolve_engine(root, desc.EngineAssociation)
  local proj = {
    name = vim.fn.fnamemodify(uproject, ":t:r"),
    uproject = uproject,
    root = root,
    association = desc.EngineAssociation,
    engine = engine,
    targets = scan_targets(root),
  }
  if engine then
    local plat = util.host_platform()
    proj.ubt = engine .. "/Engine/Binaries/DotNET/UnrealBuildTool/" .. util.exe("UnrealBuildTool")
    proj.editor = engine .. "/Engine/Binaries/" .. plat .. "/" .. util.exe("UnrealEditor")
    proj.lldb_formatters = engine .. "/Engine/Extras/LLDBDataFormatters/"
      .. (util.is_win and "UEDataFormatters_2ByteChars.py" or "UEDataFormatters.py")
  end
  cache[uproject] = proj
  return proj
end

--- Editor executable for a configuration. UE 5 ships a separate DebugGame editor
--- (UnrealEditor-Win64-DebugGame.exe) that loads the DebugGame project modules; older
--- engines use UnrealEditor.exe -debug instead.
---@return string exe, string[] extra_args
function M.editor_for(proj, cfg)
  if cfg == "DebugGame" then
    local plat = util.host_platform()
    local exe = ("%s/Engine/Binaries/%s/UnrealEditor-%s-DebugGame"):format(proj.engine, plat, plat)
    exe = exe .. (util.is_win and ".exe" or "")
    if util.exists(exe) then return exe, {} end
    return proj.editor, { "-debug" }
  end
  return proj.editor, {}
end

--- Like get(), but tells the user what is missing.
function M.require(bufnr)
  local proj = M.get(bufnr)
  if not proj then
    util.notify("Not inside an Unreal project (no .uproject found above this file or cwd)", vim.log.levels.WARN)
    return nil
  end
  if not proj.engine or not util.exists(proj.ubt) then
    util.notify(("Could not find Unreal Engine %s for %s. Set engine_path in setup()."):format(
      tostring(proj.association), proj.name), vim.log.levels.ERROR)
    return nil
  end
  return proj
end

function M.clear_cache() cache = {} end

---------------------------------------------------------------------------
-- Per-project selection of target / configuration, kept between sessions.
---------------------------------------------------------------------------
local state_file = vim.fn.stdpath("data") .. "/ue.nvim/state.json"

local function load_state() return util.read_json(state_file) or {} end

function M.selection(proj)
  local s = load_state()[proj.uproject] or {}
  local target = s.target
  if not target then
    for _, t in ipairs(proj.targets) do
      if t.type == "Editor" then target = t.name break end
    end
    target = target or (proj.targets[1] and proj.targets[1].name) or (proj.name .. "Editor")
  end
  return {
    target = target,
    config = s.config or config.options.default_config,
    platform = s.platform or util.host_platform(),
  }
end

function M.save_selection(proj, sel)
  local s = load_state()
  s[proj.uproject] = sel
  util.write_file(state_file, vim.json.encode(s))
end

function M.target_type(proj, name)
  for _, t in ipairs(proj.targets) do
    if t.name == name then return t.type end
  end
  return name:match("Editor$") and "Editor" or "Game"
end

return M
