local api = require("jira.api")
local config = require("jira.config")
local format = require("jira.format")

local M = {}

local KEY_PATTERN = "%u[%u%d_]*%-%d+"

local function notify(msg, level)
  vim.notify("[jira] " .. msg, level or vim.log.levels.INFO)
end

local function find_buf(name)
  for _, b in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_valid(b) and vim.api.nvim_buf_get_name(b) == name then
      return b
    end
  end
end

local function open_buf(name, opts)
  opts = opts or {}
  local buf = find_buf(name)
  if not buf then
    buf = vim.api.nvim_create_buf(true, true)
    vim.api.nvim_buf_set_name(buf, name)
    vim.bo[buf].filetype = "markdown"
    vim.bo[buf].buftype = opts.writable and "acwrite" or "nofile"
    vim.bo[buf].bufhidden = "hide"
    vim.bo[buf].swapfile = false
  end
  local win = vim.fn.bufwinid(buf)
  if win ~= -1 then
    vim.api.nvim_set_current_win(win)
  else
    vim.cmd(config.options().open_cmd)
    vim.api.nvim_win_set_buf(0, buf)
  end
  return buf
end

local function set_lines(buf, lines)
  if not vim.api.nvim_buf_is_valid(buf) then
    return
  end
  vim.bo[buf].modifiable = true
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modifiable = false
  vim.bo[buf].modified = false
end

local function map(buf, lhs, fn, desc)
  vim.keymap.set("n", lhs, fn, { buffer = buf, nowait = true, silent = true, desc = "Jira: " .. desc })
end

--- Pick an issue key from the argument, the current issue buffer, or the word under the cursor.
local function resolve_key(key)
  key = key or vim.b.jira_key or vim.fn.expand("<cWORD>")
  return key and key:upper():match(KEY_PATTERN)
end

--- Open a writable buffer; `on_write(text, buf)` runs on :w.
local function edit_buf(name, lines, on_write)
  local buf = open_buf(name, { writable = true })
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modified = false
  vim.api.nvim_clear_autocmds({ buffer = buf, event = "BufWriteCmd" })
  vim.api.nvim_create_autocmd("BufWriteCmd", {
    buffer = buf,
    callback = function()
      on_write(table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), "\n"), buf)
    end,
  })
  return buf
end

local function close_buf(buf)
  if vim.api.nvim_buf_is_valid(buf) then
    vim.api.nvim_buf_delete(buf, { force = true })
  end
end

function M.view(key)
  key = resolve_key(key)
  if not key then
    return notify("No issue key given or under cursor", vim.log.levels.WARN)
  end
  local buf = open_buf("jira://" .. key)
  vim.b[buf].jira_key = key
  set_lines(buf, { "Loading " .. key .. "..." })

  map(buf, "q", "<cmd>close<cr>", "close")
  map(buf, "r", function() M.view(key) end, "refresh")
  map(buf, "c", function() M.comment(key) end, "comment")
  map(buf, "t", function() M.transition(key) end, "transition")
  map(buf, "o", function() M.browse(key) end, "open in browser")
  map(buf, "<CR>", function()
    local k = vim.fn.expand("<cWORD>"):match(KEY_PATTERN)
    if k and k ~= key then M.view(k) end
  end, "open issue under cursor")

  api.get_issue(key, function(issue, err)
    if err then
      return set_lines(buf, { "Error loading " .. key .. ": " .. err })
    end
    set_lines(buf, format.issue(issue))
  end)
end

function M.search(jql)
  if not jql or vim.trim(jql) == "" then
    return notify("Usage: :Jira search <JQL>", vim.log.levels.WARN)
  end
  local buf = open_buf("jira://search")
  vim.b[buf].jira_key = nil
  set_lines(buf, { "Searching: " .. jql })

  map(buf, "q", "<cmd>close<cr>", "close")
  map(buf, "r", function() M.search(jql) end, "refresh")
  map(buf, "<CR>", function()
    local k = vim.api.nvim_get_current_line():match("^(" .. KEY_PATTERN .. ")")
    if k then M.view(k) end
  end, "open issue")

  api.search(jql, nil, function(res, err)
    if err then
      return set_lines(buf, { "JQL: " .. jql, "", "Error: " .. err })
    end
    local lines = { "JQL: " .. jql, "" }
    vim.list_extend(lines, format.search(res))
    set_lines(buf, lines)
  end)
end

function M.mine()
  M.search("assignee = currentUser() AND resolution = Unresolved ORDER BY updated DESC")
end

local new_count = 0

function M.create(project, issue_type)
  local cfg = config.options()
  new_count = new_count + 1
  local template = {
    "Project: " .. (project or cfg.default_project or ""),
    "Type: " .. (issue_type or cfg.default_type),
    "Summary: ",
    "Labels: ",
    "Parent: ",
    "--- Description below. :w to create, :q! to abort ---",
    "",
  }
  local buf = edit_buf("jira://new/" .. new_count, template, function(text, b)
    local header, desc = text:match("^(.-)\n%-%-%-[^\n]*\n?(.*)$")
    if not header then
      return notify("Could not find the '---' separator line", vim.log.levels.ERROR)
    end
    local f = {}
    for line in header:gmatch("[^\n]+") do
      local k, v = line:match("^(%w+):%s*(.-)%s*$")
      if k then
        f[k:lower()] = v
      end
    end
    if (f.project or "") == "" or (f.summary or "") == "" then
      return notify("Project and Summary are required", vim.log.levels.ERROR)
    end
    local labels = {}
    for l in (f.labels or ""):gmatch("[^,%s]+") do
      labels[#labels + 1] = l
    end
    notify("Creating issue...")
    api.create_issue({
      project = f.project:upper(),
      type = f.type ~= "" and f.type or nil,
      summary = f.summary,
      description = desc,
      labels = labels,
      parent = f.parent ~= "" and f.parent:upper() or nil,
    }, function(res, err)
      if err then
        return notify("Create failed: " .. err, vim.log.levels.ERROR)
      end
      notify("Created " .. res.key)
      close_buf(b)
      M.view(res.key)
    end)
  end)
  vim.api.nvim_win_set_cursor(0, { 3, 0 })
  vim.cmd("startinsert!")
  return buf
end

function M.comment(key)
  key = resolve_key(key)
  if not key then
    return notify("No issue key given or under cursor", vim.log.levels.WARN)
  end
  edit_buf("jira://" .. key .. "/comment", {}, function(text, b)
    if vim.trim(text) == "" then
      return notify("Empty comment, not posted", vim.log.levels.WARN)
    end
    api.add_comment(key, text, function(_, err)
      if err then
        return notify("Comment failed: " .. err, vim.log.levels.ERROR)
      end
      notify("Comment added to " .. key)
      close_buf(b)
      if find_buf("jira://" .. key) then
        M.view(key)
      end
    end)
  end)
  vim.cmd("startinsert")
end

function M.transition(key)
  key = resolve_key(key)
  if not key then
    return notify("No issue key given or under cursor", vim.log.levels.WARN)
  end
  api.transitions(key, function(res, err)
    if err then
      return notify("Could not load transitions: " .. err, vim.log.levels.ERROR)
    end
    vim.ui.select(res.transitions or {}, {
      prompt = "Transition " .. key .. " to:",
      format_item = function(t)
        return t.name .. ((t.to and t.to.name ~= t.name) and (" -> " .. t.to.name) or "")
      end,
    }, function(choice)
      if not choice then
        return
      end
      api.do_transition(key, choice.id, function(_, terr)
        if terr then
          return notify("Transition failed: " .. terr, vim.log.levels.ERROR)
        end
        notify(key .. " -> " .. choice.name)
        if find_buf("jira://" .. key) then
          M.view(key)
        end
      end)
    end)
  end)
end

function M.browse(key)
  key = resolve_key(key)
  if not key then
    return notify("No issue key given or under cursor", vim.log.levels.WARN)
  end
  vim.ui.open(api.browse_url(key))
end

function M.whoami()
  api.myself(function(me, err)
    if err then
      return notify(err, vim.log.levels.ERROR)
    end
    notify(("Logged in as %s <%s>"):format(me.displayName or "?", me.emailAddress or "?"))
  end)
end

return M
