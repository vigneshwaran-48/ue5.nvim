-- Editing helpers: switch between a header and its source file.
local util = require("ue.util")

local M = {}

local HEADER_EXT = { "h", "hpp", "hh", "hxx", "inl" }
local SOURCE_EXT = { "cpp", "cc", "cxx", "c" }

local function is_header(ext) return vim.tbl_contains(HEADER_EXT, ext) end

--- Unreal's layout: Module/Public/Foo/Bar.h <-> Module/Private/Foo/Bar.cpp (also Classes/).
local function mirrored_dirs(dir, to_header)
  local out = {}
  local swaps = to_header and { { "Private", "Public" }, { "Private", "Classes" } }
    or { { "Public", "Private" }, { "Classes", "Private" } }
  for _, s in ipairs(swaps) do
    local from, to = "/" .. s[1], "/" .. s[2]
    -- ".../Public/Sub/Dir" -> ".../Private/Sub/Dir"
    local i = dir:find(from .. "/", 1, true)
    if i then
      out[#out + 1] = dir:sub(1, i - 1) .. to .. dir:sub(i + #from)
    elseif dir:sub(-#from) == from then
      -- ".../Public" -> ".../Private"
      out[#out + 1] = dir:sub(1, -#from - 1) .. to
    end
  end
  return out
end

--- Finds the counterpart of `file` without clangd: same folder, the mirrored
--- Public/Private folder, then anywhere in the module (the folder with *.Build.cs).
function M.find_counterpart(file)
  file = util.norm(file)
  local dir, base = vim.fs.dirname(file), vim.fn.fnamemodify(file, ":t:r")
  local ext = vim.fn.fnamemodify(file, ":e"):lower()
  local to_header = not is_header(ext)
  local exts = to_header and HEADER_EXT or SOURCE_EXT
  local names = vim.tbl_map(function(e) return base .. "." .. e end, exts)

  local dirs = { dir }
  vim.list_extend(dirs, mirrored_dirs(dir, to_header))
  for _, d in ipairs(dirs) do
    for _, n in ipairs(names) do
      if util.exists(d .. "/" .. n) then return d .. "/" .. n end
    end
  end

  local root = vim.fs.root(file, function(n) return n:match("%.Build%.cs$") ~= nil end) or dir
  local found = vim.fs.find(names, { path = root, type = "file", limit = 1 })[1]
  return found and util.norm(found) or nil
end

local function open(path)
  vim.cmd.edit(vim.fn.fnameescape(path))
end

--- :UE switch — asks clangd first (it knows the include graph), falls back to the
--- Unreal folder layout when clangd isn't attached or has no answer.
function M.switch()
  local file = vim.api.nvim_buf_get_name(0)
  if file == "" then return end
  local function fallback()
    local other = M.find_counterpart(file)
    if other then open(other)
    else util.notify("No matching header/source for " .. vim.fn.fnamemodify(file, ":t"), vim.log.levels.WARN) end
  end
  local client = vim.lsp.get_clients({ bufnr = 0, name = "clangd" })[1]
  if not client then return fallback() end
  local params = vim.lsp.util.make_text_document_params(0)
  client:request("textDocument/switchSourceHeader", params, function(err, uri)
    if err or not uri or uri == vim.NIL or uri == "" then return fallback() end
    open(vim.uri_to_fname(uri))
  end, 0)
end

return M
