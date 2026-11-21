# ue5.nvim

![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)
![AI generated](https://img.shields.io/badge/AI-generated-blueviolet)
![Neovim 0.10+](https://img.shields.io/badge/Neovim-0.10%2B-green)
![Unreal Engine 5](https://img.shields.io/badge/Unreal%20Engine-5-black)

A Neovim plugin for **Unreal Engine 5 C++ development**, so you can use Neovim instead of
Visual Studio or Rider for your UE5 projects:

- **clangd IntelliSense that matches Visual Studio.** It gives clangd the same shared
  precompiled header as Unreal's build, so you don't get the false "incomplete type" and
  "missing include" errors other setups show.
- **A fast index after the first run.** clangd's index is saved and reused, so reopening a
  project takes seconds.
- **`compile_commands.json` without side effects.** `:UE compiledb` generates it, and the
  next UnrealBuildTool build doesn't recompile your project.
- **Builds from Neovim.** UnrealBuildTool runs with a live log window, and errors go to the
  quickfix list.
- **Crash call stacks in the quickfix list.** `:UE crash` reads `Saved/Crashes` and jumps
  to the first frame in your own code. Plus header/source switching (`:UE switch`).
- **Debugging with nvim-dap and codelldb.** Breakpoints, stepping, the call stack, and
  Unreal's LLDB formatters (FString, TArray, TMap, FName). You can launch the DebugGame or
  Development editor, or attach to a running one.

Tested on Windows 11 with UE 5.8 (Launcher build) and Visual Studio 2026, using the
LyraStarterGame project. Linux and macOS support is written but **untested**; see
[Linux](#linux-untested) and [macOS](#macos-untested).

> [!NOTE]
> **AI disclosure:** this plugin's code and documentation were generated with AI,
> directed, reviewed and tested by the maintainer on real Unreal Engine projects. Please
> report anything that doesn't work in the issues.

## Setting up a fresh Windows machine

### 1. Unreal Engine and Visual Studio

- Install **Unreal Engine 5** from the Epic Games Launcher.
  For stepping into engine code, also tick *Editor symbols for debugging* in the engine's
  install options.
- Install **Visual Studio 2022 or 2026** with the **Game development with C++** workload
  (MSVC compiler and Windows SDK). UnrealBuildTool needs it to build, and ue5.nvim uses it
  for `:UE compiledb` and `:UE vsdebug`.

### 2. Tools (PowerShell)

```powershell
winget install Git.Git Neovim.Neovim LLVM.LLVM BurntSushi.ripgrep.MSVC sharkdp.fd OpenJS.NodeJS.LTS
```

- **LLVM** provides the `clangd` ue5.nvim uses. Its installer doesn't add itself to PATH,
  and ue5.nvim finds it in `C:\Program Files\LLVM\bin` anyway. Use this clangd rather than
  Mason's: Mason's Windows build has no zlib, can't read the compressed index, and
  re-indexes the whole project on every start.
- **ripgrep / fd** are for Telescope. **Node** is for the npm-based language servers.
- **Optional, Nerd Font:** ue5.nvim itself doesn't need one. Install it only if other
  plugins in your config show icons (neo-tree, lualine, nvim-web-devicons):
  `winget install DEVCOM.JetBrainsMonoNerdFont`. Then in Windows Terminal, go to
  *Settings → Profiles → Defaults → Appearance → Font face* and choose
  **JetBrainsMono Nerd Font Mono**.

Open a new terminal afterwards so PATH picks up the new tools.

### 3. Neovim plugins (lazy.nvim)

Add this spec. lazy.nvim downloads the plugin from GitHub:

```lua
-- lua/plugins/ue5.lua
return {
  "vigneshwaran-48/ue5.nvim",
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
    { "<leader>uh", "<cmd>UE switch<cr>",        desc = "UE: switch header/source" },
    { "<leader>ur", "<cmd>UE crash<cr>",         desc = "UE: newest crash call stack" },
    { "<leader>uR", "<cmd>UE crashes<cr>",       desc = "UE: pick a crash report" },
  },
}
```

The plugin's Lua module is `ue` (`require("ue")`), and its command is `:UE`.

In your LSP setup, start clangd with ue5.nvim's command. Don't also let mason-lspconfig set
up clangd, or you get two instances:

```lua
local ok_ue, ue = pcall(require, "ue")
lspconfig.clangd.setup({ cmd = ok_ue and ue.clangd_cmd() or nil })
```

nvim-dap needs no configuration for Unreal; ue5.nvim registers its own adapter. Install
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

## Linux (untested)

> [!WARNING]
> ue5.nvim has **not been tested on Linux**. The Linux code paths are written to Epic's
> documented layout, but nobody has run them yet. Please open an issue with what works
> and what doesn't.

1. **Unreal Engine 5.** Epic has no launcher on Linux. Either download the prebuilt
   Linux engine from unrealengine.com, or build it from source
   (`./Setup.sh`, `./GenerateProjectFiles.sh`, `make`). UnrealBuildTool uses the clang
   toolchain bundled with the engine, so no separate compiler is needed to build.
2. **Tools.** Use your distro's packages, for example on Ubuntu or Debian:

   ```bash
   sudo apt install neovim clangd ripgrep fd-find nodejs npm git
   ```

   You need Neovim 0.10 or newer; if your distro's version is older, use the official
   AppImage.

   *Optional:* ue5.nvim doesn't need a Nerd Font. If other plugins in your config show
   icons, install one (for example JetBrainsMono Nerd Font from nerdfonts.com) and select
   it in your terminal.
3. **Plugin.** Use the same lazy.nvim spec, LSP line and `:MasonInstall codelldb` as in
   [Neovim plugins](#3-neovim-plugins-lazynvim) above.
4. **Engine detection.** ue5.nvim finds source builds through
   `~/.config/Epic/UnrealEngine/Install.ini`. For a prebuilt engine, or if
   `:checkhealth ue` says the engine isn't found, set it yourself:

   ```lua
   opts = { engine_path = "/home/you/UnrealEngine" }, -- the folder that contains Engine/
   ```

Builds run through Epic's `Engine/Build/BatchFiles/RunUBT.sh`, the editor is
`Engine/Binaries/Linux/UnrealEditor`, and debugging uses codelldb with Unreal's
`UEDataFormatters.py`.

**Not available on Linux:**
- The Visual Studio-only features: `:UE vsdebug` and Live Coding.
- The shared-PCH fix for false "missing include" errors. It's built for MSVC command
  lines, so on Linux clangd may show some missing includes that the real build hides.

## macOS (untested)

> [!WARNING]
> ue5.nvim has **not been tested on macOS**. The macOS code paths are written to Epic's
> documented layout, but nobody has run them yet. Please open an issue with what works
> and what doesn't.

1. **Unreal Engine 5** from the Epic Games Launcher, and **Xcode** (from the App Store)
   with its command-line tools: `xcode-select --install`. UnrealBuildTool builds with
   Xcode's clang.
2. **Tools** with Homebrew:

   ```bash
   brew install neovim llvm ripgrep fd node git
   ```

   Homebrew's `llvm` provides `clangd`; ue5.nvim finds it in `/opt/homebrew/opt/llvm/bin`.

   *Optional:* ue5.nvim doesn't need a Nerd Font. If other plugins in your config show
   icons, run `brew install --cask font-jetbrains-mono-nerd-font` and select it in your
   terminal.
3. **Plugin.** Use the same lazy.nvim spec, LSP line and `:MasonInstall codelldb` as in
   [Neovim plugins](#3-neovim-plugins-lazynvim) above.
4. **Engine detection.** ue5.nvim reads the launcher's list in
   `~/Library/Application Support/Epic/UnrealEngineLauncher/LauncherInstalled.dat`, and
   source builds from `~/Library/Application Support/Epic/UnrealEngine/Install.ini`. It
   also checks `/Users/Shared/Epic Games/UE_5.x`. If `:checkhealth ue` still can't find the
   engine, set `engine_path` as on Linux.

The editor is started from `UnrealEditor.app`, and builds run through `RunUBT.sh`.

**Not available on macOS:**
- The Visual Studio-only features: `:UE vsdebug` and Live Coding.
- The shared-PCH fix for false "missing include" errors. It's built for MSVC command
  lines, so on macOS clangd may show some missing includes that the real build hides.

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
| `:UE switch` | Switch between header and source: the same folder, Unreal's `Public/` ↔ `Private/` layout, then the whole module. Asks clangd only if none of those has a match (clangd's own guess from a UE header is often `ObjectMacros.h`) |
| `:UE crash` | Put the newest crash report's call stack (from `Saved/Crashes`) in the quickfix list, and jump to the first frame in your own code |
| `:UE crashes` | Pick a crash report from the list (time, crash type and message), then do the same |
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
