-- Runs UBT / editor processes, streams output to a log buffer and parses errors.
local util = require("ue.util")
local config = require("ue.config")

local M = {}

local current = nil -- running vim.SystemObj
local log_buf = nil

local function get_log_buf()
  if log_buf and vim.api.nvim_buf_is_valid(log_buf) then return log_buf end
  log_buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_name(log_buf, "ue://log")
  vim.bo[log_buf].buftype = "nofile"
  vim.bo[log_buf].bufhidden = "hide"
  vim.bo[log_buf].swapfile = false
  vim.bo[log_buf].filetype = "uelog"
  return log_buf
end

local function append(lines)
  local buf = get_log_buf()
  vim.bo[buf].modifiable = true
  vim.api.nvim_buf_set_lines(buf, -1, -1, false, lines)
  vim.bo[buf].modifiable = false
  for _, win in ipairs(vim.fn.win_findbuf(buf)) do
    vim.api.nvim_win_set_cursor(win, { vim.api.nvim_buf_line_count(buf), 0 })
  end
end

--- Appends lines to ue://log (e.g. notes from ue.nvim itself).
function M.log(...)
  append({ ... })
end

--- Shows ue://log in a window: reuses one already showing it (in this tab), otherwise
--- opens a split at the bottom. With focus = false the cursor stays where it was.
function M.show_log(focus)
  local buf = get_log_buf()
  local tab_wins = vim.api.nvim_tabpage_list_wins(0)
  for _, win in ipairs(vim.fn.win_findbuf(buf)) do
    if vim.tbl_contains(tab_wins, win) then
      if focus then vim.api.nvim_set_current_win(win) end
      vim.api.nvim_win_set_cursor(win, { vim.api.nvim_buf_line_count(buf), 0 })
      return win
    end
  end
  local prev = vim.api.nvim_get_current_win()
  vim.cmd("botright " .. (config.options.log_height or 15) .. "split")
  local win = vim.api.nvim_get_current_win()
  vim.api.nvim_win_set_buf(win, buf)
  vim.wo[win].wrap = false
  vim.wo[win].number = false
  vim.wo[win].relativenumber = false
  vim.wo[win].winfixheight = true
  vim.api.nvim_win_set_cursor(win, { vim.api.nvim_buf_line_count(buf), 0 })
  if not focus and vim.api.nvim_win_is_valid(prev) then vim.api.nvim_set_current_win(prev) end
  return win
end

function M.open_log() M.show_log(true) end

--- Parses MSVC / clang / UHT diagnostics into a quickfix item, or nil.
function M.parse_line(line)
  line = line:gsub("\r$", "")
  -- MSVC / UHT:  C:\p\File.cpp(12,5): error C2065: msg   |   File.h(30): Error: msg
  local file, lnum, col, kind, msg =
    line:match("^%s*(%a:[^%(]+)%((%d+),?(%d*)%)%s*:%s*(%a+)[^:]*:%s*(.*)$")
  if not file then
    file, lnum, col, kind, msg = line:match("^%s*(/[^%(]+)%((%d+),?(%d*)%)%s*:%s*(%a+)[^:]*:%s*(.*)$")
  end
  if not file then
    -- clang: /p/File.cpp:12:5: error: msg  (also C:/p/... on Windows)
    file, lnum, col, kind, msg = line:match("^%s*(%a?:?[^:]+):(%d+):(%d+):%s*(%a+):%s*(.*)$")
  end
  if not file then return nil end
  kind = kind:lower()
  local t
  if kind == "error" or kind == "fatal" then t = "E"
  elseif kind == "warning" then t = "W"
  elseif kind == "note" or kind == "info" then t = "I"
  else return nil end
  -- MSVC puts the code before the colon ("error C2065"); keep it in the message.
  local code = line:match("%)%s*:%s*%a+%s+(%u+%d+)%s*:")
  if code then msg = code .. ": " .. msg end
  return {
    filename = vim.trim(file),
    lnum = tonumber(lnum),
    col = tonumber(col) or 0,
    type = t,
    text = msg,
  }
end

function M.running() return current ~= nil end

function M.cancel()
  if current then
    current:kill(9)
    util.notify("Cancelled")
  end
end

local function fmt_cmd(cmd)
  local parts = {}
  for _, a in ipairs(cmd) do
    parts[#parts + 1] = a:find("[%s]") and ('"' .. a .. '"') or a
  end
  return table.concat(parts, " ")
end

--- Runs cmd, streaming to ue://log. on_exit(code, qf_items, lines).
---@param opts { title: string, quickfix?: boolean, append?: boolean, on_exit?: fun(code: integer, items: table, lines: string[]) }
function M.run(cmd, opts)
  if current then
    util.notify("A UE job is already running (:UE cancel to stop it)", vim.log.levels.WARN)
    return
  end
  local buf = get_log_buf()
  vim.bo[buf].modifiable = true
  if opts.append and vim.api.nvim_buf_line_count(buf) > 1 then
    -- A follow-up job (e.g. the compile database after a build) keeps the earlier output.
    vim.api.nvim_buf_set_lines(buf, -1, -1, false, { "", "$ " .. fmt_cmd(cmd), "" })
  else
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "$ " .. fmt_cmd(cmd), "" })
  end
  vim.bo[buf].modifiable = false
  if config.options.open_log then M.show_log(false) end

  local items, all, partial = {}, {}, { stdout = "", stderr = "" }
  local started = vim.uv.hrtime()

  local function feed(stream, data)
    if not data then return end
    data = partial[stream] .. data:gsub("\r\n", "\n")
    local lines = vim.split(data, "\n", { plain = true })
    partial[stream] = table.remove(lines)
    if #lines == 0 then return end
    vim.schedule(function()
      append(lines)
      for _, l in ipairs(lines) do
        all[#all + 1] = l
        if opts.quickfix ~= false then
          local item = M.parse_line(l)
          if item then items[#items + 1] = item end
        end
      end
    end)
  end

  util.notify(opts.title .. " ...")
  local ok, obj = pcall(vim.system, cmd, {
    text = true,
    stdout = function(_, d) feed("stdout", d) end,
    stderr = function(_, d) feed("stderr", d) end,
  }, function(res)
    vim.schedule(function()
      current = nil
      for _, s in ipairs({ "stdout", "stderr" }) do
        if partial[s] ~= "" then
          append({ partial[s] })
          all[#all + 1] = partial[s]
          local item = M.parse_line(partial[s])
          if item then items[#items + 1] = item end
        end
      end
      local secs = (vim.uv.hrtime() - started) / 1e9
      append({ "", ("[exit %d, %.1fs]"):format(res.code, secs) })

      if opts.quickfix ~= false then
        vim.fn.setqflist({}, "r", { title = opts.title, items = items })
      end
      local errors = 0
      for _, it in ipairs(items) do if it.type == "E" then errors = errors + 1 end end

      if res.code == 0 then
        util.notify(("%s succeeded (%.0fs)"):format(opts.title, secs))
      else
        local hint = ""
        for _, l in ipairs(all) do
          if l:find("Live Coding is active", 1, true) then
            hint = "\nLive Coding is active: close the editor or press Ctrl+Alt+F11 in it."
            break
          end
        end
        util.notify(("%s failed (exit %d, %d errors). :UE log for output.%s"):format(
          opts.title, res.code, errors, hint), vim.log.levels.ERROR)
        if errors > 0 and config.options.open_quickfix then vim.cmd("botright copen") end
      end
      if opts.on_exit then opts.on_exit(res.code, items, all) end
    end)
  end)
  if not ok then
    util.notify("Failed to start: " .. tostring(obj), vim.log.levels.ERROR)
    return
  end
  current = obj
  return obj
end

--- Starts a GUI process that outlives nvim.
function M.spawn_detached(cmd)
  local ok, err = pcall(vim.system, cmd, { detach = true })
  if not ok then util.notify("Failed to start: " .. tostring(err), vim.log.levels.ERROR) end
end

return M
