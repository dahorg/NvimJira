-- Jira REST client built on curl. Every function takes an optional callback
-- `cb(data, err)`; without one the call is synchronous and returns data, err.

local config = require("jira.config")
local adf = require("jira.adf")

local M = {}

local ISSUE_FIELDS =
  "summary,status,issuetype,priority,assignee,reporter,created,updated,description,comment,labels,parent,project"
local SEARCH_FIELDS = "summary,status,issuetype,assignee,priority,updated"

local function urlencode(s)
  return (tostring(s):gsub("[^%w%-_%.~]", function(c)
    return string.format("%%%02X", c:byte())
  end))
end
M.urlencode = urlencode

local function query_string(params)
  local parts = {}
  for k, v in pairs(params or {}) do
    parts[#parts + 1] = urlencode(k) .. "=" .. urlencode(v)
  end
  table.sort(parts)
  return #parts > 0 and ("?" .. table.concat(parts, "&")) or ""
end

local function format_error(status, data)
  local msgs = {}
  if type(data) == "table" then
    for _, m in ipairs(data.errorMessages or {}) do
      msgs[#msgs + 1] = m
    end
    for field, m in pairs(data.errors or {}) do
      msgs[#msgs + 1] = field .. ": " .. tostring(m)
    end
    if data.message then
      msgs[#msgs + 1] = data.message
    end
  elseif type(data) == "string" and data ~= "" then
    msgs[#msgs + 1] = data:sub(1, 300)
  end
  local prefix = status and ("HTTP " .. status) or "Request failed"
  return #msgs > 0 and (prefix .. ": " .. table.concat(msgs, "; ")) or prefix
end

local function parse(res)
  if res.code ~= 0 then
    return nil, "curl failed: " .. vim.trim(res.stderr or "")
  end
  local body, status = (res.stdout or ""):match("^(.*)\n(%d%d%d)$")
  status = tonumber(status)
  local data
  if body and body ~= "" then
    local ok, decoded = pcall(vim.json.decode, body, { luanil = { object = true, array = true } })
    data = ok and decoded or body
  end
  if not status or status >= 400 then
    return nil, format_error(status, data)
  end
  return data or {}
end

--- Perform a request. opts: { query = {...}, body = table }
function M.request(method, path, opts, cb)
  opts = opts or {}
  local cfg, err = config.get()
  if not cfg then
    if cb then
      vim.schedule(function()
        cb(nil, err)
      end)
      return
    end
    return nil, err
  end

  local auth = cfg.cloud and ("Basic " .. vim.base64.encode(cfg.email .. ":" .. cfg.token))
    or ("Bearer " .. cfg.token)
  -- Auth is passed through a curl config on stdin so the token never shows up in `ps`.
  local stdin = string.format('header = "Authorization: %s"\n', (auth:gsub('["\\]', "\\%0")))

  local cmd = {
    "curl", "-sS", "--max-time", "30",
    "-X", method,
    "-K", "-",
    "-H", "Accept: application/json",
    "-w", "\n%{http_code}",
  }
  local tmp
  if opts.body then
    tmp = vim.fn.tempname()
    local f = assert(io.open(tmp, "w"))
    f:write(vim.json.encode(opts.body))
    f:close()
    vim.list_extend(cmd, { "-H", "Content-Type: application/json", "--data-binary", "@" .. tmp })
  end
  cmd[#cmd + 1] = cfg.url .. path .. query_string(opts.query)

  local function done(res)
    if tmp then
      os.remove(tmp)
    end
    return parse(res)
  end

  if cb then
    vim.system(cmd, { text = true, stdin = stdin }, function(res)
      local data, perr = done(res)
      vim.schedule(function()
        cb(data, perr)
      end)
    end)
  else
    return done(vim.system(cmd, { text = true, stdin = stdin }):wait())
  end
end

local function base()
  return "/rest/api/" .. config.options().api_version
end

local function uses_adf()
  return config.options().api_version == "3"
end

--- Convert an API rich-text value (ADF table or wiki string) to text.
function M.body_text(value)
  if type(value) == "table" then
    return adf.to_text(value)
  end
  return value or ""
end

--- Convert user text to the body format the API expects.
function M.to_body(text)
  return uses_adf() and adf.from_text(text) or text
end

function M.browse_url(key)
  return (config.options().url or "") .. "/browse/" .. key
end

function M.myself(cb)
  return M.request("GET", base() .. "/myself", nil, cb)
end

function M.get_issue(key, cb)
  return M.request("GET", base() .. "/issue/" .. urlencode(key), { query = { fields = ISSUE_FIELDS } }, cb)
end

function M.search(jql, max, cb)
  local cfg = config.options()
  -- Jira Cloud replaced /search with /search/jql.
  local path = base() .. (cfg.cloud and "/search/jql" or "/search")
  return M.request("GET", path, {
    query = { jql = jql, fields = SEARCH_FIELDS, maxResults = max or cfg.max_results },
  }, cb)
end

--- fields: { project, summary, type?, description?, labels? (list), parent? }
function M.create_issue(f, cb)
  local fields = {
    project = { key = f.project },
    issuetype = { name = f.type or config.options().default_type },
    summary = f.summary,
  }
  if f.description and vim.trim(f.description) ~= "" then
    fields.description = M.to_body(f.description)
  end
  if f.labels and #f.labels > 0 then
    fields.labels = f.labels
  end
  if f.parent and f.parent ~= "" then
    fields.parent = { key = f.parent }
  end
  return M.request("POST", base() .. "/issue", { body = { fields = fields } }, cb)
end

function M.add_comment(key, text, cb)
  return M.request("POST", base() .. "/issue/" .. urlencode(key) .. "/comment", {
    body = { body = M.to_body(text) },
  }, cb)
end

function M.transitions(key, cb)
  return M.request("GET", base() .. "/issue/" .. urlencode(key) .. "/transitions", nil, cb)
end

function M.do_transition(key, id, cb)
  return M.request("POST", base() .. "/issue/" .. urlencode(key) .. "/transitions", {
    body = { transition = { id = id } },
  }, cb)
end

return M
