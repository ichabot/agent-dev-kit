#!/usr/bin/env bats
# Tests for agent/firewall-rules.sh

setup() {
  ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  FW="$ROOT/agent/firewall-rules.sh"
  CFG="$BATS_TEST_TMPDIR/kit.env"
  cp "$ROOT/tests/fixtures/valid.env" "$CFG"
}

set_var() {
  local tmp="$CFG.tmp"
  K="$1" V="$2" awk 'index($0, ENVIRON["K"]"=")==1 {print ENVIRON["K"]"="ENVIRON["V"]; next} {print}' "$CFG" > "$tmp"
  mv "$tmp" "$CFG"
}

# q PYTHON_EXPR: evaluate an expression over the parsed rules (variable r) from $output
q() {
  python3 -I -c 'import json, sys; r = json.loads(sys.stdin.read()); print(eval(sys.argv[1]))' "$1" <<< "$output"
}

@test "prints valid JSON rules for the valid config" {
  run "$FW" --config "$CFG"
  [ "$status" -eq 0 ]
  [ "$(q 'len(r)')" -eq 4 ]
}

@test "inbound only and every rule has a description" {
  run "$FW" --config "$CFG"
  [ "$status" -eq 0 ]
  [ "$(q 'all(x["direction"] == "in" for x in r)')" = "True" ]
  [ "$(q 'all(len(x.get("description", "")) > 0 for x in r)')" = "True" ]
  [ "$(q 'all(len(x["description"]) <= 255 for x in r)')" = "True" ]
}

@test "ssh, https, vpn and icmp are limited to CUSTOMER_IPS (normalized)" {
  run "$FW" --config "$CFG"
  [ "$status" -eq 0 ]
  expected="['203.0.113.10/32', '198.51.100.0/29', '2001:db8::/48']"
  [ "$(q '[x["source_ips"] for x in r if x["protocol"] == "tcp" and x["port"] == "22"][0]')" = "$expected" ]
  [ "$(q '[x["source_ips"] for x in r if x["protocol"] == "tcp" and x["port"] == "443"][0]')" = "$expected" ]
  [ "$(q '[x["source_ips"] for x in r if x["protocol"] == "udp" and x["port"] == "51820"][0]')" = "$expected" ]
  [ "$(q '[x["source_ips"] for x in r if x["protocol"] == "icmp"][0]')" = "$expected" ]
  [ "$(q '"port" in [x for x in r if x["protocol"] == "icmp"][0]')" = "False" ]
}

@test "bare IPs become /32 and /128" {
  set_var CUSTOMER_IPS "203.0.113.7, 2001:db8::1"
  run "$FW" --config "$CFG"
  [ "$status" -eq 0 ]
  [ "$(q 'r[0]["source_ips"]')" = "['203.0.113.7/32', '2001:db8::1/128']" ]
}

@test "VPN_PROTO tcp is honored" {
  set_var VPN_PROTO tcp
  set_var VPN_PORT 1194
  run "$FW" --config "$CFG"
  [ "$status" -eq 0 ]
  [ "$(q 'len([x for x in r if x["protocol"] == "tcp" and x["port"] == "1194"])')" -eq 1 ]
}

@test "dns01: nothing is open to the world" {
  run "$FW" --config "$CFG"
  [ "$status" -eq 0 ]
  [[ "$output" != *"0.0.0.0/0"* ]]
  [[ "$output" != *"::/0"* ]]
  [ "$(q 'len([x for x in r if x.get("port") == "80"])')" -eq 0 ]
}

@test "http01: port 80 is the only world-open rule, with a reason" {
  set_var ACME_MODE http01
  run "$FW" --config "$CFG"
  [ "$status" -eq 0 ]
  [ "$(q '[x["source_ips"] for x in r if x.get("port") == "80"][0]')" = "['0.0.0.0/0', '::/0']" ]
  [ "$(q 'len([x for x in r if "0.0.0.0/0" in x["source_ips"] or "::/0" in x["source_ips"]])')" -eq 1 ]
  [[ "$(q '[x["description"] for x in r if x.get("port") == "80"][0]')" == *"ACME"* ]]
}

@test "--admin-source adds a separate ssh rule (repeatable)" {
  run "$FW" --config "$CFG" --admin-source 198.51.100.77 --admin-source 2001:db8:1::/64
  [ "$status" -eq 0 ]
  [ "$(q 'len([x for x in r if x.get("port") == "22"])')" -eq 2 ]
  [ "$(q '[x["source_ips"] for x in r if x.get("port") == "22"][1]')" = "['198.51.100.77/32', '2001:db8:1::/64']" ]
  [[ "$(q '[x["description"] for x in r if x.get("port") == "22"][1]')" == *"handover"* ]]
}

@test "--admin-source uses the CUSTOMER_IPS rules (public, min prefix)" {
  for n in 0.0.0.0/0 ::/0 10.0.0.1 172.16.0.0/24 8.8.0.0/16 203.0.113.10/2 nonsense; do
    run "$FW" --config "$CFG" --admin-source "$n"
    [ "$status" -ne 0 ] || { echo "accepted: $n"; return 1; }
    [[ "$output" == *"admin-source"* ]] || { echo "no hint for $n: $output"; return 1; }
  done
}

@test "invalid config is refused, no JSON printed" {
  set_var CUSTOMER_IPS "0.0.0.0/0"
  run "$FW" --config "$CFG"
  [ "$status" -eq 1 ]
  [[ "$output" == *"CUSTOMER_IPS"* ]]
  [[ "$output" != *"source_ips"* ]]
}

@test "tcp VPN port colliding with ssh/https/http is refused" {
  set_var VPN_PROTO tcp
  set_var VPN_PORT 443
  run "$FW" --config "$CFG"
  [ "$status" -eq 1 ]
  [[ "$output" == *"VPN_PORT"* ]]
}

@test "unknown option and missing config exit 2" {
  run "$FW" --frobnicate
  [ "$status" -eq 2 ]
  run "$FW" --config "$BATS_TEST_TMPDIR/nope.env"
  [ "$status" -eq 2 ]
  run "$FW" --config "$CFG" --admin-source
  [ "$status" -eq 2 ]
}

@test "ipaddress.py in the working dir is not imported" {
  marker="$BATS_TEST_TMPDIR/pwned"
  mkdir -p "$BATS_TEST_TMPDIR/evil"
  printf 'open(%s, "w").close()\n' "'$marker'" > "$BATS_TEST_TMPDIR/evil/ipaddress.py"
  cp "$BATS_TEST_TMPDIR/evil/ipaddress.py" "$BATS_TEST_TMPDIR/evil/json.py"
  cd "$BATS_TEST_TMPDIR/evil"
  run "$FW" --config "$CFG"
  [ "$status" -eq 0 ]
  [ ! -e "$marker" ]
}
