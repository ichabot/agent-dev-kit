#!/usr/bin/env bats
# Tests for agent/gitea-init.sh against a fake docker (Gitea CLI, sqlite3 and API emulated).
# Runs as the current user: ADK_AS_USER_HOOK replaces runuser, ADK_TEST_HERMES_HOME and
# ADK_TEST_PASSWORD_FILE replace the real paths (honored only as non-root).

setup() {
  ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  INIT="$ROOT/agent/gitea-init.sh"
  CFG="$BATS_TEST_TMPDIR/kit.env"
  cp "$ROOT/tests/fixtures/valid.env" "$CFG"
  mkdir -p "$BATS_TEST_TMPDIR/bin" "$BATS_TEST_TMPDIR/hermes" "$BATS_TEST_TMPDIR/root"
  cp "$ROOT/tests/fixtures/fake-docker" "$BATS_TEST_TMPDIR/bin/docker"
  chmod +x "$BATS_TEST_TMPDIR/bin/docker"
  export PATH="$BATS_TEST_TMPDIR/bin:$PATH"
  export FAKE_STATE="$BATS_TEST_TMPDIR/state.json" FAKE_LOG="$BATS_TEST_TMPDIR/calls.log"
  : > "$FAKE_LOG"
  docker init
  HERMES_HOME="$BATS_TEST_TMPDIR/hermes"
  chmod 0700 "$HERMES_HOME"
  export ADK_TEST_HERMES_HOME="$HERMES_HOME"
  export ADK_TEST_PASSWORD_FILE="$BATS_TEST_TMPDIR/root/adk-gitea-initial-password"
  cat > "$BATS_TEST_TMPDIR/as-user" <<'EOF'
#!/usr/bin/env bash
shift
exec "$@"
EOF
  chmod +x "$BATS_TEST_TMPDIR/as-user"
  export ADK_AS_USER_HOOK="$BATS_TEST_TMPDIR/as-user"
  export ADK_GITEA_LOCK_DIR="$BATS_TEST_TMPDIR/run-adk"
}

# st PYTHON_EXPR: evaluate an expression over the fake Gitea state (variable s)
st() {
  python3 -I -c 'import json, sys; s = json.load(open(sys.argv[1])); print(eval(sys.argv[2]))' "$FAKE_STATE" "$1"
}

refute() {
  if "$@"; then return 1; fi
}

@test "usage errors exit 2" {
  run "$INIT" --bogus
  [ "$status" -eq 2 ]
  run "$INIT" --config
  [ "$status" -eq 2 ]
  run "$INIT" --config "$BATS_TEST_TMPDIR/missing.env"
  [ "$status" -eq 2 ]
}

@test "refuses to run as non-root without the test overrides" {
  run env -u ADK_AS_USER_HOOK "$INIT" --config "$CFG"
  [ "$status" -eq 2 ]
  [[ "$output" == *"run as root"* ]]
}

@test "invalid kit.env stops before any Gitea call" {
  sed -i 's/^GITEA_ADMIN_USER=.*/GITEA_ADMIN_USER=agent-bot/' "$CFG"
  run "$INIT" --config "$CFG"
  [ "$status" -eq 1 ]
  [[ "$output" == *"GITEA_ADMIN_USER"* ]]
  [ ! -s "$FAKE_LOG" ]
}

@test "first run creates accounts, organization and teams" {
  run "$INIT" --config "$CFG"
  [ "$status" -eq 0 ]
  # employee: site admin, must change the password at the first login
  [ "$(st 's["users"]["anna.mueller"]["admin"]')" = "True" ]
  [ "$(st 's["users"]["anna.mueller"]["must_change"]')" = "True" ]
  # bots: no admin, bot type (no password)
  for bot in agent-bot prod-pull; do
    [ "$(st "s['users']['$bot']['admin']")" = "False" ]
    [ "$(st "s['users']['$bot']['type']")" = "bot" ]
    [ "$(st "s['users']['$bot']['password']")" = "None" ]
  done
  [ "$(st 's["orgs"]["acme"]["visibility"]')" = "private" ]
  [ "$(st '[(t["name"], t["permission"], t["can_create_org_repo"], t["includes_all_repositories"]) for t in s["teams"].values() if t["name"] != "Owners"]')" \
    = "[('developers', 'write', False, False), ('readers', 'read', False, False)]" ]
  [ "$(st '[t["members"] for t in s["teams"].values() if t["name"] == "developers"]')" = "[['agent-bot']]" ]
  [ "$(st '[t["members"] for t in s["teams"].values() if t["name"] == "readers"]')" = "[['prod-pull']]" ]
  [ "$(st '[t["members"] for t in s["teams"].values() if t["name"] == "Owners"]')" = "[['anna.mueller']]" ]
  # developers: write code, issues, pulls, wiki; only read packages, releases and actions
  [ "$(st '[t["units_map"] for t in s["teams"].values() if t["name"] == "developers"]')" \
    = "[{'repo.code': 'write', 'repo.issues': 'write', 'repo.pulls': 'write', 'repo.wiki': 'write', 'repo.projects': 'write', 'repo.releases': 'read', 'repo.packages': 'read', 'repo.actions': 'read', 'repo.ext_issues': 'read', 'repo.ext_wiki': 'read'}]" ]
  # readers: read-only units incl. packages
  [ "$(st '[t["units_map"] for t in s["teams"].values() if t["name"] == "readers"]')" \
    = "[{'repo.code': 'read', 'repo.releases': 'read', 'repo.packages': 'read'}]" ]
}

@test "the initial password lives only in the root-only file" {
  run "$INIT" --config "$CFG"
  [ "$status" -eq 0 ]
  pw="$(st 's["users"]["anna.mueller"]["password"]')"
  [ -n "$pw" ]
  [ "$(stat -c %a "$ADK_TEST_PASSWORD_FILE")" = "600" ]
  grep -qF "$pw" "$ADK_TEST_PASSWORD_FILE"
  [[ "$output" != *"$pw"* ]]
  refute grep -rqF "$pw" "$HERMES_HOME"
  [[ "$output" == *"$ADK_TEST_PASSWORD_FILE"* ]]
}

@test "agent-bot token goes to hermes's file (0600) with the agreed scopes, never to stdout" {
  run "$INIT" --config "$CFG"
  [ "$status" -eq 0 ]
  tok="$(cat "$HERMES_HOME/.config/gitea/token")"
  [[ "$tok" =~ ^[0-9a-f]{40}$ ]]
  [ "$(stat -c %a "$HERMES_HOME/.config/gitea/token")" = "600" ]
  [ "$(stat -c %a "$HERMES_HOME/.config/gitea")" = "700" ]
  [ "$(st "[t['user'] for t in s['tokens'] if t['token'] == '$tok']")" = "['agent-bot']" ]
  # no package write (PROD pulls images; agent-bot must not publish them), no admin scopes
  [ "$(st "[t['scopes'] for t in s['tokens'] if t['token'] == '$tok']")" \
    = "['write:repository,write:issue,read:user,read:organization,read:package']" ]
  [[ "$output" != *"$tok"* ]]
  refute grep -qF "$tok" "$FAKE_LOG"
  # no token for prod-pull yet
  [ "$(st 'len([t for t in s["tokens"] if t["user"] == "prod-pull"])')" = "0" ]
}

@test "git credential helper for hermes points at the token file" {
  "$INIT" --config "$CFG" > /dev/null
  grep -qF '[credential "https://git.example.com"]' "$HERMES_HOME/.gitconfig"
  grep -qF "helper = $HERMES_HOME/.config/gitea/git-credential" "$HERMES_HOME/.gitconfig"
  [ "$(stat -c %a "$HERMES_HOME/.config/gitea/git-credential")" = "700" ]
  out="$(HOME="$HERMES_HOME" "$HERMES_HOME/.config/gitea/git-credential" get <<< "host=git.example.com")"
  [ "$out" = "$(printf 'username=agent-bot\npassword=%s' "$(cat "$HERMES_HOME/.config/gitea/token")")" ]
  [ -z "$(HOME="$HERMES_HOME" "$HERMES_HOME/.config/gitea/git-credential" store <<< "x=y")" ]
}

@test "the temporary admin token is gone afterwards and was passed via stdin only" {
  run "$INIT" --config "$CFG"
  [ "$status" -eq 0 ]
  [ "$(st '[t["name"] for t in s["tokens"] if t["user"] == "anna.mueller"]')" = "[]" ]
  refute grep -qE '[0-9a-f]{40}' "$FAKE_LOG"
}

@test "second run changes nothing" {
  "$INIT" --config "$CFG" > /dev/null
  : > "$FAKE_LOG"
  run "$INIT" --config "$CFG"
  [ "$status" -eq 0 ]
  [[ "$output" != *"changed:"* ]]
  refute grep -qE 'user create|API (POST|PUT|PATCH)' "$FAKE_LOG"
  [ "$(st 's["users"]["anna.mueller"]["must_change"]')" = "True" ]
}

@test "employee who already changed the password keeps must_change off" {
  "$INIT" --config "$CFG" > /dev/null
  rm "$ADK_TEST_PASSWORD_FILE"   # handed over
  python3 -I -c 'import json, sys; p = sys.argv[1]; s = json.load(open(p)); s["users"]["anna.mueller"]["must_change"] = False; json.dump(s, open(p, "w"))' "$FAKE_STATE"
  run "$INIT" --config "$CFG"
  [ "$status" -eq 0 ]
  [ "$(st 's["users"]["anna.mueller"]["must_change"]')" = "False" ]
}

@test "an invalid token file is replaced and older hermes tokens are revoked" {
  "$INIT" --config "$CFG" > /dev/null
  old="$(cat "$HERMES_HOME/.config/gitea/token")"
  printf 'garbage\n' > "$HERMES_HOME/.config/gitea/token"
  sleep 1   # token names carry a timestamp
  run "$INIT" --config "$CFG"
  [ "$status" -eq 0 ]
  new="$(cat "$HERMES_HOME/.config/gitea/token")"
  [[ "$new" =~ ^[0-9a-f]{40}$ ]]
  [ "$new" != "$old" ]
  [ "$(st "len([t for t in s['tokens'] if t['token'] == '$old'])")" = "0" ]
  [ "$(st 'len([t for t in s["tokens"] if t["user"] == "agent-bot"])')" = "1" ]
}

@test "a team with drifted settings is reset" {
  "$INIT" --config "$CFG" > /dev/null
  python3 -I -c 'import json, sys; p = sys.argv[1]; s = json.load(open(p))
for t in s["teams"].values():
    if t["name"] == "developers": t["can_create_org_repo"] = True
json.dump(s, open(p, "w"))' "$FAKE_STATE"
  run "$INIT" --config "$CFG"
  [ "$status" -eq 0 ]
  [[ "$output" == *"changed: team developers"* ]]
  [ "$(st '[t["can_create_org_repo"] for t in s["teams"].values() if t["name"] == "developers"]')" = "[False]" ]
}

@test "a bot with site admin rights stops the run" {
  docker compose -f x exec -T -u git gitea gitea admin user create --username agent-bot --email a@example.com --admin --user-type bot > /dev/null
  run "$INIT" --config "$CFG"
  [ "$status" -ne 0 ]
  [[ "$output" == *"agent-bot is a site admin"* ]]
}

@test "a bot in the Owners team stops the run" {
  "$INIT" --config "$CFG" > /dev/null
  python3 -I -c 'import json, sys; p = sys.argv[1]; s = json.load(open(p))
for t in s["teams"].values():
    if t["name"] == "Owners": t["members"].append("agent-bot")
json.dump(s, open(p, "w"))' "$FAKE_STATE"
  run "$INIT" --config "$CFG"
  [ "$status" -ne 0 ]
  [[ "$output" == *"agent-bot is an owner"* ]]
  # the temporary token is still cleaned up
  [ "$(st '[t["name"] for t in s["tokens"] if t["user"] == "anna.mueller"]')" = "[]" ]
}

@test "a symlinked ~/.config/gitea in hermes's home is refused" {
  mkdir -p "$HERMES_HOME/.config" "$BATS_TEST_TMPDIR/elsewhere"
  ln -s "$BATS_TEST_TMPDIR/elsewhere" "$HERMES_HOME/.config/gitea"
  run "$INIT" --config "$CFG"
  [ "$status" -eq 3 ]
  [ -z "$(ls -A "$BATS_TEST_TMPDIR/elsewhere")" ]
}

@test "both bots may not create repositories in their own namespace (max_repo_creation 0)" {
  run "$INIT" --config "$CFG"
  [ "$status" -eq 0 ]
  [ "$(st 's["users"]["agent-bot"]["max_repo_creation"]')" = "0" ]
  [ "$(st 's["users"]["prod-pull"]["max_repo_creation"]')" = "0" ]
  [ "$(st 's["users"]["anna.mueller"]["max_repo_creation"]')" = "-1" ]
  : > "$FAKE_LOG"
  run "$INIT" --config "$CFG"
  refute grep -q 'API PATCH /admin/users' "$FAKE_LOG"
}

@test "a leftover temporary token of a killed run is deleted at the start" {
  "$INIT" --config "$CFG" > /dev/null
  docker compose -f x exec -T -u git gitea gitea admin user generate-access-token --username anna.mueller \
    --token-name adk-init-20260101000000-1 --scopes all --raw > /dev/null
  run "$INIT" --config "$CFG"
  [ "$status" -eq 0 ]
  [ "$(st '[t["name"] for t in s["tokens"] if t["user"] == "anna.mueller"]')" = "[]" ]
}

@test "Gitea failing during the run: must-change is set again, the token deleted, exit != 0" {
  "$INIT" --config "$CFG" > /dev/null
  python3 -I -c 'import json, sys; p = sys.argv[1]; s = json.load(open(p)); s["api_calls"] = 0; json.dump(s, open(p, "w"))' "$FAKE_STATE"
  FAKE_CURL_FAIL_AFTER=2 run "$INIT" --config "$CFG"
  [ "$status" -ne 0 ]
  [ "$(st 's["users"]["anna.mueller"]["must_change"]')" = "True" ]
  [ "$(st '[t["name"] for t in s["tokens"] if t["user"] == "anna.mueller"]')" = "[]" ]
  [ ! -e "$BATS_TEST_TMPDIR/root/.adk-gitea-must-change-pending" ]
}

@test "the marker of a crashed run puts must-change back" {
  "$INIT" --config "$CFG" > /dev/null
  rm "$ADK_TEST_PASSWORD_FILE"
  # a run killed after lifting the flag: flag off, marker left behind
  python3 -I -c 'import json, sys; p = sys.argv[1]; s = json.load(open(p)); s["users"]["anna.mueller"]["must_change"] = False; json.dump(s, open(p, "w"))' "$FAKE_STATE"
  : > "$BATS_TEST_TMPDIR/root/.adk-gitea-must-change-pending"
  run "$INIT" --config "$CFG"
  [ "$status" -eq 0 ]
  [ "$(st 's["users"]["anna.mueller"]["must_change"]')" = "True" ]
  [ ! -e "$BATS_TEST_TMPDIR/root/.adk-gitea-must-change-pending" ]
}

@test "an initial password file not handed over yet means must change" {
  "$INIT" --config "$CFG" > /dev/null
  python3 -I -c 'import json, sys; p = sys.argv[1]; s = json.load(open(p)); s["users"]["anna.mueller"]["must_change"] = False; json.dump(s, open(p, "w"))' "$FAKE_STATE"
  run "$INIT" --config "$CFG"
  [ "$status" -eq 0 ]
  [ "$(st 's["users"]["anna.mueller"]["must_change"]')" = "True" ]
}

@test "organization repositories without protection are listed as WARNING" {
  "$INIT" --config "$CFG" > /dev/null
  python3 -I -c 'import json, sys; p = sys.argv[1]; s = json.load(open(p))
s["repos"]["acme/open"] = {"default_branch": "main", "branch_protections": [], "tag_protections": []}
json.dump(s, open(p, "w"))' "$FAKE_STATE"
  run "$INIT" --config "$CFG"
  [ "$status" -eq 0 ]
  [[ "$output" == *"WARNING: acme/open is not protected"* ]]
  [[ "$output" == *"protect-repo.sh acme/open"* ]]
}

@test "a valid agent-bot token with outdated scopes (write:package) is replaced" {
  "$INIT" --config "$CFG" > /dev/null
  python3 -I -c 'import json, sys; p = sys.argv[1]; s = json.load(open(p))
for t in s["tokens"]:
    if t["user"] == "agent-bot": t["scopes"] = "write:repository,write:issue,read:user,write:package,read:organization"
json.dump(s, open(p, "w"))' "$FAKE_STATE"
  old="$(cat "$HERMES_HOME/.config/gitea/token")"
  sleep 1
  run "$INIT" --config "$CFG"
  [ "$status" -eq 0 ]
  [ "$(cat "$HERMES_HOME/.config/gitea/token")" != "$old" ]
  [ "$(st '[t["scopes"] for t in s["tokens"] if t["user"] == "agent-bot"]')" \
    = "['write:repository,write:issue,read:user,read:organization,read:package']" ]
}

@test "teams do not include all repositories: a new repository is not writable for agent-bot" {
  "$INIT" --config "$CFG" > /dev/null
  python3 -I -c 'import json, sys; p = sys.argv[1]; s = json.load(open(p))
for t in s["teams"].values():
    if t["name"] == "developers": t["includes_all_repositories"] = True
json.dump(s, open(p, "w"))' "$FAKE_STATE"
  run "$INIT" --config "$CFG"
  [ "$status" -eq 0 ]
  [[ "$output" == *"changed: team developers reset"* ]]
  [ "$(st '[t["includes_all_repositories"] for t in s["teams"].values() if t["name"] == "developers"]')" = "[False]" ]
}

@test "an unprotected repository loses team developers; a protected one without teams is reported" {
  "$INIT" --config "$CFG" > /dev/null
  python3 -I -c 'import json, sys; p = sys.argv[1]; s = json.load(open(p))
good = [{"rule_name": "main", "enable_push": False, "enable_force_push": False, "enable_merge_whitelist": True,
         "enable_bypass_allowlist": False, "dismiss_stale_approvals": True, "block_on_rejected_reviews": True,
         "enable_approvals_whitelist": True, "required_approvals": 1,
         "merge_whitelist_usernames": ["anna.mueller"], "approvals_whitelist_username": ["anna.mueller"]}]
tags = [{"id": 99, "name_pattern": "*", "whitelist_usernames": ["anna.mueller"], "whitelist_teams": []}]
s["repos"]["acme/open"] = {"default_branch": "main", "branch_protections": [], "tag_protections": [], "teams": ["developers", "readers"]}
s["repos"]["acme/safe"] = {"default_branch": "main", "branch_protections": good, "tag_protections": tags, "teams": []}
json.dump(s, open(p, "w"))' "$FAKE_STATE"
  run "$INIT" --config "$CFG"
  [ "$status" -eq 0 ]
  [[ "$output" == *"changed: acme/open: team developers removed"* ]]
  [ "$(st 's["repos"]["acme/open"]["teams"]')" = "['readers']" ]
  [[ "$output" == *"WARNING: acme/safe is protected, but team(s) developers readers have no access yet"* ]]
  # nothing is added by gitea-init itself
  [ "$(st 's["repos"]["acme/safe"]["teams"]')" = "[]" ]
}

@test "kit scripts with admin access run one at a time (lock), each deletes its own token" {
  # (as a kit script leaves it: root-only directory, file 0600)
  mkdir -m 0700 "$ADK_GITEA_LOCK_DIR"
  (umask 077; : > "$ADK_GITEA_LOCK_DIR/gitea-admin.lock")
  flock "$ADK_GITEA_LOCK_DIR/gitea-admin.lock" sleep 5 &
  holder=$!
  sleep 0.5
  ADK_GITEA_LOCK_WAIT=1 run "$INIT" --config "$CFG"
  kill "$holder" 2> /dev/null || true
  [ "$status" -ne 0 ]
  [[ "$output" == *"another kit script is using the Gitea admin access"* ]]
  [ "$(st 'len([t for t in s["tokens"] if t["name"].startswith("adk-init-")])')" = "0" ]
  wait "$holder" 2> /dev/null || true
  run "$INIT" --config "$CFG"
  [ "$status" -eq 0 ]
  grep -qE "^sqlite3 .*DELETE FROM access_token WHERE name = 'adk-init-[0-9]{14}-[0-9]+-[0-9]+';" "$FAKE_LOG"
}
