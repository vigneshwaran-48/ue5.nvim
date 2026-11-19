local util = require("ue.util")

local M = {}

function M.check()
  local h = vim.health
  h.start("ue.nvim")

  if vim.fn.has("nvim-0.10") == 1 then h.ok("Neovim " .. tostring(vim.version()))
  else h.error("Neovim 0.10 or newer is required") end

  local clangd = util.find_clangd()
  if clangd then
    h.ok("clangd: " .. clangd)
    if vim.fn.exepath("clangd") == "" then
      h.info("clangd is not on PATH; use require('ue').clangd_cmd() as your clangd cmd")
    end
  else
    h.error("clangd not found (install LLVM or :MasonInstall clangd)")
  end

  if pcall(require, "dap") then h.ok("nvim-dap installed")
  else h.warn("nvim-dap not installed: debugging commands are unavailable") end

  local codelldb = require("ue.debug").codelldb_path()
  if codelldb then h.ok("codelldb: " .. codelldb)
  else h.warn("codelldb not found (:MasonInstall codelldb)") end

  local proj = require("ue.project").get(0)
  if not proj then
    h.info("Not inside an Unreal project (open nvim in a folder with a .uproject to check it)")
    return
  end
  h.ok("Project: " .. proj.uproject)
  if proj.engine and util.exists(proj.ubt) then h.ok("Engine: " .. proj.engine)
  else h.error("Engine " .. tostring(proj.association) .. " not found; set engine_path in setup()") end
  if proj.lldb_formatters and util.exists(proj.lldb_formatters) then
    h.ok("Unreal LLDB formatters: " .. proj.lldb_formatters)
  else
    h.warn("Unreal LLDB formatters not found; FString/TArray will show as raw structs")
  end
  local db = proj.root .. "/compile_commands.json"
  if not util.exists(db) then h.warn("compile_commands.json missing: run :UE compiledb")
  elseif require("ue.ubt").compiledb_stale(proj) then h.warn("compile_commands.json is older than the build rules: run :UE compiledb")
  else h.ok("compile_commands.json is up to date") end
end

return M
