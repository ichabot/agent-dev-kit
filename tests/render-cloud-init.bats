#!/usr/bin/env bats
# Tests for agent/render-cloud-init.sh

setup() {
  ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  RENDER="$ROOT/agent/render-cloud-init.sh"
  KEY="$BATS_TEST_TMPDIR/installer"
  ssh-keygen -q -t ed25519 -N '' -C 'installer@example.com' -f "$KEY"
}

# y PYTHON_EXPR: evaluate an expression over the parsed cloud-config (variable c)
y() {
  python3 -c 'import sys, yaml; c = yaml.safe_load(sys.stdin.read()); print(eval(sys.argv[1]))' "$1" <<< "$output"
}

need_yaml() {
  python3 -c 'import yaml' 2>/dev/null || skip "python3-yaml not installed"
}

@test "renders a #cloud-config below the 32 KiB user_data limit" {
  run "$RENDER" --pubkey "$KEY.pub"
  [ "$status" -eq 0 ]
  [ "${lines[0]}" = "#cloud-config" ]
  [ "${#output}" -lt 32768 ]
  [[ "$output" != *"@@"* ]]
}

@test "output is valid YAML with the expected structure" {
  need_yaml
  run "$RENDER" --pubkey "$KEY.pub"
  [ "$status" -eq 0 ]
  [ "$(y 'c["disable_root"]')" = "True" ]
  [ "$(y 'c["ssh_pwauth"]')" = "False" ]
  [ "$(y '[u["name"] for u in c["users"]]')" = "['adk-admin']" ]
  [ "$(y 'c["users"][0]["sudo"]')" = "ALL=(ALL) NOPASSWD:ALL" ]
  [ "$(y 'c["users"][0]["shell"]')" = "/bin/bash" ]
  # keys only in the root-owned file, never in the user's home
  [ "$(y '"ssh_authorized_keys" in c["users"][0]')" = "False" ]
}

@test "installer key goes into a root-owned key file" {
  need_yaml
  run "$RENDER" --pubkey "$KEY.pub"
  [ "$status" -eq 0 ]
  f="$(y '[w for w in c["write_files"] if w["path"] == "/etc/ssh/authorized_keys/adk-admin"][0]')"
  [[ "$f" == *"'owner': 'root:root'"* ]]
  [[ "$f" == *"'permissions': '0644'"* ]]
  [[ "$f" == *"$(cut -d' ' -f2 "$KEY.pub")"* ]]
  [[ "$output" == *"install -d -m 0755 -o root -g root /etc/ssh/authorized_keys"* ]]
}

@test "sshd drop-in matches docs/hermes-remote.md" {
  run "$RENDER" --pubkey "$KEY.pub"
  [ "$status" -eq 0 ]
  for l in "PasswordAuthentication no" "KbdInteractiveAuthentication no" "PermitRootLogin no" \
           "AuthorizedKeysFile /etc/ssh/authorized_keys/%u" "AllowTcpForwarding no" \
           "X11Forwarding no" "AllowUsers adk-admin hermes" "Match User hermes" \
           "AllowTcpForwarding local" "PermitOpen 127.0.0.1:*"; do
    [[ "$output" == *"$l"* ]] || { echo "missing: $l"; return 1; }
  done
  [[ "$output" == *"/etc/ssh/sshd_config.d/10-adk.conf"* ]]
}

@test "ssh is restarted (not reloaded) after the config test" {
  run "$RENDER" --pubkey "$KEY.pub"
  [ "$status" -eq 0 ]
  [[ "$output" == *"sshd -t && systemctl restart ssh"* ]]
  [[ "$output" != *"reload ssh"* ]]
}

@test "base packages are installed" {
  need_yaml
  run "$RENDER" --pubkey "$KEY.pub"
  [ "$status" -eq 0 ]
  for p in python3 libatomic1 curl git ca-certificates rsync; do
    [ "$(y "\"$p\" in c[\"packages\"]")" = "True" ] || { echo "missing: $p"; return 1; }
  done
}

@test "write_files only touches files no package owns" {
  need_yaml
  run "$RENDER" --pubkey "$KEY.pub"
  [ "$status" -eq 0 ]
  [ "$(y 'all(w["path"].startswith(("/etc/ssh/sshd_config.d/", "/etc/ssh/authorized_keys/")) for w in c["write_files"])')" = "True" ]
}

@test "key comment with special characters is copied verbatim" {
  need_yaml
  printf '%s %s a&b\\c|d\n' "$(cut -d' ' -f1 "$KEY.pub")" "$(cut -d' ' -f2 "$KEY.pub")" > "$BATS_TEST_TMPDIR/odd.pub"
  run "$RENDER" --pubkey "$BATS_TEST_TMPDIR/odd.pub"
  [ "$status" -eq 0 ]
  [[ "$(y '[w["content"] for w in c["write_files"] if w["path"].endswith("adk-admin")][0]')" == *'a&b\c|d'* ]]
}

@test "missing --pubkey or file is a usage error" {
  run "$RENDER"
  [ "$status" -eq 2 ]
  run "$RENDER" --pubkey "$BATS_TEST_TMPDIR/nope.pub"
  [ "$status" -eq 2 ]
}

@test "private key, garbage and multiple keys are refused" {
  run "$RENDER" --pubkey "$KEY"
  [ "$status" -eq 1 ]
  [[ "$output" != *"PRIVATE"*"cloud-config"* ]]
  printf 'ssh-ed25519 AAAAnotakey\n' > "$BATS_TEST_TMPDIR/bad.pub"
  run "$RENDER" --pubkey "$BATS_TEST_TMPDIR/bad.pub"
  [ "$status" -eq 1 ]
  cat "$KEY.pub" "$KEY.pub" > "$BATS_TEST_TMPDIR/two.pub"
  run "$RENDER" --pubkey "$BATS_TEST_TMPDIR/two.pub"
  [ "$status" -eq 1 ]
  printf 'command="/bin/sh" %s' "$(cat "$KEY.pub")" > "$BATS_TEST_TMPDIR/opts.pub"
  run "$RENDER" --pubkey "$BATS_TEST_TMPDIR/opts.pub"
  [ "$status" -eq 1 ]
}

@test "extra lines after the key are refused or dropped, never rendered" {
  printf '%s %s x\n  - path: /etc/evil\n' "$(cut -d' ' -f1 "$KEY.pub")" "$(cut -d' ' -f2 "$KEY.pub")" > "$BATS_TEST_TMPDIR/inj.pub"
  run "$RENDER" --pubkey "$BATS_TEST_TMPDIR/inj.pub"
  [ "$status" -eq 1 ]
  printf '%s\n#runcmd: evil\n' "$(cat "$KEY.pub")" > "$BATS_TEST_TMPDIR/comment.pub"
  run "$RENDER" --pubkey "$BATS_TEST_TMPDIR/comment.pub"
  [ "$status" -eq 0 ]
  [[ "$output" != *"evil"* ]]
}
