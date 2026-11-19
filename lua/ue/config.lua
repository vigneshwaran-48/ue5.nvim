local M = {}

M.defaults = {
  -- Engine root (the folder that contains Engine/). nil = detect from the .uproject's
  -- EngineAssociation via the Epic launcher / registry. May also be a function(association).
  engine_path = nil,
  -- Configuration used until you pick one with :UE target.
  default_config = "Development",
  -- Write a .clangd file next to compile_commands.json (only if none exists).
  write_clangd_file = true,
  -- UBT -Compiler= for :UE compiledb. nil = MSVC matching your Visual Studio
  -- (VisualStudio2026 / VisualStudio2022); "Clang" needs VS's Clang tools; false = UBT default.
  compiledb_compiler = nil,
  -- Give clangd the same forced includes as the real build and Visual Studio (the
  -- module's shared PCH header). Without it clangd flags missing includes that the
  -- build hides. Needs one normal build of the module first.
  compiledb_pch = true,
  -- Restart clangd after a new compile database is written.
  restart_clangd = true,
  -- Regenerate compile_commands.json after a successful build when .Build.cs / .Target.cs
  -- files are newer than it.
  auto_compiledb = true,
  -- UE coding standard: tabs, width 4, for C/C++/C# buffers inside a UE project.
  tabs = true,
  -- Extra arguments appended to every UBT build invocation.
  build_args = { "-WaitMutex" },
  -- Open the quickfix list automatically when a build reports errors.
  open_quickfix = true,
  -- Show the ue://log window when a build/clean/compiledb job starts: reuse an open
  -- log window, otherwise split at the bottom. The cursor stays where it was.
  open_log = true,
  log_height = 15,
  dap = {
    enabled = true,
    -- Path to codelldb. nil = Mason's install, then PATH.
    codelldb = nil,
    -- Extra arguments passed to UnrealEditor when debugging.
    editor_args = {},
  },
  -- Visual Studio fallback for :UE vsdebug (Windows). nil = find with vswhere.
  devenv = nil,
}

M.options = vim.deepcopy(M.defaults)

function M.setup(opts)
  M.options = vim.tbl_deep_extend("force", vim.deepcopy(M.defaults), opts or {})
end

return M
