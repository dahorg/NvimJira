# nvimjira

A small Neovim plugin for Jira: read issues, search with JQL, create issues, comment and transition. Everything is also available as a `jira` CLI (built on the same Lua code), so scripts and AI agents like Claude Code can use it too.

Requires Neovim 0.10+ and `curl`. Works with Jira Cloud (API v3) and Jira Server/Data Center (API v2).

## Install

### lazy.nvim

Create `~/.config/nvim/lua/plugins/jira.lua`:

```lua
return {
  "dahorg/NvimJira",
  main = "jira",
  cmd = "Jira",
  keys = {
    { "<leader>jm", "<cmd>Jira mine<cr>", desc = "Jira: my issues" },
    { "<leader>jv", "<cmd>Jira view<cr>", desc = "Jira: view issue under cursor" },
    { "<leader>js", ":Jira search ", desc = "Jira: search (JQL)" },
    { "<leader>jc", "<cmd>Jira create<cr>", desc = "Jira: create issue" },
  },
  opts = {
    -- All optional. Leave out anything you set through JIRA_* env vars.
    -- url = "https://yourcompany.atlassian.net",
    -- email = "you@company.com",
    -- token_cmd = "pass show jira",
    -- default_project = "ABC",
    -- open_cmd = "vsplit",
  },
}
```

To work on a local checkout, replace `"dahorg/NvimJira"` with `dir = "~/dev/nvimjira"`.

lazy.nvim calls `require("jira").setup(opts)` for you. `setup()` is optional, and every option can also come from environment variables.

To get the `jira` CLI from the lazy install, link it onto your PATH:

```sh
ln -s ~/.local/share/nvim/lazy/NvimJira/bin/jira ~/.local/bin/jira
```

## Authentication

Jira Cloud: create an API token at <https://id.atlassian.com/manage-profile/security/api-tokens>, then:

```sh
export JIRA_URL=https://yourcompany.atlassian.net
export JIRA_EMAIL=you@company.com
export JIRA_API_TOKEN=...            # or: export JIRA_API_TOKEN_CMD="pass show jira"
export JIRA_PROJECT=ABC              # optional default project for create
```

Jira Server/Data Center: set `JIRA_URL` and put a personal access token in `JIRA_API_TOKEN`. Leave `JIRA_EMAIL` unset, which switches the plugin to Bearer auth and API v2.

You can also put these in `~/.config/nvimjira/config.json` (keys: `url`, `email`, `token`, `token_cmd`, `api_version`, `default_project`) or pass them to `setup()`. The precedence is `setup()`, then env vars, then the config file.

The token reaches curl through stdin, so it never appears in the process list.

## Neovim usage

| Command | Action |
|---|---|
| `:Jira` / `:Jira mine` | Unresolved issues assigned to you |
| `:Jira ABC-123` / `:Jira view [KEY]` | Open an issue (with no KEY, uses the key under the cursor) |
| `:Jira search <JQL>` | Search |
| `:Jira create [PROJECT] [TYPE]` | Open a template. Fill it in and `:w` to create the issue |
| `:Jira comment [KEY]` | Write a comment, then `:w` to post it |
| `:Jira transition [KEY]` | Pick a status transition |
| `:Jira open [KEY]` | Open the issue in a browser |
| `:Jira whoami` | Check that authentication works |

Issue buffer keys: `r` refresh, `c` comment, `t` transition, `o` open in browser, `<CR>` open the key under the cursor, `q` close.
Search buffer keys: `<CR>` open issue, `r` refresh, `q` close.

Descriptions and comments accept light markdown: paragraphs, `-` and `1.` lists, `#` headings, fenced code blocks, `` `code` ``, `**bold**`, `[text](url)` and bare URLs. On Cloud this is converted to Atlassian Document Format.

Options (defaults):

```lua
require("jira").setup({
  url = nil, email = nil, token = nil, token_cmd = nil,
  api_version = nil,       -- "3" if email is set, otherwise "2"
  default_project = nil,
  default_type = "Task",
  max_results = 50,
  open_cmd = "vsplit",     -- how issue and search buffers are opened
})
```

## CLI (for scripts and AI agents)

```sh
ln -s ~/dev/nvimjira/bin/jira ~/.local/bin/jira
jira help
jira view ABC-123
jira search 'project = ABC AND updated >= -7d'
jira create --project ABC --summary "Title" --description-file - < desc.md
jira comment ABC-123 "Looks good"
jira transition ABC-123 "Done"
```

Add `--json` to any command for the raw API response.

### Claude Code

`skills/jira/SKILL.md` teaches Claude Code how to use the CLI. To enable it:

```sh
ln -s ~/dev/nvimjira/skills/jira ~/.claude/skills/jira
```

Make sure the `JIRA_*` variables are exported in the shell Claude Code runs in, or use the config file.

## lazygit: Jira-linked commits

`bin/lazygit-jira` starts [lazygit](https://github.com/jesseduffield/lazygit) with one change: `c` in the files panel asks for a ticket, a commit type and a summary, then commits as e.g. `fix(#PL-250): handle Safari's cookie quirk`.

```sh
ln -s ~/dev/nvimjira/bin/lazygit-jira ~/.local/bin/lazygit-jira
alias lg=lazygit-jira
```

1. **Ticket:** your tickets whose status is in Jira's *In Progress* category (e.g. In Progress, Waiting, In Review), plus "(no ticket)". If the Jira lookup fails, the error is shown on the "(no ticket)" line.
2. **Commit type:** `fix`, `feat`, `chore`, `refactor`, `docs`, `test`, `perf`, `build`, `ci` or `style`.
3. **Summary.** With "(no ticket)" the message is just `fix: summary`.

The wrapper uses the same credentials as the plugin and CLI (see [Authentication](#authentication)), so lazygit needs to start from a shell that has the `JIRA_*` variables, or you can use the config file.
Run `lazygit-jira --check` to check that authentication and the ticket query work from your current shell.

lazygit itself is not modified. The wrapper sets `LG_CONFIG_FILE` to your normal lazygit config plus `lazygit/jira-commit.yml`, which adds a custom command on `c`. Edit that file to change the commit types or the message format.

| Variable           | Default                                                                                   | Purpose                     |
| ------------------ | ----------------------------------------------------------------------------------------- | --------------------------- |
| `LAZYGIT_JIRA_JQL` | `assignee = currentUser() AND statusCategory = "In Progress" ORDER BY updated DESC`       | Which tickets are listed    |
| `LAZYGIT_BIN`      | `lazygit`                                                                                 | lazygit binary to run       |
| `LG_CONFIG_FILE`   | `~/.config/lazygit/config.yml` (if it exists)                                             | Base config(s) to layer on  |

Notes:

- `c` no longer opens lazygit's built-in commit panel. `C` (commit with your git editor) still works.
- lazygit replaces lists when merging config files, so `customCommands` in your own config are replaced by those in `jira-commit.yml`. Copy them into `jira-commit.yml` to keep them.
- Don't name the symlink `lazygit` unless `LAZYGIT_BIN` points at the real binary, or the wrapper will call itself.

### Inside Neovim (lazygit.nvim)

[lazygit.nvim](https://github.com/kdheepak/lazygit.nvim) always runs plain `lazygit`, so it skips the wrapper. Have it load the same config files, and put `lazygit-jira-tickets` on your `PATH` because lazygit calls it to list tickets:

```sh
ln -s ~/dev/nvimjira/bin/lazygit-jira-tickets ~/.local/bin/lazygit-jira-tickets
```

```lua
{
  "kdheepak/lazygit.nvim",
  init = function()
    vim.g.lazygit_use_custom_config_file_path = 1
    vim.g.lazygit_config_file_path = {
      vim.fn.expand("~/.config/lazygit/config.yml"), -- drop this line if you have no config.yml
      vim.fn.expand("~/dev/nvimjira/lazygit/jira-commit.yml"),
    }
  end,
}
```

Restart Neovim after changing this. Neovim also needs the `JIRA_*` variables (or the config file) for the ticket lookup to work.

### Tests

```sh
test/lazygit_jira_test.sh          # offline, against a fake Jira server
test/lazygit_jira_test.sh --live   # also checks your real credentials
```

The offline tests run the real `jira` CLI against `test/fake_jira.py`, which only accepts the expected Basic auth header. They cover the ticket list, the auth sources (env vars, `JIRA_API_TOKEN_CMD` and the config file), error handling and the environment lazygit is started with. They also drive a real lazygit in tmux to check the commit messages; that part is skipped if `tmux` or `lazygit` is missing. Requires `python3`.
