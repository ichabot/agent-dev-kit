#!/usr/bin/env bats
# Tests for agent/protect-repo.sh against the fake Gitea (tests/fixtures/fake-docker).

setup() {
  ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  PROTECT="$ROOT/agent/protect-repo.sh"
  CFG="$BATS_TEST_TMPDIR/kit.env"
  cp "$ROOT/tests/fixtures/valid.env" "$CFG"
  mkdir -p "$BATS_TEST_TMPDIR/bin" "$BATS_TEST_TMPDIR/root"
  cp "$ROOT/tests/fixtures/fake-docker" "$BATS_TEST_TMPDIR/bin/docker"
  chmod +x "$BATS_TEST_TMPDIR/bin/docker"
  export PATH="$BATS_TEST_TMPDIR/bin:$PATH"
  export FAKE_STATE="$BATS_TEST_TMPDIR/state.json" FAKE_LOG="$BATS_TEST_TMPDIR/calls.log"
  : > "$FAKE_LOG"
  docker init
  export ADK_TEST_PASSWORD_FILE="$BATS_TEST_TMPDIR/root/adk-gitea-initial-password"
  # the employee (admin, must still change the password) and one repository
  docker compose -f x exec -T -u git gitea gitea admin user create --username anna.mueller \
    --email anna@example.com --admin --must-change-password=true > /dev/null
  python3 -I -c 'import json, sys; p = sys.argv[1]; s = json.load(open(p))
s["repos"]["acme/demo"] = {"default_branch": "main", "branch_protections": [], "tag_protections": []}
# teams of the organization (gitea-init.sh), not "all repositories"
for i, (name, perm) in enumerate((("Owners", "owner"), ("developers", "write"), ("readers", "read"))):
    s["teams"][str(50 + i)] = {"id": 50 + i, "org": "acme", "name": name, "members": [],
                               "includes_all_repositories": name == "Owners", "permission": perm}
json.dump(s, open(p, "w"))' "$FAKE_STATE"
  : > "$FAKE_LOG"
  export ADK_GITEA_LOCK_DIR="$BATS_TEST_TMPDIR/run-adk"
}

st() {
  python3 -I -c 'import json, sys; s = json.load(open(sys.argv[1])); print(eval(sys.argv[2]))' "$FAKE_STATE" "$1"
}
rule() { st "next(r for r in s['repos']['acme/demo']['branch_protections'] if r['rule_name'] == 'main')['$1']"; }

refute() {
  if "$@"; then return 1; fi
}

@test "protects the default branch: PR only, merge and approval only by the employee" {
  run "$PROTECT" --config "$CFG" acme/demo
  [ "$status" -eq 0 ]
  [ "$(rule enable_push)" = "False" ]
  [ "$(rule enable_force_push)" = "False" ]
  [ "$(rule enable_merge_whitelist)" = "True" ]
  [ "$(rule merge_whitelist_usernames)" = "['anna.mueller']" ]
  [ "$(rule merge_whitelist_teams)" = "[]" ]
  [ "$(rule required_approvals)" = "1" ]
  [ "$(rule enable_approvals_whitelist)" = "True" ]
  [ "$(rule approvals_whitelist_username)" = "['anna.mueller']" ]
  [ "$(rule dismiss_stale_approvals)" = "True" ]
  [ "$(rule block_on_rejected_reviews)" = "True" ]
  [ "$(rule enable_bypass_allowlist)" = "False" ]
  [ "$(rule enable_status_check)" = "False" ]
}

@test "protects all tags: only the employee may create or delete them" {
  run "$PROTECT" --config "$CFG" acme/demo
  [ "$status" -eq 0 ]
  [ "$(st 's["repos"]["acme/demo"]["tag_protections"][0]["name_pattern"]')" = "*" ]
  [ "$(st 's["repos"]["acme/demo"]["tag_protections"][0]["whitelist_usernames"]')" = "['anna.mueller']" ]
  [ "$(st 's["repos"]["acme/demo"]["tag_protections"][0]["whitelist_teams"]')" = "[]" ]
}

@test "--status-check requires the given CI contexts" {
  run "$PROTECT" --config "$CFG" --status-check "ci / test (pull_request)" acme/demo
  [ "$status" -eq 0 ]
  [ "$(rule enable_status_check)" = "True" ]
  [ "$(rule status_check_contexts)" = "['ci / test (pull_request)']" ]
}

@test "second run changes nothing, drifted settings are reset" {
  "$PROTECT" --config "$CFG" acme/demo > /dev/null
  run "$PROTECT" --config "$CFG" acme/demo
  [ "$status" -eq 0 ]
  [[ "$output" != *"changed:"* ]]
  python3 -I -c 'import json, sys; p = sys.argv[1]; s = json.load(open(p))
r = s["repos"]["acme/demo"]
r["branch_protections"][0]["enable_merge_whitelist"] = False
r["branch_protections"][0]["merge_whitelist_usernames"] = ["agent-bot"]
r["tag_protections"][0]["whitelist_usernames"] = ["agent-bot"]
json.dump(s, open(p, "w"))' "$FAKE_STATE"
  run "$PROTECT" --config "$CFG" acme/demo
  [ "$status" -eq 0 ]
  [[ "$output" == *"changed: acme/demo main protection reset"* ]]
  [[ "$output" == *"changed: acme/demo tag protection reset"* ]]
  [ "$(rule merge_whitelist_usernames)" = "['anna.mueller']" ]
  [ "$(st 's["repos"]["acme/demo"]["tag_protections"][0]["whitelist_usernames"]')" = "['anna.mueller']" ]
}

@test "another tag rule that lets agent-bot tag is reported and fails the run" {
  python3 -I -c 'import json, sys; p = sys.argv[1]; s = json.load(open(p))
s["repos"]["acme/demo"]["tag_protections"].append({"id": 99, "name_pattern": "v*", "whitelist_usernames": ["agent-bot"], "whitelist_teams": []})
json.dump(s, open(p, "w"))' "$FAKE_STATE"
  run "$PROTECT" --config "$CFG" acme/demo
  [ "$status" -eq 1 ]
  [[ "$output" == *"v*"* ]]
}

@test "the temporary admin token is gone and must-change is set again" {
  run "$PROTECT" --config "$CFG" acme/demo
  [ "$status" -eq 0 ]
  [ "$(st '[t["name"] for t in s["tokens"] if t["user"] == "anna.mueller"]')" = "[]" ]
  [ "$(st 's["users"]["anna.mueller"]["must_change"]')" = "True" ]
  refute grep -qE '[0-9a-f]{40}' "$FAKE_LOG"
  refute grep -qE '[0-9a-f]{40}' <<< "$output"
}

@test "only repositories of the customer organization, valid names" {
  run "$PROTECT" --config "$CFG" other/demo
  [ "$status" -eq 2 ]
  run "$PROTECT" --config "$CFG" acme
  [ "$status" -eq 2 ]
  run "$PROTECT" --config "$CFG" 'acme/demo;id'
  [ "$status" -eq 2 ]
  run "$PROTECT" --config "$CFG" acme/..
  [ "$status" -eq 2 ]
  run "$PROTECT" --config "$CFG" --status-check 'x"y' acme/demo
  [ "$status" -eq 2 ]
  [ ! -s "$FAKE_LOG" ]
}

@test "a missing repository is reported" {
  run "$PROTECT" --config "$CFG" acme/missing
  [ "$status" -eq 1 ]
  [[ "$output" == *"not found"* ]]
}

@test "refuses to run as non-root without the test override" {
  run env -u ADK_TEST_PASSWORD_FILE "$PROTECT" --config "$CFG" acme/demo
  [ "$status" -eq 2 ]
  [[ "$output" == *"run as root"* ]]
}

@test "teams developers and readers get access only after the protection is in place" {
  run "$PROTECT" --config "$CFG" acme/demo
  [ "$status" -eq 0 ]
  [ "$(st 's["repos"]["acme/demo"]["teams"]')" = "['developers', 'readers']" ]
  last_protect="$(grep -nE '^API (POST|PATCH) /repos/acme/demo/(branch|tag)_protections' "$FAKE_LOG" | tail -n 1 | cut -d: -f1)"
  first_team="$(grep -n '^API PUT /repos/acme/demo/teams/' "$FAKE_LOG" | head -n 1 | cut -d: -f1)"
  [ "$last_protect" -lt "$first_team" ]
  # the final check of the protection lies in between too
  check="$(grep -n '^API GET /repos/acme/demo/tag_protections' "$FAKE_LOG" | tail -n 1 | cut -d: -f1)"
  [ "$check" -lt "$first_team" ]
  run "$PROTECT" --config "$CFG" acme/demo
  [ "$status" -eq 0 ]
  [[ "$output" == *"ok: acme/demo: team developers has access"* ]]
  [[ "$output" != *changed* ]]
}

@test "no team access when the protection cannot be completed" {
  python3 -I -c 'import json, sys; p = sys.argv[1]; s = json.load(open(p))
s["repos"]["acme/demo"]["tag_protections"] = [{"id": 7, "name_pattern": "v*", "whitelist_usernames": ["agent-bot"], "whitelist_teams": []}]
json.dump(s, open(p, "w"))' "$FAKE_STATE"
  run "$PROTECT" --config "$CFG" acme/demo
  [ "$status" -ne 0 ]
  [ "$(st 's["repos"]["acme/demo"].get("teams", [])')" = "[]" ]
  refute grep -q '^API PUT /repos/acme/demo/teams/' "$FAKE_LOG"
}

@test "a missing organization team is an error (gitea-init.sh first)" {
  python3 -I -c 'import json, sys; p = sys.argv[1]; s = json.load(open(p))
s["teams"] = {k: t for k, t in s["teams"].items() if t["name"] != "readers"}
json.dump(s, open(p, "w"))' "$FAKE_STATE"
  run "$PROTECT" --config "$CFG" acme/demo
  [ "$status" -ne 0 ]
  [[ "$output" == *"cannot give team readers access"* ]]
}
