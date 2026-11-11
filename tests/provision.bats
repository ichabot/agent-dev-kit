#!/usr/bin/env bats
# Tests for agent/provision.sh: --dry-run (no network) and the API flow against a fake curl.

setup() {
  ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  PROV="$ROOT/agent/provision.sh"
  CFG="$BATS_TEST_TMPDIR/kit.env"
  cp "$ROOT/tests/fixtures/valid.env" "$CFG"
  KEY="$BATS_TEST_TMPDIR/installer"
  ssh-keygen -q -t ed25519 -N '' -C 'installer@example.com' -f "$KEY"

  mkdir -p "$BATS_TEST_TMPDIR/bin"
  cp "$ROOT/tests/fixtures/fake-curl" "$BATS_TEST_TMPDIR/bin/curl"
  chmod +x "$BATS_TEST_TMPDIR/bin/curl"
  export PATH="$BATS_TEST_TMPDIR/bin:$PATH"
  export FAKE_LOG="$BATS_TEST_TMPDIR/requests.log" FAKE_ARGV="$BATS_TEST_TMPDIR/argv.log"
  : > "$FAKE_LOG"; : > "$FAKE_ARGV"
  export FAKE_TOKEN="Tok3nTok3nTok3nTok3nTok3nTok3nTok3nTok3nTok3nTok3nTok3nTok3nTok3"
  FAKE_FP="$(ssh-keygen -l -E md5 -f "$KEY.pub" | cut -d' ' -f2)"
  export FAKE_FP="${FAKE_FP#MD5:}"
  export HCLOUD_TOKEN_FILE="$BATS_TEST_TMPDIR/hcloud-token"
  (umask 077; printf '%s\n' "$FAKE_TOKEN" > "$HCLOUD_TOKEN_FILE")
  export ADK_POLL_INTERVAL=0
}

# body METHOD PATH: JSON body of the first matching request line in $output
body() {
  local line
  line="$(grep -m1 -F "$1 $2 " <<< "$output")"
  printf '%s' "${line#"$1 $2 "}"
}

# j JSON PYTHON_EXPR: evaluate an expression over JSON (variable d)
j() {
  python3 -I -c 'import json, sys; d = json.loads(sys.argv[1]); print(eval(sys.argv[2]))' "$1" "$2"
}

# no_match [grep options] PATTERN FILE: fail if the pattern is found
no_match() {
  if grep -q "$@"; then return 1; fi
}

# --- dry run ---------------------------------------------------------------

@test "dry-run makes no network call and needs no token" {
  rm "$HCLOUD_TOKEN_FILE"
  run "$PROV" --config "$CFG" --pubkey "$KEY.pub" --dry-run
  [ "$status" -eq 0 ]
  [ ! -s "$FAKE_ARGV" ]
}

@test "dry-run lists the requests in order" {
  run "$PROV" --config "$CFG" --pubkey "$KEY.pub" --dry-run
  [ "$status" -eq 0 ]
  got="$(grep -oE '^(GET|POST) [^ ]+' <<< "$output" | tr '\n' ';')"
  [ "$got" = "GET /servers?name=adk-acme-agent;GET /firewalls?name=adk-acme-agent;GET /ssh_keys?name=adk-acme-installer;GET /ssh_keys?fingerprint=$FAKE_FP;POST /ssh_keys;POST /firewalls;POST /servers;POST /servers/<id>/actions/enable_backup;" ]
}

@test "dry-run without --pubkey: only firewall and backups, server must exist" {
  rm "$HCLOUD_TOKEN_FILE"
  run "$PROV" --config "$CFG" --dry-run
  [ "$status" -eq 0 ]
  got="$(grep -oE '^(GET|POST) [^ ]+' <<< "$output" | tr '\n' ';')"
  [ "$got" = "GET /servers?name=adk-acme-agent;GET /firewalls?name=adk-acme-agent;POST /firewalls;POST /servers/<id>/actions/enable_backup;" ]
  [[ "$output" == *"must exist"* ]]
}

@test "dry-run: server is created with firewall attached, labels and debian-13" {
  run "$PROV" --config "$CFG" --pubkey "$KEY.pub" --dry-run
  [ "$status" -eq 0 ]
  b="$(body POST /servers)"
  [ "$(j "$b" 'd["name"]')" = "adk-acme-agent" ]
  [ "$(j "$b" 'd["image"]')" = "debian-13" ]
  [ "$(j "$b" 'd["location"]')" = "nbg1" ]
  [ "$(j "$b" 'd["server_type"]')" = "cx33" ]
  [ "$(j "$b" 'd["labels"]')" = "{'managed-by': 'agent-dev-kit', 'customer': 'acme'}" ]
  [ "$(j "$b" 'd["firewalls"]')" = "[{'firewall': '<id of firewall adk-acme-agent>'}]" ]
  [ "$(j "$b" 'd["ssh_keys"]')" = "['<id of ssh key adk-acme-installer>']" ]
}

@test "dry-run: user_data is the rendered cloud-init, truncated" {
  run "$PROV" --config "$CFG" --pubkey "$KEY.pub" --dry-run
  [ "$status" -eq 0 ]
  ud="$(j "$(body POST /servers)" 'd["user_data"]')"
  [[ "$ud" == "#cloud-config"* ]]
  [[ "$ud" == *"bytes"* ]]
  [[ "$ud" != *"PermitOpen"* ]]
}

@test "dry-run: firewall rules come from firewall-rules.sh incl. --admin-source" {
  run "$PROV" --config "$CFG" --pubkey "$KEY.pub" --admin-source 198.51.100.77 --dry-run
  [ "$status" -eq 0 ]
  b="$(body POST /firewalls)"
  expected="$("$ROOT/agent/firewall-rules.sh" --config "$CFG" --admin-source 198.51.100.77)"
  [ "$(j "$b" 'd["rules"]')" = "$(j "$expected" 'd')" ]
  [ "$(j "$b" 'd["name"]')" = "adk-acme-agent" ]
  [ "$(j "$b" 'd["labels"]["managed-by"]')" = "agent-dev-kit" ]
}

@test "dry-run: ssh key upload carries the public key only" {
  run "$PROV" --config "$CFG" --pubkey "$KEY.pub" --dry-run
  [ "$status" -eq 0 ]
  b="$(body POST /ssh_keys)"
  [ "$(j "$b" 'd["name"]')" = "adk-acme-installer" ]
  [ "$(j "$b" 'd["public_key"]')" = "$(cat "$KEY.pub")" ]
  [[ "$output" != *"PRIVATE"* ]]
}

@test "dry-run never prints the token" {
  run "$PROV" --config "$CFG" --pubkey "$KEY.pub" --dry-run
  [ "$status" -eq 0 ]
  [[ "$output" != *"$FAKE_TOKEN"* ]]
}

@test "invalid config, key or admin source: refused before any request" {
  printf 'CUSTOMER_IPS=0.0.0.0/0\n' >> "$CFG"
  run "$PROV" --config "$CFG" --pubkey "$KEY.pub" --dry-run
  [ "$status" -eq 1 ]
  cp "$ROOT/tests/fixtures/valid.env" "$CFG"
  run "$PROV" --config "$CFG" --pubkey "$KEY" --dry-run
  [ "$status" -eq 1 ]
  run "$PROV" --config "$CFG" --pubkey "$KEY.pub" --admin-source 10.0.0.1 --dry-run
  [ "$status" -eq 1 ]
  [[ "$output" != *"POST"* ]]
  [ ! -s "$FAKE_ARGV" ]
}

@test "usage errors exit 2" {
  run "$PROV" --config "$CFG" --pubkey "$KEY.pub" --frobnicate
  [ "$status" -eq 2 ]
  run "$PROV" --config "$CFG" --pubkey "$BATS_TEST_TMPDIR/nope.pub" --dry-run
  [ "$status" -eq 2 ]
}

# --- token handling --------------------------------------------------------

@test "missing token file is refused" {
  rm "$HCLOUD_TOKEN_FILE"
  run "$PROV" --config "$CFG" --pubkey "$KEY.pub"
  [ "$status" -eq 2 ]
  [[ "$output" == *"token"* ]]
  [ ! -s "$FAKE_ARGV" ]
}

@test "token file readable by group/others is refused" {
  chmod 0644 "$HCLOUD_TOKEN_FILE"
  run "$PROV" --config "$CFG" --pubkey "$KEY.pub"
  [ "$status" -eq 2 ]
  [[ "$output" == *"0600"* ]]
  [ ! -s "$FAKE_ARGV" ]
}

@test "token file owned by someone else is refused" {
  [ "$(id -u)" -eq 0 ] && skip "running as root"
  [ -f /etc/hostname ] || skip "no root-owned file to point at"
  HCLOUD_TOKEN_FILE=/etc/hostname run "$PROV" --config "$CFG" --pubkey "$KEY.pub"
  [ "$status" -eq 2 ]
  [[ "$output" == *"owned"* ]]
  [ ! -s "$FAKE_ARGV" ]
}

@test "token with odd characters is refused (header injection)" {
  (umask 077; printf 'abc\r\nX-Evil: 1\n' > "$HCLOUD_TOKEN_FILE")
  run "$PROV" --config "$CFG" --pubkey "$KEY.pub"
  [ "$status" -eq 2 ]
  [ ! -s "$FAKE_ARGV" ]
}

# --- API flow (fake curl) --------------------------------------------------

@test "fresh project: creates key, firewall, server (firewall at create), backups" {
  FAKE_STATE=empty run "$PROV" --config "$CFG" --pubkey "$KEY.pub"
  [ "$status" -eq 0 ]
  got="$(cut -d' ' -f1,2 "$FAKE_LOG" | tr '\n' ';')"
  [[ "$got" == "GET /servers?name=adk-acme-agent;GET /firewalls?name=adk-acme-agent;GET /ssh_keys?name=adk-acme-installer;GET /ssh_keys?fingerprint=$FAKE_FP;POST /ssh_keys;POST /firewalls;POST /servers;GET /actions/44;GET /servers/33;POST /servers/33/actions/enable_backup;GET /actions/45;"* ]]
  srv="$(grep -m1 '^POST /servers ' "$FAKE_LOG")"
  srv="${srv#POST /servers }"
  [ "$(j "$srv" 'd["firewalls"]')" = "[{'firewall': 22}]" ]
  [ "$(j "$srv" 'd["ssh_keys"]')" = "[11]" ]
  [[ "$(j "$srv" 'd["user_data"]')" == "#cloud-config"*"PermitOpen 127.0.0.1:*"* ]]
  [[ "$output" == *"203.0.113.50"* ]]
  [[ "$output" == *"2001:db8:5::1"* ]]
  [[ "$output" == *"bootstrap.sh --identity"*" 203.0.113.50"* ]]
}

@test "token is passed via header file, never in argv or output" {
  FAKE_STATE=empty run "$PROV" --config "$CFG" --pubkey "$KEY.pub"
  [ "$status" -eq 0 ]
  [ -s "$FAKE_ARGV" ]
  no_match -F "$FAKE_TOKEN" "$FAKE_ARGV"
  [[ "$output" != *"$FAKE_TOKEN"* ]]
  grep -q -- '-H @' "$FAKE_ARGV"
}

@test "curl gets -q first (no ~/.curlrc can add -v or --trace)" {
  FAKE_STATE=empty run "$PROV" --config "$CFG" --pubkey "$KEY.pub"
  [ "$status" -eq 0 ]
  [ -s "$FAKE_ARGV" ]
  no_match -v '^-q ' "$FAKE_ARGV"
}

@test "existing setup: idempotent, only the firewall rules are re-applied" {
  FAKE_STATE=existing run "$PROV" --config "$CFG" --pubkey "$KEY.pub"
  [ "$status" -eq 0 ]
  no_match -E '^POST /(ssh_keys|firewalls|servers) ' "$FAKE_LOG"
  no_match 'enable_backup' "$FAKE_LOG"
  no_match 'apply_to_resources' "$FAKE_LOG"
  grep -q '^POST /firewalls/22/actions/set_rules ' "$FAKE_LOG"
  [[ "$output" == *"203.0.113.50"* ]]
}

@test "existing server without --pubkey (handover): no ssh key requests at all" {
  FAKE_STATE=existing run "$PROV" --config "$CFG"
  [ "$status" -eq 0 ]
  no_match 'ssh_keys' "$FAKE_LOG"
  grep -q '^POST /firewalls/22/actions/set_rules ' "$FAKE_LOG"
}

@test "missing server without --pubkey: refused before any change" {
  FAKE_STATE=empty run "$PROV" --config "$CFG"
  [ "$status" -eq 1 ]
  [[ "$output" == *"--pubkey"* ]]
  no_match '^POST' "$FAKE_LOG"
}

@test "existing server without the kit firewall: firewall is applied" {
  FAKE_STATE=nofw run "$PROV" --config "$CFG"
  [ "$status" -eq 0 ]
  b="$(grep -m1 '^POST /firewalls/22/actions/apply_to_resources ' "$FAKE_LOG")"
  b="${b#POST /firewalls/22/actions/apply_to_resources }"
  [ "$(j "$b" 'd["apply_to"]')" = "[{'type': 'server', 'server': {'id': 33}}]" ]
  grep -q '^GET /actions/47$' "$FAKE_LOG"
  [[ "$output" == *"firewall applied"* ]]
}

@test "existing server without backups: backups are enabled" {
  FAKE_STATE=nobackup run "$PROV" --config "$CFG"
  [ "$status" -eq 0 ]
  grep -q '^POST /servers/33/actions/enable_backup$' "$FAKE_LOG"
  grep -q '^GET /actions/45$' "$FAKE_LOG"
}

@test "a second firewall on the server is refused (Hetzner adds up allow rules)" {
  FAKE_STATE=extrafw run "$PROV" --config "$CFG"
  [ "$status" -eq 1 ]
  [[ "$output" == *"99"* ]]
  no_match '^POST' "$FAKE_LOG"
}

@test "server labelled for another customer is not touched" {
  FAKE_STATE=othercustomer run "$PROV" --config "$CFG" --pubkey "$KEY.pub"
  [ "$status" -eq 1 ]
  [[ "$output" == *"customer"* ]]
  no_match '^POST' "$FAKE_LOG"
}

@test "firewall with the kit's name but without label is not touched" {
  FAKE_STATE=fwforeign run "$PROV" --config "$CFG" --pubkey "$KEY.pub"
  [ "$status" -eq 1 ]
  [[ "$output" == *"managed-by"* ]]
  no_match '^POST' "$FAKE_LOG"
}

@test "same key uploaded under another name is reused" {
  FAKE_STATE=fpreuse run "$PROV" --config "$CFG" --pubkey "$KEY.pub"
  [ "$status" -eq 0 ]
  no_match '^POST /ssh_keys' "$FAKE_LOG"
  srv="$(grep -m1 '^POST /servers ' "$FAKE_LOG")"
  srv="${srv#POST /servers }"
  [ "$(j "$srv" 'd["ssh_keys"]')" = "[12]" ]
  [[ "$output" == *"laptop"* ]]
}

@test "failed action is reported" {
  FAKE_STATE=actionerror run "$PROV" --config "$CFG" --pubkey "$KEY.pub"
  [ "$status" -eq 1 ]
  [[ "$output" == *"action 44 failed: boom"* ]]
}

@test "action that never finishes times out" {
  ADK_POLL_MAX=3 FAKE_STATE=actiontimeout run "$PROV" --config "$CFG" --pubkey "$KEY.pub"
  [ "$status" -eq 1 ]
  [[ "$output" == *"did not finish"* ]]
  [ "$(grep -c '^GET /actions/44$' "$FAKE_LOG")" -eq 3 ]
}

@test "non-JSON API response: clear error, no traceback" {
  FAKE_STATE=html run "$PROV" --config "$CFG" --pubkey "$KEY.pub"
  [ "$status" -eq 1 ]
  [[ "$output" == *"502"* ]]
  [[ "$output" == *"not JSON"* ]]
  [[ "$output" != *"Traceback"* ]]
  no_match '^POST' "$FAKE_LOG"
}

@test "non-numeric id from the API is never used in a path" {
  FAKE_STATE=badid run "$PROV" --config "$CFG"
  [ "$status" -eq 1 ]
  [[ "$output" == *"id"* ]]
  no_match '\.\.' "$FAKE_LOG"
  no_match '^POST' "$FAKE_LOG"
}

@test "server with the same name but not managed by the kit is not touched" {
  FAKE_STATE=foreign run "$PROV" --config "$CFG" --pubkey "$KEY.pub"
  [ "$status" -eq 1 ]
  [[ "$output" == *"managed-by"* ]]
  no_match '^POST' "$FAKE_LOG"
}

@test "ssh key name taken by a different key is refused" {
  FAKE_STATE=badkey run "$PROV" --config "$CFG" --pubkey "$KEY.pub"
  [ "$status" -eq 1 ]
  [[ "$output" == *"adk-acme-installer"* ]]
  no_match '^POST' "$FAKE_LOG"
}

@test "API errors are reported without the token" {
  FAKE_STATE=unauthorized run "$PROV" --config "$CFG" --pubkey "$KEY.pub"
  [ "$status" -eq 1 ]
  [[ "$output" == *"401"* ]]
  [[ "$output" == *"unable to authenticate"* ]]
  [[ "$output" != *"$FAKE_TOKEN"* ]]
}
