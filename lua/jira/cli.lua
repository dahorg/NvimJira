-- Command-line entry point, run via `nvim -l` (see bin/jira).
-- Designed for scripts and AI agents: plain-text output on stdout, errors on stderr, exit code 1 on failure.

local root = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h:h")
vim.opt.rtp:prepend(root)

local api = require("jira.api")
local config = require("jira.config")
local format = require("jira.format")

local USAGE = [[
Usage: jira <command> [args] [--json]

  whoami                               Show the authenticated user
  view KEY                             Show an issue with description and comments
  search "JQL" [--max N]               Search issues with JQL
  mine                                 Unresolved issues assigned to me
  create --project KEY --summary TEXT  Create an issue, prints the new key
         [--type Task] [--description TEXT | --description-file FILE|-]
         [--labels a,b] [--parent KEY]
  comment KEY [TEXT | -]               Add a comment (reads stdin if TEXT is - or omitted)
  transition KEY [NAME]                List transitions, or move the issue to NAME

  --json prints the raw API response instead of formatted text.
  Descriptions and comments accept light markdown (paragraphs, - lists, 1. lists,
  # headings, ``` code blocks, `code`, **bold**, [text](url)).

Config: JIRA_URL, JIRA_EMAIL, JIRA_API_TOKEN (or JIRA_API_TOKEN_CMD), JIRA_PROJECT
]]

local function out(s)
  io.stdout:write(s, "\n")
end

local function die(msg)
  io.stderr:write("jira: ", msg, "\n")
  os.exit(1)
end

local function check(data, err)
  if err then
    die(err)
  end
  return data
end

local function parse_args(argv)
  local pos, flags = {}, {}
  local i = 1
  while i <= #argv do
    local a = argv[i]
    local k, v = a:match("^%-%-([%w-]+)=(.*)$")
    if k then
      flags[k] = v
    elseif a:match("^%-%-[%w-]+$") then
      k = a:sub(3)
      if k == "json" or k == "help" then
        flags[k] = true
      else
        flags[k] = argv[i + 1]
        i = i + 1
      end
    elseif a == "-h" then
      flags.help = true
    else
      pos[#pos + 1] = a
    end
    i = i + 1
  end
  return pos, flags
end

local function read_file(path)
  if path == "-" then
    return io.stdin:read("*a")
  end
  local f = io.open(path, "r") or die("cannot read " .. path)
  local s = f:read("*a")
  f:close()
  return s
end

local function need_key(k)
  return (k and k:upper():match("^%u[%u%d_]*%-%d+$")) or die("expected an issue key like ABC-123")
end

local commands = {}

function commands.whoami(_, flags)
  local me = check(api.myself())
  if flags.json then
    return out(vim.json.encode(me))
  end
  out(("%s <%s>"):format(me.displayName or "?", me.emailAddress or "?"))
end

function commands.view(pos, flags)
  local issue = check(api.get_issue(need_key(pos[1])))
  if flags.json then
    return out(vim.json.encode(issue))
  end
  out(table.concat(format.issue(issue), "\n"))
end

function commands.search(pos, flags)
  local jql = table.concat(pos, " ")
  if jql == "" then
    die('usage: jira search "JQL"')
  end
  local res = check(api.search(jql, tonumber(flags.max)))
  if flags.json then
    return out(vim.json.encode(res))
  end
  out(table.concat(format.search(res), "\n"))
end

function commands.mine(_, flags)
  commands.search({ "assignee = currentUser() AND resolution = Unresolved ORDER BY updated DESC" }, flags)
end

function commands.create(_, flags)
  local project = flags.project or config.options().default_project
  if not project or not flags.summary then
    die("create requires --project (or JIRA_PROJECT) and --summary")
  end
  local desc = flags.description
  if flags["description-file"] then
    desc = read_file(flags["description-file"])
  end
  local labels = {}
  for l in (flags.labels or ""):gmatch("[^,%s]+") do
    labels[#labels + 1] = l
  end
  local res = check(api.create_issue({
    project = project:upper(),
    summary = flags.summary,
    type = flags.type,
    description = desc,
    labels = labels,
    parent = flags.parent and flags.parent:upper(),
  }))
  if flags.json then
    return out(vim.json.encode(res))
  end
  out(res.key .. " " .. api.browse_url(res.key))
end

function commands.comment(pos, flags)
  local key = need_key(pos[1])
  local text = table.concat(vim.list_slice(pos, 2), " ")
  if text == "" or text == "-" then
    text = io.stdin:read("*a")
  end
  if vim.trim(text) == "" then
    die("empty comment")
  end
  local res = check(api.add_comment(key, text))
  if flags.json then
    return out(vim.json.encode(res))
  end
  out("Comment added to " .. key)
end

function commands.transition(pos, flags)
  local key = need_key(pos[1])
  local wanted = table.concat(vim.list_slice(pos, 2), " "):lower()
  local list = check(api.transitions(key)).transitions or {}
  if wanted == "" then
    if flags.json then
      return out(vim.json.encode(list))
    end
    for _, t in ipairs(list) do
      out(("%s -> %s"):format(t.name, t.to and t.to.name or "?"))
    end
    return
  end
  for _, t in ipairs(list) do
    if t.name:lower() == wanted or (t.to and t.to.name:lower() == wanted) then
      check(api.do_transition(key, t.id))
      return out(("%s -> %s"):format(key, t.to and t.to.name or t.name))
    end
  end
  local names = vim.tbl_map(function(t) return t.name end, list)
  die(("no transition '%s' for %s (available: %s)"):format(wanted, key, table.concat(names, ", ")))
end

local pos, flags = parse_args(_G.arg or {})
local cmd = table.remove(pos, 1)
if not cmd or flags.help or cmd == "help" then
  io.stdout:write(USAGE)
  os.exit(cmd and 0 or 1)
end
if not commands[cmd] then
  die("unknown command '" .. cmd .. "'\n\n" .. USAGE)
end
commands[cmd](pos, flags)
os.exit(0)
