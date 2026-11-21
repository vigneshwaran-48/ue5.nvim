-- Crash reports: Saved/Crashes/<id>/CrashContext.runtime-xml -> quickfix list.
local util = require("ue.util")

local M = {}

--- Crash report folders of the project, newest first.
function M.list(proj)
  local dir = proj.root .. "/Saved/Crashes"
  local out = {}
  if not util.exists(dir) then return out end
  for name, kind in vim.fs.dir(dir) do
    if kind == "directory" then
      local path = dir .. "/" .. name
      local st = vim.uv.fs_stat(path)
      out[#out + 1] = { path = path, name = name, mtime = st and st.mtime.sec or 0 }
    end
  end
  table.sort(out, function(a, b) return a.mtime > b.mtime end)
  return out
end

local function unescape(s)
  return (s:gsub("&lt;", "<"):gsub("&gt;", ">"):gsub("&quot;", '"'):gsub("&apos;", "'"):gsub("&amp;", "&"))
end

--- One call stack line: "Module!Function() [C:\path\File.cpp:57]", or just "Module".
local function parse_frame(line)
  line = vim.trim(line)
  if line == "" then return nil end
  local module, rest = line:match("^([^!%s]+)!(.*)$")
  if not module then return { module = line } end
  local func, file, lnum = rest:match("^(.-)%s*%[(.+):(%d+)%]%s*$")
  if not func then
    func = rest:gsub("%s*%[%]%s*$", "")
  end
  return { module = module, func = func, file = file, lnum = tonumber(lnum) }
end

--- Reads a crash folder: { type, message, frames = { {module, func, file, lnum} } }.
function M.read(dir)
  local report = { frames = {} }
  local xml = util.read_file(dir .. "/CrashContext.runtime-xml")
  if xml then
    report.type = xml:match("<CrashType>(.-)</CrashType>")
    local msg = xml:match("<ErrorMessage>(.-)</ErrorMessage>")
    report.message = msg and vim.trim(unescape(msg)) or nil
    local stack = xml:match("<CallStack>(.-)</CallStack>")
    if stack then
      for line in unescape(stack):gmatch("[^\r\n]+") do
        local f = parse_frame(line)
        if f then report.frames[#report.frames + 1] = f end
      end
    end
  end
  if #report.frames == 0 then
    -- Fallback: "[Callstack] 0x00007ff... Module.dll!Func() [C:\path\File.cpp:57]" in the log.
    for name, kind in vim.fs.dir(dir) do
      if kind == "file" and name:match("%.log$") then
        for line in (util.read_file(dir .. "/" .. name) or ""):gmatch("[^\r\n]+") do
          local rest = line:match("%[Callstack%]%s+0x%x+%s+(.*)$")
          local f = rest and parse_frame(rest)
          if f then report.frames[#report.frames + 1] = f end
        end
        break
      end
    end
  end
  return report
end

--- Fills the quickfix list with a crash's call stack and opens it. Frames with source
--- that exists on this machine are jumpable; the rest (engine code without symbols or
--- source) are listed as text so the whole stack stays readable.
function M.to_quickfix(proj, entry)
  local report = M.read(entry.path)
  if #report.frames == 0 then
    util.notify("No call stack found in " .. entry.name, vim.log.levels.WARN)
    return
  end
  local items = {}
  local first_line = vim.trim(((report.message or ""):match("^[^\r\n]*")) or "")
  local header = ("%s: %s"):format(report.type or "Crash", first_line ~= "" and first_line or "(no message)")
  items[#items + 1] = { text = header, valid = 0 }
  local first_project = nil
  for i, f in ipairs(report.frames) do
    local text = ("#%d %s%s"):format(i - 1, f.func and (f.func .. "  ") or "", "[" .. f.module .. "]")
    if f.file and util.exists(f.file) then
      items[#items + 1] = { filename = f.file, lnum = f.lnum or 1, text = text, type = "E" }
      local norm = util.norm(f.file)
      if not first_project and norm:sub(1, #proj.root):lower() == proj.root:lower() then
        first_project = #items
      end
    else
      if f.file then text = text .. "  " .. f.file .. ":" .. (f.lnum or "?") end
      items[#items + 1] = { text = text, valid = 0 }
    end
  end
  local title = ("UE crash %s (%s)"):format(os.date("%Y-%m-%d %H:%M", entry.mtime), entry.name)
  vim.fn.setqflist({}, "r", { title = title, items = items, idx = first_project or 1 })
  vim.cmd("botright copen")
  if first_project then
    -- Jump to the deepest frame in your own code: usually where to look first.
    vim.cmd("cc " .. first_project)
  end
  util.notify(("%s (%d frames)"):format(header:sub(1, 200), #report.frames))
end

--- :UE crash — newest crash report.
function M.latest(proj)
  local list = M.list(proj)
  if #list == 0 then
    util.notify("No crash reports in " .. proj.root .. "/Saved/Crashes")
    return
  end
  M.to_quickfix(proj, list[1])
end

--- :UE crashes — pick one of the crash reports.
function M.pick(proj)
  local list = M.list(proj)
  if #list == 0 then
    util.notify("No crash reports in " .. proj.root .. "/Saved/Crashes")
    return
  end
  vim.ui.select(list, {
    prompt = "Unreal crash report",
    format_item = function(e)
      local r = M.read(e.path)
      return ("%s  %-8s %s"):format(os.date("%Y-%m-%d %H:%M", e.mtime), r.type or "?",
        (r.message or ""):gsub("%s+", " "):sub(1, 100))
    end,
  }, function(e)
    if e then M.to_quickfix(proj, e) end
  end)
end

return M
