-- Render API responses as text lines (shared by the Neovim UI and the CLI).

local api = require("jira.api")

local M = {}

local function name(x, fallback)
  return x and (x.displayName or x.name) or fallback or "-"
end

local function date(s)
  return s and (s:sub(1, 16):gsub("T", " ")) or "-"
end

local function add_text(lines, s)
  for _, l in ipairs(vim.split(s or "", "\n", { plain = true })) do
    lines[#lines + 1] = l
  end
end

function M.issue(issue)
  local f = issue.fields or {}
  local lines = {}
  local function add(s)
    add_text(lines, s)
  end

  add(("# %s: %s"):format(issue.key, f.summary or ""))
  add("")
  add("- Type:     " .. name(f.issuetype))
  add("- Status:   " .. name(f.status))
  add("- Priority: " .. name(f.priority))
  add("- Assignee: " .. name(f.assignee, "Unassigned"))
  add("- Reporter: " .. name(f.reporter))
  if f.parent then
    add("- Parent:   " .. f.parent.key .. " " .. ((f.parent.fields or {}).summary or ""))
  end
  if f.labels and #f.labels > 0 then
    add("- Labels:   " .. table.concat(f.labels, ", "))
  end
  add("- Created:  " .. date(f.created))
  add("- Updated:  " .. date(f.updated))
  add("- URL:      " .. api.browse_url(issue.key))
  add("")
  add("## Description")
  add("")
  local desc = vim.trim(api.body_text(f.description))
  add(desc ~= "" and desc or "_No description_")

  local comments = (f.comment and f.comment.comments) or {}
  add("")
  add(("## Comments (%d)"):format((f.comment and f.comment.total) or #comments))
  for _, c in ipairs(comments) do
    add("")
    add(("### %s - %s"):format(name(c.author), date(c.created)))
    add("")
    add(vim.trim(api.body_text(c.body)))
  end
  return lines
end

-- Pad by display width so emoji and non-ASCII status names line up.
local function pad(s, width)
  return s .. string.rep(" ", math.max(1, width - vim.fn.strdisplaywidth(s)))
end

function M.search_line(issue)
  local f = issue.fields or {}
  return ("%s%s%s%s  (%s)"):format(
    pad(issue.key, 13),
    pad("[" .. name(f.status) .. "]", 16),
    pad(name(f.issuetype), 11),
    f.summary or "",
    name(f.assignee, "Unassigned")
  )
end

function M.search(result)
  local lines = {}
  for _, issue in ipairs(result.issues or {}) do
    lines[#lines + 1] = M.search_line(issue)
  end
  if #lines == 0 then
    lines[1] = "No issues found."
  end
  return lines
end

return M
