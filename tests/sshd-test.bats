#!/usr/bin/env bats
# Effective sshd settings of test/sshd-adk-test.conf (TEST VM), sshd -T against a Debian-like
# main config. Skipped where no sshd is installed; the lab run checks the real host too.

setup() {
  ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  CONF="$ROOT/test/sshd-adk-test.conf"
  SSHD="$(command -v sshd || true)"
  [ -n "$SSHD" ] || SSHD=/usr/sbin/sshd
}

need_sshd() {
  [ -x "$SSHD" ] || skip "sshd not installed"
  D="$BATS_TEST_TMPDIR/sshd"
  mkdir -p "$D/sshd_config.d"
  ssh-keygen -q -t ed25519 -N '' -f "$D/host_key"
  cp "$CONF" "$D/sshd_config.d/10-adk.conf"
  printf 'PasswordAuthentication yes\n' > "$D/sshd_config.d/50-cloud-init.conf"
  cat > "$D/sshd_config" <<EOF
Include $D/sshd_config.d/*.conf
KbdInteractiveAuthentication no
UsePAM yes
X11Forwarding yes
PrintMotd no
AcceptEnv LANG LC_*
Subsystem sftp /usr/lib/openssh/sftp-server
EOF
}

eff() {
  "$SSHD" -T -f "$D/sshd_config" -h "$D/host_key" -C "user=$1,host=client.example.com,addr=203.0.113.9"
}

# global_part FILE: directive lines before the first Match block (comments dropped)
global_part() {
  awk '/^Match /{exit} /^[A-Za-z]/' "$1"
}

@test "global hardening is the same as on the agent VPS (except AllowUsers)" {
  diff <(global_part "$ROOT/agent/sshd-adk.conf" | grep -v '^AllowUsers') <(global_part "$CONF" | grep -v '^AllowUsers')
}

@test "drop-in is valid for sshd" {
  need_sshd
  run "$SSHD" -t -f "$D/sshd_config" -h "$D/host_key"
  [ "$status" -eq 0 ]
}

@test "only adk-admin and deploy may log in (no hermes on TEST)" {
  need_sshd
  run eff adk-admin
  [ "$status" -eq 0 ]
  grep -qx "allowusers adk-admin" <<< "$output"
  grep -qx "allowusers deploy" <<< "$output"
  [ "$(grep -c '^allowusers ' <<< "$output")" -eq 2 ]
}

@test "deploy: forced gate, no pty, no forwarding of any kind, no user rc" {
  need_sshd
  run eff deploy
  [ "$status" -eq 0 ]
  for l in "forcecommand /opt/adk/test/deploy-gate.sh" "permittty no" "allowtcpforwarding no" \
           "permituserrc no" "permitlisten none" "permitopen none" "x11forwarding no" \
           "allowagentforwarding no" "allowstreamlocalforwarding no" "permittunnel no" \
           "passwordauthentication no" "authorizedkeysfile /etc/ssh/authorized_keys/%u"; do
    grep -qx "$l" <<< "$output" || { echo "deploy: missing '$l'"; return 1; }
  done
}

@test "adk-admin: no forced command, no TCP forwarding" {
  need_sshd
  run eff adk-admin
  [ "$status" -eq 0 ]
  ! grep -q '^forcecommand ' <<< "$output"
  grep -qx "allowtcpforwarding no" <<< "$output"
}

@test "the drop-in ends with a Match all block" {
  [ "$(grep -E '^Match ' "$CONF" | tail -n1)" = "Match all" ]
}
