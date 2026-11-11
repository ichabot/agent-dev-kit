#!/usr/bin/env bats
# Tests for scripts/check-config.sh

setup() {
  ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  CHECK="$ROOT/scripts/check-config.sh"
  CFG="$BATS_TEST_TMPDIR/kit.env"
  cp "$ROOT/tests/fixtures/valid.env" "$CFG"
}

# set_var KEY VALUE: replace (or append) KEY in the test config
set_var() {
  if grep -q "^$1=" "$CFG"; then
    local tmp="$CFG.tmp"
    awk -v k="$1" -v v="$2" 'index($0, k"=")==1 {print k"="v; next} {print}' "$CFG" > "$tmp"
    mv "$tmp" "$CFG"
  else
    printf '%s=%s\n' "$1" "$2" >> "$CFG"
  fi
}

@test "valid config passes" {
  run "$CHECK" "$CFG"
  [ "$status" -eq 0 ]
  [[ "$output" == *"OK"* ]]
}

@test "missing file exits 2" {
  run "$CHECK" "$BATS_TEST_TMPDIR/nope.env"
  [ "$status" -eq 2 ]
  [[ "$output" == *"not found"* ]]
}

@test "empty required value is reported by name" {
  set_var GITEA_DOMAIN ""
  run "$CHECK" "$CFG"
  [ "$status" -eq 1 ]
  [[ "$output" == *"GITEA_DOMAIN"* ]]
}

@test "missing required key is reported" {
  grep -v '^TEST_TYPE=' "$CFG" > "$CFG.tmp" && mv "$CFG.tmp" "$CFG"
  run "$CHECK" "$CFG"
  [ "$status" -eq 1 ]
  [[ "$output" == *"TEST_TYPE"* ]]
}

@test "all errors are listed, not only the first" {
  set_var GITEA_DOMAIN ""
  set_var VPN_PORT "abc"
  run "$CHECK" "$CFG"
  [ "$status" -eq 1 ]
  [[ "$output" == *"GITEA_DOMAIN"* ]]
  [[ "$output" == *"VPN_PORT"* ]]
}

@test "IPv4 any-address is rejected" {
  set_var CUSTOMER_IPS "0.0.0.0/0"
  run "$CHECK" "$CFG"
  [ "$status" -eq 1 ]
  [[ "$output" == *"CUSTOMER_IPS"* ]]
}

@test "IPv6 any-address is rejected" {
  set_var CUSTOMER_IPS "203.0.113.10/32,::/0"
  run "$CHECK" "$CFG"
  [ "$status" -eq 1 ]
  [[ "$output" == *"::/0"* ]]
}

@test "invalid CIDR is rejected" {
  set_var CUSTOMER_IPS "203.0.113.300/32"
  run "$CHECK" "$CFG"
  [ "$status" -eq 1 ]
  [[ "$output" == *"203.0.113.300/32"* ]]
}

@test "bare IP without prefix is accepted" {
  set_var CUSTOMER_IPS "203.0.113.10"
  run "$CHECK" "$CFG"
  [ "$status" -eq 0 ]
}

@test "VPN_PORT out of range is rejected" {
  set_var VPN_PORT 70000
  run "$CHECK" "$CFG"
  [ "$status" -eq 1 ]
  [[ "$output" == *"VPN_PORT"* ]]
}

@test "VPN_PROTO must be udp or tcp" {
  set_var VPN_PROTO icmp
  run "$CHECK" "$CFG"
  [ "$status" -eq 1 ]
  [[ "$output" == *"VPN_PROTO"* ]]
}

@test "invalid domain is rejected" {
  set_var TEST_DOMAIN "test_example"
  run "$CHECK" "$CFG"
  [ "$status" -eq 1 ]
  [[ "$output" == *"TEST_DOMAIN"* ]]
}

@test "invalid e-mail is rejected" {
  set_var ACME_EMAIL "admin.example.com"
  run "$CHECK" "$CFG"
  [ "$status" -eq 1 ]
  [[ "$output" == *"ACME_EMAIL"* ]]
}

@test "dns01 requires DNS_PROVIDER" {
  set_var DNS_PROVIDER ""
  run "$CHECK" "$CFG"
  [ "$status" -eq 1 ]
  [[ "$output" == *"DNS_PROVIDER"* ]]
}

@test "http01 works without DNS_PROVIDER" {
  set_var ACME_MODE http01
  set_var DNS_PROVIDER ""
  run "$CHECK" "$CFG"
  [ "$status" -eq 0 ]
}

@test "unknown ACME_MODE is rejected" {
  set_var ACME_MODE tls
  run "$CHECK" "$CFG"
  [ "$status" -eq 1 ]
  [[ "$output" == *"ACME_MODE"* ]]
}

@test "invalid CUSTOMER_NAME is rejected" {
  set_var CUSTOMER_NAME "Acme Corp"
  run "$CHECK" "$CFG"
  [ "$status" -eq 1 ]
  [[ "$output" == *"CUSTOMER_NAME"* ]]
}

@test "BACKUP_TARGET must be sftp:// when set" {
  set_var BACKUP_TARGET "ftp://host/backups"
  run "$CHECK" "$CFG"
  [ "$status" -eq 1 ]
  [[ "$output" == *"BACKUP_TARGET"* ]]
  set_var BACKUP_TARGET "sftp://u123@u123.your-storagebox.de/backups"
  run "$CHECK" "$CFG"
  [ "$status" -eq 0 ]
}

@test "unknown key is rejected (typo protection)" {
  set_var GITEA_DOMIAN "git.example.com"
  run "$CHECK" "$CFG"
  [ "$status" -eq 1 ]
  [[ "$output" == *"GITEA_DOMIAN"* ]]
}

@test "values are never executed" {
  marker="$BATS_TEST_TMPDIR/pwned"
  set_var CUSTOMER_NAME "\$(touch $marker)"
  run "$CHECK" "$CFG"
  [ "$status" -eq 1 ]
  [ ! -e "$marker" ]
}

@test "kit.env.example lists exactly the known keys" {
  run "$CHECK" --list-keys
  [ "$status" -eq 0 ]
  expected="$(printf '%s\n' "${lines[@]}" | sort)"
  actual="$(grep -oE '^[A-Z_]+=' "$ROOT/kit.env.example" | tr -d '=' | sort)"
  [ "$expected" = "$actual" ]
}

@test "unfilled kit.env.example fails" {
  run "$CHECK" "$ROOT/kit.env.example"
  [ "$status" -eq 1 ]
}
