local util = require("ue.util")
local config = require("ue.config")
local project = require("ue.project")

local M = {}

local CONFIGS_EDITOR = { "Development", "DebugGame", "Debug" }
local CONFIGS_GAME = { "Development", "DebugGame", "Debug", "Test", "Shipping" }

--- Current project + selection, with optional :UE <cmd> [Target] [Config] overrides.
local function context(args)
  local proj = project.require(0)
  if not proj then return nil end
  local sel = project.selection(proj)
  for _, a in ipairs(args or {}) do
    local is_target = false
    for _, t in ipairs(proj.targets) do
      if t.name == a then is_target = true end
    end
    if is_target then sel.target = a
    elseif vim.tbl_contains(CONFIGS_GAME, a) then sel.config = a
    elseif a == "Win64" or a == "Linux" or a == "Mac" then sel.platform = a
    else
      util.notify("Unknown argument: " .. a, vim.log.levels.WARN)
    end
  end
  return proj, sel
end

function M.select_target()
  local proj = project.require(0)
  if not proj then return end
  if #proj.targets == 0 then
    util.notify("No *.Target.cs files in " .. proj.root .. "/Source", vim.log.levels.WARN)
    return
  end
  vim.ui.select(proj.targets, {
    prompt = "Unreal target",
    format_item = function(t) return ("%s  (%s)"):format(t.name, t.type) end,
  }, function(t)
    if not t then return end
    local list = t.type == "Editor" and CONFIGS_EDITOR or CONFIGS_GAME
    vim.ui.select(list, { prompt = "Configuration for " .. t.name }, function(c)
      if not c then return end
      local sel = project.selection(proj)
      sel.target, sel.config = t.name, c
      project.save_selection(proj, sel)
      require("ue.debug").register(0)
      util.notify(("Target: %s %s %s"):format(sel.target, sel.platform, sel.config))
    end)
  end)
end

--- Starts the editor (or the game with -game) without a debugger. With opts.build,
--- builds the selected target first and only starts it when the build succeeds.
function M.launch(args, opts)
  local p, s = context(args)
  if not p then return end
  local function start()
    local exe, extra = project.editor_for(p, s.config)
    local cmd = { exe, p.uproject }
    if opts.game then vim.list_extend(cmd, { "-game", "-log" }) end
    require("ue.job").spawn_detached(vim.list_extend(cmd, extra))
    util.notify(opts.game and ("Starting " .. p.name .. " (-game)") or "Starting Unreal Editor")
  end
  if not opts.build then return start() end
  require("ue.ubt").build(p, s, function(code)
    if code == 0 then start() end
  end)
end

--- Closes the helper windows debugging and builds leave open: dap-ui panels, the dap
--- REPL/console, ue://log and the quickfix list. Code windows are left alone, and the
--- last window of the tab is never closed.
local HELPER_FT = {
  dapui_scopes = true, dapui_breakpoints = true, dapui_stacks = true, dapui_watches = true,
  dapui_console = true, ["dap-repl"] = true, ["dap-terminal"] = true, dap_float = true,
  uelog = true, qf = true,
}

function M.close_windows()
  pcall(function() require("dapui").close() end)
  pcall(function() require("dap").repl.close() end)
  local closed = 0
  for _, win in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
    if vim.api.nvim_win_is_valid(win) and #vim.api.nvim_tabpage_list_wins(0) > 1 then
      local buf = vim.api.nvim_win_get_buf(win)
      local ft = vim.bo[buf].filetype
      local name = vim.api.nvim_buf_get_name(buf)
      if HELPER_FT[ft] or name:match("%[dap%-terminal%]") or name:match("ue://log$") then
        if pcall(vim.api.nvim_win_close, win, true) then closed = closed + 1 end
      end
    end
  end
  return closed
end

function M.info()
  local proj = project.get(0)
  if not proj then
    util.notify("Not inside an Unreal project")
    return
  end
  local sel = project.selection(proj)
  local ubt = require("ue.ubt")
  local lines = {
    "Project:   " .. proj.uproject,
    "Engine:    " .. tostring(proj.engine) .. "  (association " .. tostring(proj.association) .. ")",
    ("Selected:  %s %s %s"):format(sel.target, sel.platform, sel.config),
    "Targets:   " .. table.concat(vim.tbl_map(function(t) return t.name end, proj.targets), ", "),
    "Compile DB: " .. (util.exists(ubt.compiledb_path(proj))
      and (ubt.compiledb_stale(proj) and "stale (run :UE compiledb)" or "up to date")
      or "missing (run :UE compiledb)"),
  }
  util.notify(table.concat(lines, "\n"))
end

M.commands = {
  build = function(a) local p, s = context(a); if p then require("ue.ubt").build(p, s) end end,
  rebuild = function(a) local p, s = context(a); if p then require("ue.ubt").rebuild(p, s) end end,
  clean = function(a) local p, s = context(a); if p then require("ue.ubt").clean(p, s) end end,
  compiledb = function(a) local p, s = context(a); if p then require("ue.ubt").compiledb(p, s) end end,
  projectfiles = function() local p = project.require(0); if p then require("ue.ubt").project_files(p) end end,
  target = function() M.select_target() end,
  editor = function(a) M.launch(a, { game = false, build = true }) end,
  editornobuild = function(a) M.launch(a, { game = false, build = false }) end,
  game = function(a) M.launch(a, { game = true, build = true }) end,
  gamenobuild = function(a) M.launch(a, { game = true, build = false }) end,
  debug = function(a) local p, s = context(a); if p then require("ue.debug").start(p, s) end end,
  debugnobuild = function(a) local p, s = context(a); if p then require("ue.debug").start(p, s, { build = false }) end end,
  attach = function(a) local p, s = context(a); if p then require("ue.debug").start(p, s, { attach = true }) end end,
  vsdebug = function(a) local p, s = context(a); if p then require("ue.debug").visual_studio(p, s) end end,
  log = function() require("ue.job").open_log() end,
  cancel = function() require("ue.job").cancel() end,
  close = function() M.close_windows() end,
  switch = function() require("ue.code").switch() end,
  crash = function() local p = project.get(0); if p then require("ue.crash").latest(p) else util.notify("Not inside an Unreal project") end end,
  crashes = function() local p = project.get(0); if p then require("ue.crash").pick(p) else util.notify("Not inside an Unreal project") end end,
  info = function() M.info() end,
  reload = function() project.clear_cache(); M.info() end,
}

local function complete(arglead, line)
  local words = vim.split(line, "%s+", { trimempty = true })
  local n = #words + (line:match("%s$") and 1 or 0)
  local items
  if n <= 2 then
    items = vim.tbl_keys(M.commands)
  else
    items = vim.list_extend({}, CONFIGS_GAME)
    local proj = project.get(0)
    if proj then
      for _, t in ipairs(proj.targets) do table.insert(items, t.name) end
    end
  end
  table.sort(items)
  return vim.tbl_filter(function(i) return i:find(arglead, 1, true) == 1 end, items)
end

local warned = {}

local function on_buffer(ev)
  local proj = project.get(ev.buf)
  if not proj then return end
  local ft = vim.bo[ev.buf].filetype
  if config.options.tabs and (ft == "c" or ft == "cpp" or ft == "cs") then
    vim.bo[ev.buf].expandtab = false
    vim.bo[ev.buf].tabstop = 4
    vim.bo[ev.buf].shiftwidth = 4
    vim.bo[ev.buf].softtabstop = 0
  end
  if ft == "c" or ft == "cpp" then
    if config.options.dap.enabled then require("ue.debug").register(ev.buf) end
    if not warned[proj.uproject] and not util.exists(proj.root .. "/compile_commands.json") then
      warned[proj.uproject] = true
      util.notify("No compile_commands.json for " .. proj.name
        .. ". Run :UE compiledb so clangd understands Unreal code.", vim.log.levels.WARN)
    end
  end
end

function M.setup(opts)
  config.setup(opts)

  vim.api.nvim_create_user_command("UE", function(cmd)
    local sub = cmd.fargs[1] or "info"
    local fn = M.commands[sub]
    if not fn then
      util.notify("Unknown :UE command: " .. sub, vim.log.levels.ERROR)
      return
    end
    fn(vim.list_slice(cmd.fargs, 2))
  end, { nargs = "*", complete = complete, desc = "Unreal Engine" })

  local group = vim.api.nvim_create_augroup("ue.nvim", { clear = true })
  vim.api.nvim_create_autocmd("FileType", {
    group = group,
    pattern = { "c", "cpp", "cs" },
    callback = on_buffer,
  })
  -- Unreal's .usf/.ush shaders are HLSL; .uproject/.uplugin are JSON.
  vim.filetype.add({
    extension = { usf = "hlsl", ush = "hlsl", uproject = "json", uplugin = "json" },
  })
end

--- Recommended clangd command for Unreal projects (also fine for other C++).
function M.clangd_cmd(extra)
  local cmd = {
    util.find_clangd() or "clangd",
    "--background-index",
    -- clangd indexes at "low" OS priority by default, which Windows starves badly.
    "--background-index-priority=normal",
    "--header-insertion=never", -- auto-includes break UE's .generated.h ordering
    "--completion-style=detailed",
    "--pch-storage=memory",
    -- Every UE .cpp pulls in most of the engine headers, so indexing is CPU-bound:
    -- use all cores but two.
    "-j=" .. math.max(2, #vim.uv.cpu_info() - 2),
  }
  return vim.list_extend(cmd, extra or {})
end

return M
