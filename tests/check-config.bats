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
    K="$1" V="$2" awk 'index($0, ENVIRON["K"]"=")==1 {print ENVIRON["K"]"="ENVIRON["V"]; next} {print}' "$CFG" > "$tmp"
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
  actual="$(grep -oE '^[A-Z][A-Z0-9_]*=' "$ROOT/kit.env.example" | tr -d '=' | sort)"
  [ "$expected" = "$actual" ]
}

@test "unfilled kit.env.example fails only on empty values" {
  run "$CHECK" "$ROOT/kit.env.example"
  [ "$status" -eq 1 ]
  [[ "$output" == *"empty"* ]]
  [[ "$output" != *"not a KEY=VALUE"* ]]
  [[ "$output" != *"unknown key"* ]]
  [[ "$output" != *"duplicate"* ]]
}

# --- firewall source networks -------------------------------------------

@test "CUSTOMER_IPS: host bits set (prefix typo) are rejected" {
  set_var CUSTOMER_IPS "203.0.113.10/2"
  run "$CHECK" "$CFG"
  [ "$status" -eq 1 ]
  [[ "$output" == *"203.0.113.10/2"* ]]
}

@test "CUSTOMER_IPS: split any-address halves are rejected" {
  set_var CUSTOMER_IPS "0.0.0.0/1,128.0.0.0/1"
  run "$CHECK" "$CFG"
  [ "$status" -eq 1 ]
  set_var CUSTOMER_IPS "::/1,8000::/1"
  run "$CHECK" "$CFG"
  [ "$status" -eq 1 ]
}

@test "CUSTOMER_IPS: too broad prefixes are rejected" {
  set_var CUSTOMER_IPS "8.8.0.0/16"
  run "$CHECK" "$CFG"
  [ "$status" -eq 1 ]
  [[ "$output" == *"too broad"* ]]
  set_var CUSTOMER_IPS "2a01::/32"
  run "$CHECK" "$CFG"
  [ "$status" -eq 1 ]
}

@test "CUSTOMER_IPS: non-public addresses are rejected" {
  for n in 127.0.0.1 0.0.0.0 172.16.0.0/24 10.0.0.1 224.0.0.0/24 169.254.1.1 ::1 fe80::1 ::ffff:203.0.113.1 fd00::/48; do
    set_var CUSTOMER_IPS "$n"
    run "$CHECK" "$CFG"
    [ "$status" -eq 1 ] || { echo "accepted: $n"; return 1; }
  done
}

@test "CUSTOMER_IPS: only separators is rejected" {
  set_var CUSTOMER_IPS ",,"
  run "$CHECK" "$CFG"
  [ "$status" -eq 1 ]
  [[ "$output" == *"CUSTOMER_IPS"* ]]
}

@test "CUSTOMER_IPS: ipaddress.py in the working dir is not imported" {
  marker="$BATS_TEST_TMPDIR/pwned"
  mkdir -p "$BATS_TEST_TMPDIR/evil"
  printf 'open(%s, "w").close()\n' "'$marker'" > "$BATS_TEST_TMPDIR/evil/ipaddress.py"
  cd "$BATS_TEST_TMPDIR/evil"
  run "$CHECK" "$CFG"
  [ ! -e "$marker" ]
}

# --- parser --------------------------------------------------------------

@test "CRLF line endings are accepted" {
  sed -i 's/$/\r/' "$CFG"
  run "$CHECK" "$CFG"
  [ "$status" -eq 0 ]
}

@test "file without trailing newline is accepted" {
  printf '%s' "$(cat "$CFG")" > "$CFG.tmp" && mv "$CFG.tmp" "$CFG"
  run "$CHECK" "$CFG"
  [ "$status" -eq 0 ]
}

@test "duplicate key is rejected" {
  printf 'CUSTOMER_IPS=0.0.0.0/1\n' >> "$CFG"
  run "$CHECK" "$CFG"
  [ "$status" -eq 1 ]
  [[ "$output" == *"duplicate"* ]]
}

@test "export prefix gets a clear message" {
  sed -i 's/^VPN_PORT=/export VPN_PORT=/' "$CFG"
  run "$CHECK" "$CFG"
  [ "$status" -eq 1 ]
  [[ "$output" == *"export"* ]]
}

@test "quoted values are rejected with a clear message" {
  set_var GITEA_DOMAIN '"git.example.com"'
  run "$CHECK" "$CFG"
  [ "$status" -eq 1 ]
  [[ "$output" == *"quotes"* ]]
}

@test "tab before inline comment is accepted" {
  set_var VPN_PORT "$(printf '51820\t# wireguard')"
  run "$CHECK" "$CFG"
  [ "$status" -eq 0 ]
}

# --- formats ---------------------------------------------------------------

@test "non-ASCII letters are rejected regardless of locale" {
  set_var CUSTOMER_NAME "müller"
  LC_ALL=C.UTF-8 run "$CHECK" "$CFG"
  [ "$status" -eq 1 ]
  set_var CUSTOMER_NAME "acme"
  set_var GITEA_DOMAIN "git.bücher.de"
  LC_ALL=C.UTF-8 run "$CHECK" "$CFG"
  [ "$status" -eq 1 ]
}

@test "uppercase domain gets a lowercase hint" {
  set_var GITEA_DOMAIN "Git.Example.com"
  run "$CHECK" "$CFG"
  [ "$status" -eq 1 ]
  [[ "$output" == *"lowercase"* ]]
}

@test "CUSTOMER_NAME must not end with a hyphen" {
  set_var CUSTOMER_NAME "acme-"
  run "$CHECK" "$CFG"
  [ "$status" -eq 1 ]
}

@test "VPN_PORT 0 is rejected" {
  set_var VPN_PORT 0
  run "$CHECK" "$CFG"
  [ "$status" -eq 1 ]
}

@test "BACKUP_TARGET with password or odd characters is rejected" {
  set_var BACKUP_TARGET "sftp://u:secret@host.example.com/x"
  run "$CHECK" "$CFG"
  [ "$status" -eq 1 ]
  set_var BACKUP_TARGET "sftp://u@host.example.com/x;id"
  run "$CHECK" "$CFG"
  [ "$status" -eq 1 ]
  set_var BACKUP_TARGET "sftp://u123@u123.your-storagebox.de:23/backups/acme"
  run "$CHECK" "$CFG"
  [ "$status" -eq 0 ]
}

@test "DNS_PROVIDER and server types use safe characters" {
  set_var DNS_PROVIDER "hetzner;x"
  run "$CHECK" "$CFG"
  [ "$status" -eq 1 ]
  set_var DNS_PROVIDER "hetzner"
  set_var AGENT_TYPE "CX33"
  run "$CHECK" "$CFG"
  [ "$status" -eq 1 ]
}

# --- usage -----------------------------------------------------------------

@test "defaults to kit.env in the working directory" {
  [ "$(basename "$CFG")" = "kit.env" ]
  cd "$(dirname "$CFG")"
  run "$CHECK"
  [ "$status" -eq 0 ]
}

@test "unreadable file exits 2" {
  [ "$(id -u)" -eq 0 ] && skip "root can read everything"
  chmod 000 "$CFG"
  run "$CHECK" "$CFG"
  [ "$status" -eq 2 ]
}

@test "unknown option and extra arguments exit 2" {
  run "$CHECK" --frobnicate
  [ "$status" -eq 2 ]
  run "$CHECK" "$CFG" extra
  [ "$status" -eq 2 ]
}
