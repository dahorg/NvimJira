#!/bin/sh
# Tests for bin/lazygit-jira and bin/lazygit-jira-tickets.
#
#   test/lazygit_jira_test.sh          offline tests against a fake Jira server
#   test/lazygit_jira_test.sh --live   also check your real Jira credentials
#                                      (uses the JIRA_* variables in your shell)
#
# The end-to-end test drives a real lazygit in tmux and is skipped if either
# is missing.
set -u
ROOT=$(dirname "$(dirname "$(readlink -f "$0")")")
BIN=$ROOT/bin

pass=0
fail=0
skip=0
ok() { pass=$((pass + 1)); echo "ok   - $1"; }
not_ok() { fail=$((fail + 1)); echo "FAIL - $1"; [ $# -gt 1 ] && printf '%s\n' "$2" | sed 's/^/       /'; }
skipped() { skip=$((skip + 1)); echo "skip - $1"; }

# --- live: your real credentials, exactly as lazygit-jira would see them ----

if [ "${1:-}" = "--live" ]; then
  if out=$("$BIN/lazygit-jira" --check 2>&1); then
    ok "live: authenticated and listed tickets"
    printf '%s\n' "$out" | sed 's/^/       /'
  else
    not_ok "live: authenticated and listed tickets (run secrets-on?)" "$out"
  fi
fi

# Keep real credentials out of the offline tests: clear JIRA_* and point
# XDG_CONFIG_HOME at an empty dir so ~/.config/nvimjira/config.json is ignored.
unset JIRA_URL JIRA_EMAIL JIRA_API_TOKEN JIRA_API_TOKEN_CMD JIRA_API_VERSION JIRA_PROJECT LAZYGIT_JIRA_JQL LG_CONFIG_FILE

TMP=$(mktemp -d)
SERVER_PID=
cleanup() {
  [ -n "$SERVER_PID" ] && kill "$SERVER_PID" 2>/dev/null
  command -v tmux >/dev/null && tmux -L lazygit-jira-test kill-server 2>/dev/null
  rm -rf "$TMP"
}
trap cleanup EXIT INT TERM

mkdir -p "$TMP/xdg"
python3 "$ROOT/test/fake_jira.py" "$TMP/port" "$TMP/requests.log" &
SERVER_PID=$!
i=0
while [ ! -s "$TMP/port" ] && [ $i -lt 50 ]; do sleep 0.1; i=$((i + 1)); done
[ -s "$TMP/port" ] || { echo "fake Jira server did not start"; exit 1; }
URL=http://127.0.0.1:$(cat "$TMP/port")

# Runs a command with an isolated config dir and the given JIRA_* settings.
jenv() { env XDG_CONFIG_HOME="$TMP/xdg" "$@"; }
good() { jenv JIRA_URL="$URL" JIRA_EMAIL=test@example.com JIRA_API_TOKEN=secret-token "$@"; }

# --- ticket list -------------------------------------------------------------

: >"$TMP/requests.log"
out=$(good "$BIN/lazygit-jira-tickets")
expected=$(printf '%s\n' \
  "PL-250       [In Progress]   Bug        Login fails on Safari  (Test User)" \
  "PL-237       [Waiting]       Task       Follow up on security review  (Test User)" \
  "NONE  (no ticket)")
[ "$out" = "$expected" ] && ok "lists tickets, then a no-ticket option" || not_ok "lists tickets, then a no-ticket option" "$out"

if grep -q '"auth_ok": true' "$TMP/requests.log" && ! grep -q '"auth_ok": false' "$TMP/requests.log"; then
  ok "sends Basic auth built from JIRA_EMAIL and JIRA_API_TOKEN"
else
  not_ok "sends Basic auth built from JIRA_EMAIL and JIRA_API_TOKEN" "$(cat "$TMP/requests.log")"
fi

grep -qF 'assignee = currentUser() AND status in (\"In Progress\", \"Waiting\")' "$TMP/requests.log" \
  && ok "default JQL asks for In Progress and Waiting" \
  || not_ok "default JQL asks for In Progress and Waiting" "$(cat "$TMP/requests.log")"

: >"$TMP/requests.log"
good LAZYGIT_JIRA_JQL='project = PL' "$BIN/lazygit-jira-tickets" >/dev/null
grep -qF '"jql": ["project = PL"]' "$TMP/requests.log" \
  && ok "LAZYGIT_JIRA_JQL overrides the query" \
  || not_ok "LAZYGIT_JIRA_JQL overrides the query" "$(cat "$TMP/requests.log")"

out=$(jenv JIRA_URL="$URL" JIRA_EMAIL=test@example.com JIRA_API_TOKEN_CMD='echo secret-token' "$BIN/lazygit-jira-tickets" | head -n 1)
case $out in PL-250*) ok "reads the token from JIRA_API_TOKEN_CMD" ;; *) not_ok "reads the token from JIRA_API_TOKEN_CMD" "$out" ;; esac

printf '{"url": "%s", "email": "test@example.com", "token": "secret-token"}\n' "$URL" >"$TMP/cfgfile.json"
mkdir -p "$TMP/xdg-file/nvimjira" && cp "$TMP/cfgfile.json" "$TMP/xdg-file/nvimjira/config.json"
out=$(env XDG_CONFIG_HOME="$TMP/xdg-file" "$BIN/lazygit-jira-tickets" | head -n 1)
case $out in PL-250*) ok "reads credentials from nvimjira/config.json" ;; *) not_ok "reads credentials from nvimjira/config.json" "$out" ;; esac

out=$(jenv JIRA_URL="$URL" JIRA_EMAIL=test@example.com JIRA_API_TOKEN=wrong "$BIN/lazygit-jira-tickets"); rc=$?
case $out in
  "NONE  (no ticket) - Jira lookup failed: HTTP 401"*) [ $rc -eq 0 ] && ok "a bad token shows the 401 in the menu" || not_ok "a bad token shows the 401 in the menu" "exit $rc" ;;
  *) not_ok "a bad token shows the 401 in the menu" "$out" ;;
esac

out=$(jenv "$BIN/lazygit-jira-tickets")
[ "$out" = "NONE  (no ticket) - Jira lookup failed: JIRA_URL is not set" ] \
  && ok "missing credentials show an error in the menu" \
  || not_ok "missing credentials show an error in the menu" "$out"

jenv "$BIN/lazygit-jira-tickets" --strict >/dev/null && not_ok "--strict exits non-zero when the lookup fails" || ok "--strict exits non-zero when the lookup fails"

# --- wrapper -----------------------------------------------------------------

# A stand-in for lazygit that reports what it was started with, and runs the
# ticket command from PATH the way lazygit's menuFromCommand does.
cat >"$TMP/fake-lazygit" <<'STUB'
#!/bin/sh
echo "LG_CONFIG_FILE=$LG_CONFIG_FILE"
echo "ARGS=$*"
lazygit-jira-tickets | head -n 1
STUB
chmod +x "$TMP/fake-lazygit"

mkdir -p "$TMP/xdg/lazygit" && : >"$TMP/xdg/lazygit/config.yml"
out=$(good LAZYGIT_BIN="$TMP/fake-lazygit" PATH=/usr/bin:/bin "$BIN/lazygit-jira" -p somewhere)
expected=$(printf '%s\n' \
  "LG_CONFIG_FILE=$TMP/xdg/lazygit/config.yml,$ROOT/lazygit/jira-commit.yml" \
  "ARGS=-p somewhere" \
  "PL-250       [In Progress]   Bug        Login fails on Safari  (Test User)")
[ "$out" = "$expected" ] \
  && ok "lazygit gets your config + jira-commit.yml, the args, and authenticated tickets on PATH" \
  || not_ok "lazygit gets your config + jira-commit.yml, the args, and authenticated tickets on PATH" "$out"
rm "$TMP/xdg/lazygit/config.yml"

out=$(good LAZYGIT_BIN="$TMP/fake-lazygit" "$BIN/lazygit-jira" | head -n 1)
[ "$out" = "LG_CONFIG_FILE=$ROOT/lazygit/jira-commit.yml" ] \
  && ok "skips a missing base lazygit config" || not_ok "skips a missing base lazygit config" "$out"

out=$(good LG_CONFIG_FILE=/a.yml,/b.yml LAZYGIT_BIN="$TMP/fake-lazygit" "$BIN/lazygit-jira" | head -n 1)
[ "$out" = "LG_CONFIG_FILE=/a.yml,/b.yml,$ROOT/lazygit/jira-commit.yml" ] \
  && ok "keeps an existing LG_CONFIG_FILE" || not_ok "keeps an existing LG_CONFIG_FILE" "$out"

out=$(good "$BIN/lazygit-jira" --check) && case $out in "Test User <test@example.com>"*PL-250*) true ;; *) false ;; esac \
  && ok "--check passes with good credentials" || not_ok "--check passes with good credentials" "$out"
out=$(jenv JIRA_URL="$URL" JIRA_EMAIL=test@example.com JIRA_API_TOKEN=wrong "$BIN/lazygit-jira" --check 2>&1) \
  && not_ok "--check fails with a bad token" "$out" || ok "--check fails with a bad token"

# --- end to end: real lazygit in tmux ----------------------------------------

# Types keys into the test lazygit and waits for lazygit to redraw.
keys() { tmux -L lazygit-jira-test send-keys -t e2e "$@"; sleep 0.8; }
screen() { tmux -L lazygit-jira-test capture-pane -pt e2e; }
wait_for() {
  i=0
  while ! screen | grep -qF -- "$1"; do
    i=$((i + 1)); [ $i -ge 50 ] && return 1; sleep 0.1
  done
}

e2e_commit() { # name, menu keys..., summary; expects $1 as the commit subject
  expect=$1; shift
  repo=$TMP/repo-$pass-$fail
  git init -q "$repo" && echo x >"$repo/f" && git -C "$repo" add f
  tmux -L lazygit-jira-test kill-session -t e2e 2>/dev/null
  tmux -L lazygit-jira-test new-session -d -s e2e -x 160 -y 40 -c "$repo" \
    "env XDG_CONFIG_HOME='$TMP/xdg' JIRA_URL='$URL' JIRA_EMAIL=test@example.com JIRA_API_TOKEN=secret-token \
     GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t '$BIN/lazygit-jira'"
  wait_for "Files" || { not_ok "e2e: $expect" "lazygit did not start"; return; }
  keys c
  wait_for "PL-250" || { not_ok "e2e: $expect" "ticket menu not shown: $(screen)"; return; }
  for k in "$@"; do
    case $k in text:*) tmux -L lazygit-jira-test send-keys -t e2e -l "${k#text:}"; sleep 0.3 ;; *) keys "$k" ;; esac
  done
  i=0
  while [ "$(git -C "$repo" log -1 --format=%s 2>/dev/null)" != "$expect" ] && [ $i -lt 30 ]; do sleep 0.1; i=$((i + 1)); done
  got=$(git -C "$repo" log -1 --format=%s 2>/dev/null)
  [ "$got" = "$expect" ] && ok "e2e: commits \"$expect\"" || not_ok "e2e: commits \"$expect\"" "got: $got"
}

if command -v tmux >/dev/null && command -v lazygit >/dev/null; then
  # Ticket PL-250, type fix, summary with a quote to check shell escaping.
  e2e_commit "fix(#PL-250): handle Safari's cookie quirk" Enter Enter "text:handle Safari's cookie quirk" Enter
  # Ticket PL-237 (second), type feat (second).
  e2e_commit "feat(#PL-237): add audit log" j Enter j Enter "text:add audit log" Enter
  # No ticket (third), type chore (third).
  e2e_commit "chore: bump deps" j j Enter j j Enter "text:bump deps" Enter
else
  skipped "e2e tests (need tmux and lazygit)"
fi

echo
echo "$pass passed, $fail failed, $skip skipped"
[ $fail -eq 0 ]
