-- Configuration resolution. Precedence (highest first):
--   require("jira").setup({...})  >  environment variables  >  config file  >  defaults
--
-- Environment variables:
--   JIRA_URL            https://yourcompany.atlassian.net
--   JIRA_EMAIL          your Atlassian account email (Cloud only; omit for Server/DC PAT auth)
--   JIRA_API_TOKEN      API token (Cloud) or personal access token (Server/DC)
--   JIRA_API_TOKEN_CMD  shell command that prints the token, e.g. "pass show jira"
--   JIRA_API_VERSION    "3" (Cloud default) or "2" (Server/DC default)
--   JIRA_PROJECT        default project key for create
--
-- Config file: $XDG_CONFIG_HOME/nvimjira/config.json (same keys as setup(), lowercase)

local M = {}

local defaults = {
  url = nil,
  email = nil,
  token = nil,
  token_cmd = nil,
  api_version = nil,
  default_project = nil,
  default_type = "Task",
  max_results = 50,
  open_cmd = "vsplit",
}

local user_opts = {}
local file_cache
local token_cache

local function file_config()
  if file_cache then
    return file_cache
  end
  local dir = vim.env.XDG_CONFIG_HOME or ((vim.env.HOME or "") .. "/.config")
  local f = io.open(dir .. "/nvimjira/config.json", "r")
  file_cache = {}
  if f then
    local ok, data = pcall(vim.json.decode, f:read("*a"))
    f:close()
    if ok and type(data) == "table" then
      file_cache = data
    end
  end
  return file_cache
end

local function env_config()
  local function e(name)
    local v = vim.env[name]
    return (v and v ~= "") and v or nil
  end
  return {
    url = e("JIRA_URL"),
    email = e("JIRA_EMAIL"),
    token = e("JIRA_API_TOKEN"),
    token_cmd = e("JIRA_API_TOKEN_CMD"),
    api_version = e("JIRA_API_VERSION"),
    default_project = e("JIRA_PROJECT"),
  }
end

function M.setup(opts)
  user_opts = opts or {}
  token_cache = nil
end

--- Resolved options without validation (safe for UI settings).
function M.options()
  local cfg = vim.tbl_extend("force", defaults, file_config(), env_config(), user_opts)
  if cfg.url then
    cfg.url = cfg.url:gsub("/+$", "")
  end
  cfg.cloud = cfg.email ~= nil and cfg.email ~= ""
  cfg.api_version = tostring(cfg.api_version or (cfg.cloud and "3" or "2"))
  return cfg
end

--- Resolved and validated options, including the token. Returns cfg, err.
function M.get()
  local cfg = M.options()
  if not cfg.url then
    return nil, "JIRA_URL is not set"
  end
  if (not cfg.token or cfg.token == "") and cfg.token_cmd then
    if not token_cache then
      local r = vim.system({ "sh", "-c", cfg.token_cmd }, { text = true }):wait()
      if r.code ~= 0 then
        return nil, "token_cmd failed: " .. vim.trim(r.stderr or "")
      end
      token_cache = vim.trim(r.stdout or "")
    end
    cfg.token = token_cache
  end
  if not cfg.token or cfg.token == "" then
    return nil, "No Jira token configured (set JIRA_API_TOKEN or JIRA_API_TOKEN_CMD)"
  end
  return cfg
end

return M
