---
name: jira
description: Read, search, create, comment on and transition Jira issues via the `jira` CLI. Use when the user mentions a Jira ticket key (e.g. ABC-123), asks what's on their plate, or wants to file or update a Jira issue.
---

# Jira CLI

`jira` (from the nvimjira plugin) talks to the user's Jira. It writes plain text to stdout, errors to stderr, and exits 1 on failure. Add `--json` for the raw API response.

```bash
jira whoami                                   # check auth
jira view ABC-123                             # issue + description + comments (markdown)
jira search 'project = ABC AND status = "In Progress" ORDER BY updated DESC' --max 20
jira mine                                     # my unresolved issues
jira create --project ABC --type Task --summary "Short title" --description-file - <<'EOF'
Context paragraph.

- acceptance criterion 1
- acceptance criterion 2
EOF
jira comment ABC-123 - <<'EOF'
Comment text, light markdown supported.
EOF
jira transition ABC-123                       # list available transitions
jira transition ABC-123 "In Progress"         # move issue
```

Optional create flags: `--labels a,b`, `--parent ABC-1` (for subtasks or child issues).

## Rules

- Reading (`view`, `search`, `mine`, `transition` with no name) is safe to run freely.
- `create`, `comment` and `transition KEY NAME` change shared state that the team can see. Show the user the exact summary/description/comment first and get their confirmation, unless they already told you exactly what to post.
- Pass multi-line text through a quoted heredoc (`<<'EOF'`) so the shell doesn't expand backticks or `$`.
- If a command fails with "JIRA_URL is not set" or "No Jira token configured", tell the user to set up credentials (see the nvimjira README). Don't try to guess the values.
