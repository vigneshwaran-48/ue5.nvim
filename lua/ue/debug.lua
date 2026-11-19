-- Debugging through nvim-dap + codelldb, with Unreal's LLDB data formatters
-- (FString, TArray, TMap, FName ... shown as values instead of raw structs).
local util = require("ue.util")
local config = require("ue.config")
local project = require("ue.project")

local M = {}

local ADAPTER = "ue_codelldb"

local function codelldb_path()
  local opt = config.options.dap.codelldb
  if opt then return opt end
  local mason = vim.fn.stdpath("data") .. "/mason/packages/codelldb/extension/adapter/" .. util.exe("codelldb")
  if util.exists(mason) then return mason end
  local onpath = vim.fn.exepath("codelldb")
  if onpath ~= "" then return onpath end
end
M.codelldb_path = codelldb_path

local function ensure_adapter(dap)
  if dap.adapters[ADAPTER] then return true end
  local exe = codelldb_path()
  if not exe then
    util.notify("codelldb not found. Install it with :MasonInstall codelldb", vim.log.levels.ERROR)
    return false
  end
  dap.adapters[ADAPTER] = {
    type = "server",
    port = "${port}",
    executable = {
      command = exe,
      args = { "--port", "${port}" },
      detached = not util.is_win,
    },
  }
  return true
end

local function init_commands(proj)
  local cmds = {}
  if proj.lldb_formatters and util.exists(proj.lldb_formatters) then
    table.insert(cmds, ('command script import "%s"'):format(proj.lldb_formatters))
  end
  return cmds
end

--- Path of the executable a Game/Client/Server target produces.
local function target_exe(proj, sel)
  local suffix = sel.config == "Development" and "" or ("-" .. sel.platform .. "-" .. sel.config)
  return ("%s/Binaries/%s/%s%s"):format(proj.root, sel.platform, sel.target, suffix) .. (util.is_win and ".exe" or "")
end

local function base(proj, name)
  return {
    name = name,
    type = ADAPTER,
    initCommands = init_commands(proj),
    -- Engine modules are loaded later; without this, early breakpoints stay pending.
    stopOnEntry = false,
    sourceLanguages = { "cpp" },
  }
end

--- Builds the dap configurations for the current project / selection.
function M.configurations(proj, sel)
  local cfgs = {}
  local ttype = project.target_type(proj, sel.target)
  local extra = config.options.dap.editor_args or {}

  if ttype == "Editor" then
    local exe, cfg_args = project.editor_for(proj, sel.config)
    local args = { proj.uproject }
    vim.list_extend(args, cfg_args)
    vim.list_extend(args, extra)

    local editor = base(proj, ("UE: Launch editor (%s %s)"):format(sel.target, sel.config))
    editor.request = "launch"
    editor.program = exe
    editor.args = args
    editor.cwd = vim.fs.dirname(exe)
    table.insert(cfgs, editor)

    local game = base(proj, ("UE: Launch standalone game (%s %s)"):format(sel.target, sel.config))
    game.request = "launch"
    game.program = exe
    game.args = vim.list_extend(vim.list_extend({}, args), { "-game", "-log" })
    game.cwd = vim.fs.dirname(exe)
    table.insert(cfgs, game)
  else
    local exe = base(proj, ("UE: Launch %s (%s)"):format(sel.target, sel.config))
    exe.request = "launch"
    exe.program = target_exe(proj, sel)
    exe.args = ttype == "Server" and { "-log" } or {}
    exe.cwd = vim.fs.dirname(exe.program)
    table.insert(cfgs, exe)
  end

  local attach = base(proj, "UE: Attach to running process")
  attach.request = "attach"
  attach.pid = function()
    return require("dap.utils").pick_process({
      filter = function(p)
        local n = p.name:lower()
        return n:find("unreal", 1, true) or n:find(sel.target:lower(), 1, true)
      end,
    })
  end
  table.insert(cfgs, attach)
  return cfgs
end

local function get_dap()
  local ok, dap = pcall(require, "dap")
  if not ok then
    util.notify("nvim-dap is not installed", vim.log.levels.ERROR)
    return nil
  end
  if not ensure_adapter(dap) then return nil end
  -- LLDB's own PDB reader; codelldb is built without Microsoft's DIA SDK.
  vim.env.LLDB_USE_NATIVE_PDB_READER = "1"
  return dap
end

function M.run(cfg)
  local dap = get_dap()
  if dap then dap.run(cfg) end
end

--- :UE debug — pick a configuration and start it, building first if asked to.
function M.start(proj, sel, opts)
  opts = opts or {}
  local cfgs = M.configurations(proj, sel)
  local function go(cfg)
    if not cfg then return end
    if cfg.request == "launch" and opts.build ~= false then
      require("ue.ubt").build(proj, sel, function(code)
        if code == 0 then M.run(cfg) end
      end)
    else
      M.run(cfg)
    end
  end
  if opts.attach then return go(cfgs[#cfgs]) end
  if #cfgs == 1 then return go(cfgs[1]) end
  vim.ui.select(cfgs, {
    prompt = "Unreal debug",
    format_item = function(c) return c.name end,
  }, go)
end

--- Registers the UE configurations so :DapContinue / <leader>dc offers them in C++ buffers.
function M.register(bufnr)
  local ok, dap = pcall(require, "dap")
  if not ok then return end
  local proj = project.get(bufnr)
  if not proj or not proj.engine then return end
  if not ensure_adapter(dap) then return end
  vim.env.LLDB_USE_NATIVE_PDB_READER = "1"
  dap.configurations.cpp = dap.configurations.cpp or {}
  -- Drop any UE entries from an earlier registration (target/config may have changed).
  local kept = {}
  for _, c in ipairs(dap.configurations.cpp) do
    if c.type ~= ADAPTER then kept[#kept + 1] = c end
  end
  vim.list_extend(kept, M.configurations(proj, project.selection(proj)))
  dap.configurations.cpp = kept
end

---------------------------------------------------------------------------
-- Visual Studio fallback (best debugger for UE on Windows; natvis, Live Coding aware).
---------------------------------------------------------------------------
local function devenv_path()
  if config.options.devenv then return config.options.devenv end
  local vswhere = (os.getenv("ProgramFiles(x86)") or "C:/Program Files (x86)")
    .. "/Microsoft Visual Studio/Installer/vswhere.exe"
  if not util.exists(vswhere) then return nil end
  local out = vim.fn.system({ vswhere, "-latest", "-prerelease", "-property", "productPath" })
  out = vim.trim(out or "")
  return out ~= "" and out or nil
end

function M.visual_studio(proj, sel)
  local devenv = devenv_path()
  if not devenv then
    util.notify("Visual Studio not found (set devenv in setup())", vim.log.levels.ERROR)
    return
  end
  local cfg = M.configurations(proj, sel)[1]
  local cmd = { devenv, "/debugexe", cfg.program }
  vim.list_extend(cmd, cfg.args or {})
  require("ue.job").spawn_detached(cmd)
  util.notify("Started Visual Studio debugger. Press F5 in Visual Studio to launch.")
end

return M
