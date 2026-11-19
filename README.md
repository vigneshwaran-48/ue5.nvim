# ue.nvim

![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)
![AI generated](https://img.shields.io/badge/AI-generated-blueviolet)

Unreal Engine 5 C++ development in Neovim: clangd IntelliSense, UnrealBuildTool builds
with errors in the quickfix list, and debugging through nvim-dap + codelldb with Unreal's
own LLDB formatters (FString, TArray, TMap, FName shown as values).

Tested on Windows 11 with UE 5.8 (Launcher build), Visual Studio 2026, LyraStarterGame
and GameAnimationSample.

> [!NOTE]
> **AI disclosure:** this plugin's code and documentation were generated with AI
> ([Claude Code](https://claude.com/claude-code) by Anthropic), directed, reviewed and
> tested by the maintainer on real Unreal Engine projects. Please report anything that
> doesn't work in the issues.

## Setting up a fresh Windows machine

### 1. Unreal Engine and Visual Studio

- Install **Unreal Engine 5** from the Epic Games Launcher.
  For stepping into engine code, also tick *Editor symbols for debugging* in the engine's
  install options.
- Install **Visual Studio 2022 or 2026** with the **Game development with C++** workload
  (MSVC compiler and Windows SDK). UnrealBuildTool needs it to build, and ue.nvim uses it
  for `:UE compiledb` and `:UE vsdebug`.

### 2. Tools (PowerShell)

```powershell
winget install Git.Git Neovim.Neovim LLVM.LLVM BurntSushi.ripgrep.MSVC sharkdp.fd OpenJS.NodeJS.LTS
winget install DEVCOM.JetBrainsMonoNerdFont
```

- **LLVM** provides the `clangd` ue.nvim uses. Its installer doesn't add itself to PATH,
  and ue.nvim finds it in `C:\Program Files\LLVM\bin` anyway. Use this clangd rather than
  Mason's: Mason's Windows build has no zlib, can't read the compressed index, and
  re-indexes the whole project on every start.
- **ripgrep / fd** are for Telescope. **Node** is for the npm-based language servers.
- **Nerd Font:** in Windows Terminal, go to *Settings → Profiles → Defaults →
  Appearance → Font face* and choose **JetBrainsMono Nerd Font Mono**.

Open a new terminal afterwards so PATH picks up the new tools.

### 3. Neovim plugins (lazy.nvim)

Put ue.nvim on the machine. For now that means copying the folder to
`~/Documents/Projects/ue.nvim`, or cloning it there once it's on GitHub. Then add this spec:

```lua
-- lua/plugins/ue.lua
local path = vim.fn.expand("~/Documents/Projects/ue.nvim")
return {
  dir = path,
  name = "ue.nvim",
  cond = vim.uv.fs_stat(path) ~= nil, -- skipped on machines without the folder
  lazy = false,
  dependencies = { "mfussenegger/nvim-dap" },
  opts = {},
  keys = {
    { "<leader>ub", "<cmd>UE build<cr>",         desc = "UE: build" },
    { "<leader>ut", "<cmd>UE target<cr>",        desc = "UE: pick target/config" },
    { "<leader>ud", "<cmd>UE debug<cr>",         desc = "UE: build + debug" },
    { "<leader>ua", "<cmd>UE attach<cr>",        desc = "UE: attach to editor" },
    { "<leader>ue", "<cmd>UE editor<cr>",        desc = "UE: build + open editor" },
    { "<leader>uE", "<cmd>UE editornobuild<cr>", desc = "UE: open editor (no build)" },
    { "<leader>uc", "<cmd>UE compiledb<cr>",     desc = "UE: regenerate compile_commands.json" },
    { "<leader>ul", "<cmd>UE log<cr>",           desc = "UE: build log" },
    { "<leader>ux", "<cmd>UE cancel<cr>",        desc = "UE: cancel build" },
    { "<leader>uq", "<cmd>UE close<cr>",         desc = "UE: close debug/log/quickfix windows" },
  },
}
```

In your LSP setup, start clangd with ue.nvim's command. Don't also let mason-lspconfig set
up clangd, or you get two instances:

```lua
local ok_ue, ue = pcall(require, "ue")
lspconfig.clangd.setup({ cmd = ok_ue and ue.clangd_cmd() or nil })
```

nvim-dap needs no configuration for Unreal; ue.nvim registers its own adapter. Install
the debugger once:

```vim
:MasonInstall codelldb
```

Then check everything from inside a UE project folder:

```vim
:checkhealth ue
```

### Requirements, in short

- Neovim 0.10+
- `clangd` from LLVM
- For debugging: [nvim-dap](https://github.com/mfussenegger/nvim-dap) and `codelldb`
- Visual Studio, for building, `:UE compiledb` and `:UE vsdebug`

## First run in a project

1. Open nvim in the project folder (the one with the `.uproject`).
2. `:UE target` and pick e.g. `MyGameEditor` / `DebugGame` (or `Development`).
3. `:UE build` once. UHT creates the `*.generated.h` headers, and the build creates the
   shared PCH that clangd's flags use.
4. `:UE compiledb` to write `compile_commands.json` and `.clangd` in the project root.
5. Open a `.cpp`. clangd indexes the project in the background. The first time takes a few
   minutes; it's cached in `.cache/clangd`, so later starts take seconds.

clangd gets the same forced includes as the real build and Visual Studio (each module's
shared PCH header), so it doesn't flag includes that Unreal's PCH already provides. That
needs one normal build of the module first: run `:UE compiledb` again after the first build
of a new project or module.

After a successful build, the compile database is regenerated automatically when any
`*.Build.cs`, `*.Target.cs` or the `.uproject` is newer than it.

## Commands

| Command | What it does |
|---|---|
| `:UE info` | Project, engine, selected target, compile DB status |
| `:UE target` | Pick target + configuration (remembered per project) |
| `:UE build [Target] [Config]` | Build with UBT, errors to quickfix |
| `:UE rebuild` / `:UE clean` | Clean (+ build) |
| `:UE compiledb` | Generate `compile_commands.json` + `.clangd` |
| `:UE projectfiles` | Regenerate Visual Studio project files |
| `:UE editor` / `:UE game` | Build, then start the editor / the game (`-game`) without debugging. Starts only if the build succeeds |
| `:UE editornobuild` / `:UE gamenobuild` | Same without building |
| `:UE debug` | Build, then launch under codelldb (editor, standalone game, or attach) |
| `:UE debugnobuild` | Same without building |
| `:UE attach` | Attach to a running UnrealEditor / game |
| `:UE vsdebug` | Open the target under the Visual Studio debugger |
| `:UE log` / `:UE cancel` | Show the output of the last job / stop it |
| `:UE close` | Close dap-ui panels, the dap REPL, the log window and quickfix (code windows stay) |
| `:UE reload` | Re-read the .uproject and targets |

`:checkhealth ue` checks clangd, codelldb, the engine and the compile database.

The UE configurations are also added to `dap.configurations.cpp`, so `:DapContinue`
offers them in any C++ buffer of the project.

## Debugging notes

- **DebugGame** (pick it with `:UE target`) gives you unoptimized project code with an
  optimized engine. That's the usual choice for stepping through your own code.
  `:UE debug` starts `UnrealEditor-Win64-DebugGame.exe`, which loads the DebugGame
  modules (on engines without it, `UnrealEditor.exe -debug`).
- Engine symbols: stepping into engine code needs "Editor symbols for debugging",
  an install option in the Epic launcher. Without them you still debug your own modules.
- codelldb reads PDBs with LLDB's native reader. It works for breakpoints, stepping,
  locals and the UE formatters, but it's slower than Visual Studio on large modules.
  `:UE vsdebug` is the fallback when you need the full MSVC debugger (natvis, Live Coding).
- Building while the editor runs fails if Live Coding is on. Use Ctrl+Alt+F11 in the
  editor instead, or close it.

## Options

```lua
require("ue").setup({
  engine_path = nil,            -- engine root; nil = detect from EngineAssociation
  default_config = "Development",
  write_clangd_file = true,     -- write .clangd next to compile_commands.json if missing
  restart_clangd = true,
  auto_compiledb = true,
  tabs = true,                  -- UE coding standard: tabs, width 4
  build_args = { "-WaitMutex" },
  open_quickfix = true,
  open_log = true,              -- show ue://log when a job starts (reuses an open log window)
  log_height = 15,
  dap = { enabled = true, codelldb = nil, editor_args = {} },
  devenv = nil,                 -- Visual Studio devenv.exe; nil = vswhere
})
```

## License

[MIT](LICENSE). Free to use, change and redistribute, for commercial and non-commercial
projects alike. Keep the copyright and license notice in copies.
