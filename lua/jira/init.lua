local M = {}

--- Optional. See lua/jira/config.lua for options; env vars work without calling this.
function M.setup(opts)
  require("jira.config").setup(opts)
end

M.api = setmetatable({}, { __index = function(_, k) return require("jira.api")[k] end })

for _, fn in ipairs({ "view", "search", "mine", "create", "comment", "transition", "browse", "whoami" }) do
  M[fn] = function(...)
    return require("jira.ui")[fn](...)
  end
end

return M
