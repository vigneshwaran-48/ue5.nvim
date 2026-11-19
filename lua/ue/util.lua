local M = {}

M.is_win = vim.fn.has("win32") == 1

function M.notify(msg, level)
  vim.notify(msg, level or vim.log.levels.INFO, { title = "ue.nvim" })
end

function M.norm(p)
  return p and vim.fs.normalize(p) or nil
end

function M.exists(p)
  return p ~= nil and vim.uv.fs_stat(p) ~= nil
end

function M.read_file(p)
  local fd = io.open(p, "rb")
  if not fd then return nil end
  local data = fd:read("*a")
  fd:close()
  -- Strip a UTF-8 BOM, which some Epic files carry.
  if data:sub(1, 3) == "\239\187\191" then data = data:sub(4) end
  return data
end

function M.write_file(p, data)
  vim.fn.mkdir(vim.fs.dirname(p), "p")
  local fd = assert(io.open(p, "wb"))
  fd:write(data)
  fd:close()
end

function M.read_json(p)
  local data = M.read_file(p)
  if not data then return nil end
  local ok, decoded = pcall(vim.json.decode, data)
  return ok and decoded or nil
end

--- Platform name UBT uses for the host.
function M.host_platform()
  if M.is_win then return "Win64" end
  if vim.fn.has("mac") == 1 then return "Mac" end
  return "Linux"
end

function M.exe(name)
  return M.is_win and (name .. ".exe") or name
end

--- clangd to use. On Windows the official LLVM install comes first: Mason's Windows
--- clangd is built without zlib, so it cannot read index shards that a zlib-enabled
--- clangd compressed, and it re-indexes the whole project on every start. Always using
--- one binary keeps the on-disk index (.cache/clangd) reusable.
function M.find_clangd()
  if M.is_win then
    local llvm = (os.getenv("ProgramFiles") or "C:/Program Files") .. "/LLVM/bin/clangd.exe"
    if M.exists(llvm) then return M.norm(llvm) end
  end
  local p = vim.fn.exepath("clangd")
  if p ~= "" then return p end
  local mason = vim.fn.stdpath("data") .. "/mason/bin/clangd" .. (M.is_win and ".cmd" or "")
  if M.exists(mason) then return mason end
  for _, c in ipairs({ "/usr/bin/clangd", "/usr/local/bin/clangd", "/opt/homebrew/opt/llvm/bin/clangd" }) do
    if M.exists(c) then return c end
  end
end

return M
