-- UnrealBuildTool commands: build, clean, rebuild, compile database, project files.
local util = require("ue.util")
local config = require("ue.config")
local project = require("ue.project")
local job = require("ue.job")

local M = {}

local function target_args(proj, sel)
  return { sel.target, sel.platform, sel.config, "-Project=" .. proj.uproject }
end

---@param chained boolean? true when this runs right after another job (keeps its log)
function M.build(proj, sel, on_done, chained)
  local cmd = { proj.ubt }
  vim.list_extend(cmd, target_args(proj, sel))
  vim.list_extend(cmd, config.options.build_args)
  job.run(cmd, {
    title = ("Build %s %s %s"):format(sel.target, sel.platform, sel.config),
    append = chained,
    on_exit = function(code)
      if code == 0 and config.options.auto_compiledb and M.compiledb_stale(proj) then
        -- Refresh clangd's database, then carry on (launch/debug) whatever its result.
        M.compiledb(proj, sel, function() if on_done then on_done(code) end end, true)
        return
      end
      if on_done then on_done(code) end
    end,
  })
end

function M.clean(proj, sel, on_done)
  local cmd = { proj.ubt, "-Clean" }
  vim.list_extend(cmd, target_args(proj, sel))
  job.run(cmd, {
    title = ("Clean %s %s %s"):format(sel.target, sel.platform, sel.config),
    on_exit = function(code) if on_done then on_done(code) end end,
  })
end

function M.rebuild(proj, sel)
  M.clean(proj, sel, function(code)
    if code == 0 then M.build(proj, sel, nil, true) end
  end)
end

function M.project_files(proj)
  job.run({ proj.ubt, "-ProjectFiles", "-Project=" .. proj.uproject, "-Game", "-Engine" }, {
    title = "Generate project files",
    quickfix = false,
  })
end

---------------------------------------------------------------------------
-- compile_commands.json for clangd
---------------------------------------------------------------------------
function M.compiledb_path(proj) return proj.root .. "/compile_commands.json" end

--- True when the database is missing or older than any *.Build.cs / *.Target.cs / .uproject.
function M.compiledb_stale(proj)
  local db = vim.uv.fs_stat(M.compiledb_path(proj))
  if not db then return true end
  local newest = (vim.uv.fs_stat(proj.uproject) or {}).mtime
  local files = {}
  for _, dir in ipairs({ "Source", "Plugins" }) do
    vim.list_extend(files, vim.fs.find(function(name)
      return name:match("%.Build%.cs$") or name:match("%.Target%.cs$")
    end, { path = proj.root .. "/" .. dir, type = "file", limit = math.huge }))
  end
  for _, f in ipairs(files) do
    local st = vim.uv.fs_stat(f)
    if st and newest and st.mtime.sec > newest.sec then newest = st.mtime end
  end
  return newest ~= nil and newest.sec > db.mtime.sec
end

local CLANGD_FILE = [[
# Written by ue5.nvim. clangd reads this next to compile_commands.json.
CompileFlags:
  # MSVC precompiled-header flags point at .pch files clangd can't use.
  Remove: [/Yu*, /Yc*, /Fp*, /d2*]
  # UE builds with MSVC's conforming preprocessor (/Zc:preprocessor), but clang-cl
  # defines _MSVC_TRADITIONAL=1, which sends UE's macros down a path clang rejects.
  Add: [/U_MSVC_TRADITIONAL]
Diagnostics:
  UnusedIncludes: None
  MissingIncludes: None
]]

local function restart_clangd()
  if not config.options.restart_clangd then return end
  local clients = vim.lsp.get_clients({ name = "clangd" })
  if #clients == 0 then return end
  for _, c in ipairs(clients) do c:stop() end
  vim.defer_fn(function()
    -- Re-trigger attachment for open C/C++ buffers.
    for _, b in ipairs(vim.api.nvim_list_bufs()) do
      if vim.api.nvim_buf_is_loaded(b) and vim.tbl_contains({ "c", "cpp" }, vim.bo[b].filetype) then
        vim.api.nvim_exec_autocmds("FileType", { buffer = b })
      end
    end
  end, 500)
end

--- UBT's clang-database mode defaults to the Clang toolchain on Windows, which needs
--- Visual Studio's "C++ Clang tools" component. Use MSVC unless told otherwise; clangd
--- understands cl.exe command lines fine.
local function compiledb_compiler()
  local opt = config.options.compiledb_compiler
  if opt ~= nil then return opt ~= false and opt or nil end
  if not util.is_win then return nil end
  local vswhere = (os.getenv("ProgramFiles(x86)") or "C:/Program Files (x86)")
    .. "/Microsoft Visual Studio/Installer/vswhere.exe"
  if not util.exists(vswhere) then return nil end
  local out = vim.fn.system({ vswhere, "-latest", "-prerelease", "-property", "installationVersion" })
  local major = tonumber((out or ""):match("^(%d+)"))
  if major == 18 then return "VisualStudio2026" end
  if major == 17 then return "VisualStudio2022" end
end

---------------------------------------------------------------------------
-- UBT's clang-database mode rewrites the build's own response files (*.Shared.rsp,
-- *.dll.rsp, LiveCodingInfo.json ...) under Intermediate/Build with database-mode flags.
-- The next real build then sees "Shared.rsp modified", invalidates its makefile and
-- recompiles the project. So: snapshot those files, let UBT write the database, copy the
-- database-mode .rsp files clangd needs into .cache/ue.nvim/rsp, then put the build's
-- files back byte for byte with their original timestamps.
---------------------------------------------------------------------------
local SKIP_DIRS = { Content = true, Binaries = true, Source = true, Resources = true, Config = true,
  [".git"] = true, [".cache"] = true, Saved = true, DerivedDataCache = true }

local function intermediate_build_dirs(root)
  local dirs = {}
  local function walk(dir, depth)
    if depth > 6 then return end
    for name, kind in vim.fs.dir(dir) do
      if kind == "directory" then
        local path = dir .. "/" .. name
        if name == "Intermediate" then
          if util.exists(path .. "/Build") then dirs[#dirs + 1] = path .. "/Build" end
        elseif not SKIP_DIRS[name] then
          walk(path, depth + 1)
        end
      end
    end
  end
  walk(root, 0)
  return dirs
end

local function is_build_state_file(name)
  return name:match("%.rsp$") or name:match("LiveCodingInfo%.json$")
end

local function scan_state_files(dirs)
  local files = {}
  for _, d in ipairs(dirs) do
    for name, kind in vim.fs.dir(d, { depth = 12 }) do
      if kind == "file" and is_build_state_file(name) then files[#files + 1] = d .. "/" .. name end
    end
  end
  return files
end

local function snapshot_build_state(root)
  local dirs = intermediate_build_dirs(root)
  local snap = {}
  for _, f in ipairs(scan_state_files(dirs)) do
    local st = vim.uv.fs_stat(f)
    local fd = io.open(f, "rb")
    if st and fd then
      snap[f] = { data = fd:read("*a"), atime = st.atime, mtime = st.mtime }
      fd:close()
    end
  end
  return { dirs = dirs, files = snap }
end

local function restore_build_state(snapshot)
  local restored, removed = 0, 0
  for f, s in pairs(snapshot.files) do
    local fd = io.open(f, "rb")
    local cur = fd and fd:read("*a")
    if fd then fd:close() end
    if cur ~= s.data then
      local out = io.open(f, "wb")
      if out then
        out:write(s.data)
        out:close()
        restored = restored + 1
      end
    end
    vim.uv.fs_utime(f, s.atime.sec + s.atime.nsec / 1e9, s.mtime.sec + s.mtime.nsec / 1e9)
  end
  -- Files only the database mode created: the build never had them, so drop them.
  for _, f in ipairs(scan_state_files(snapshot.dirs)) do
    if not snapshot.files[f] and f:match("%.rsp$") then
      os.remove(f)
      removed = removed + 1
    end
  end
  return restored, removed
end

--- The forced includes the real build uses for the module in `dir`: its shared/private
--- PCH header plus Definitions.<Module>.h, taken from a build-mode .cpp.obj.rsp that
--- uses /Yu. The database mode leaves the PCH out, so without this clangd misses
--- everything the PCH brings in (UPackage, UGameInstance ...) and reports errors that
--- Visual Studio and the build never show. nil when the module has no PCH build yet.
local function build_forced_includes(snapshot, dir, cache, wrap_dir)
  if cache[dir] ~= nil then return cache[dir] or nil end
  cache[dir] = false
  for f, s in pairs(snapshot.files) do
    if vim.fs.dirname(f) == dir and f:match("%.cpp%.obj%.rsp$") and s.data:find("/Yu", 1, true) then
      local lines = {}
      for line in s.data:gmatch("[^\r\n]+") do
        local hdr = line:match('^/FI"(.-)"%s*$')
        if hdr then
          if not util.exists(hdr) then return nil end
          if util.exists(hdr .. ".pch") then
            -- clang treats a "<header>.pch" next to a forced include as its own PCH and
            -- fails on MSVC's format, silently dropping the include. Force-include a
            -- wrapper that #includes the real header instead.
            local wrapper = wrap_dir .. "/" .. vim.fs.basename(hdr)
            if not util.exists(wrapper) then
              util.write_file(wrapper, ('// Written by ue5.nvim\n#pragma once\n#include "%s"\n'):format(hdr))
            end
            line = ('/FI"%s"'):format(wrapper)
          end
          lines[#lines + 1] = line
          -- MSVC finds headers next to already-included ones (Definitions.<Module>.h
          -- includes SharedDefinitions.*.h from the PCH folder); clang needs the folder.
          lines[#lines + 1] = ('/I "%s"'):format(vim.fs.dirname(hdr))
        end
      end
      if #lines > 0 then cache[dir] = lines end
      break
    end
  end
  return cache[dir] or nil
end

--- Points every @"file.rsp" in compile_commands.json at a private copy under
--- .cache/ue.nvim/rsp (nested @ references included), so clangd's flags no longer
--- depend on files the build rewrites or :UE clean deletes. Per-file copies get the
--- build's forced includes in place of the database mode's Definitions.h.
local function detach_compiledb(proj, snapshot)
  local db_path = M.compiledb_path(proj)
  local entries = util.read_json(db_path)
  if type(entries) ~= "table" then return false end
  local mirror_root = proj.root .. "/.cache/ue.nvim/rsp"
  local copied, fi_cache = {}, {}
  local rewrite
  local function with_build_includes(src, data)
    if not (config.options.compiledb_pch and src:match("%.cpp%.obj%.rsp$")) then return data end
    local fis = build_forced_includes(snapshot, vim.fs.dirname(src), fi_cache, proj.root .. "/.cache/ue.nvim/pch")
    if not fis then return data end
    local replaced = false
    data = data:gsub('/FI"[^"\r\n]-/Definitions%.h"', function()
      if replaced then return "" end
      replaced = true
      return table.concat(fis, "\r\n")
    end)
    return data
  end
  local function copy(ref)
    local src = util.norm(ref)
    if copied[src] then return copied[src] end
    local data = util.read_file(src)
    if not data then return ref end
    local dst = mirror_root .. "/" .. src:gsub("^(%a):", "%1")
    copied[src] = dst
    util.write_file(dst, rewrite(with_build_includes(src, data)))
    return dst
  end
  rewrite = function(text)
    text = text:gsub('@"([^"]+)"', function(ref) return '@"' .. copy(ref) .. '"' end)
    return (text:gsub('@([^%s"]+)', function(ref) return '@"' .. copy(ref) .. '"' end))
  end
  for _, e in ipairs(entries) do
    if e.command then e.command = rewrite(e.command) end
    if e.arguments then
      for i, a in ipairs(e.arguments) do e.arguments[i] = rewrite(a) end
    end
  end
  util.write_file(db_path, vim.json.encode(entries))
  return true
end

---@param chained boolean? after a build: append to its log and keep its quickfix list
function M.compiledb(proj, sel, on_done, chained)
  local cmd = {
    proj.ubt, "-Mode=GenerateClangDatabase",
    "-Project=" .. proj.uproject,
    sel.target, sel.platform, sel.config,
    "-OutputDir=" .. proj.root,
  }
  local compiler = compiledb_compiler()
  if compiler then table.insert(cmd, "-Compiler=" .. compiler) end
  local started = os.time()
  local snapshot = snapshot_build_state(proj.root)
  local function finish(code)
    if code ~= 0 then
      restore_build_state(snapshot)
      return code
    end
    local dest = M.compiledb_path(proj)
    local st = vim.uv.fs_stat(dest)
    if not st or st.mtime.sec < started - 1 then
      -- Older UBT ignores -OutputDir and writes to the engine root.
      local engine_db = proj.engine .. "/compile_commands.json"
      if util.exists(engine_db) then
        util.write_file(dest, util.read_file(engine_db))
      else
        util.notify("UBT finished but no compile_commands.json was written", vim.log.levels.ERROR)
        restore_build_state(snapshot)
        return 1
      end
    end
    detach_compiledb(proj, snapshot)
    local restored, removed = restore_build_state(snapshot)
    require("ue.job").log(("[ue5.nvim] restored %d build response files, removed %d database-only ones"):format(
      restored, removed))
    local clangd_file = proj.root .. "/.clangd"
    if config.options.write_clangd_file and not util.exists(clangd_file) then
      util.write_file(clangd_file, CLANGD_FILE)
    end
    util.notify("compile_commands.json written to " .. proj.root)
    restart_clangd()
    return 0
  end
  job.run(cmd, {
    title = "Compile database " .. sel.target,
    append = chained,
    -- After a build, the build's warnings/errors stay in the quickfix list.
    quickfix = not chained,
    on_exit = function(code)
      local result = finish(code)
      if on_done then on_done(result) end
    end,
  })
end

return M
