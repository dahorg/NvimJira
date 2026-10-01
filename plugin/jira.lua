if vim.g.loaded_jira then
  return
end
vim.g.loaded_jira = true

local subcommands = {
  view = function(rest, a) require("jira.ui").view(a[1]) end,
  search = function(rest) require("jira.ui").search(rest) end,
  mine = function() require("jira.ui").mine() end,
  create = function(rest, a) require("jira.ui").create(a[1], a[2]) end,
  comment = function(rest, a) require("jira.ui").comment(a[1]) end,
  transition = function(rest, a) require("jira.ui").transition(a[1]) end,
  open = function(rest, a) require("jira.ui").browse(a[1]) end,
  whoami = function() require("jira.ui").whoami() end,
}

vim.api.nvim_create_user_command("Jira", function(o)
  local sub, rest = o.args:match("^(%S+)%s*(.*)$")
  sub = sub or "mine"
  local fn = subcommands[sub]
  if not fn then
    -- `:Jira ABC-123` is shorthand for `:Jira view ABC-123`
    if sub:upper():match("^%u[%u%d_]*%-%d+$") then
      return subcommands.view("", { sub })
    end
    return vim.notify("[jira] Unknown subcommand: " .. sub, vim.log.levels.ERROR)
  end
  fn(rest or "", vim.list_slice(o.fargs, 2))
end, {
  nargs = "*",
  desc = "Jira: view/search/mine/create/comment/transition/open/whoami",
  complete = function(arglead, cmdline)
    if cmdline:match("^%S+%s+%S*$") then
      return vim.tbl_filter(function(s)
        return s:find(arglead, 1, true) == 1
      end, vim.tbl_keys(subcommands))
    end
    return {}
  end,
})
