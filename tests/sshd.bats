#!/usr/bin/env bats
# Effective sshd settings of agent/sshd-adk.conf (sshd -T against a Debian-like main config).
# Skipped where no sshd is installed; the VM integration test checks the real host too.

setup() {
  ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  SSHD="$(command -v sshd || true)"
  [ -n "$SSHD" ] || SSHD=/usr/sbin/sshd
  [ -x "$SSHD" ] || skip "sshd not installed"
  D="$BATS_TEST_TMPDIR/sshd"
  mkdir -p "$D/sshd_config.d"
  ssh-keygen -q -t ed25519 -N '' -f "$D/host_key"
  cp "$ROOT/agent/sshd-adk.conf" "$D/sshd_config.d/10-adk.conf"
  # Debian 13 order: Include first, distribution defaults after it; cloud-init's 50- file.
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

# eff USER: effective configuration for a connection of USER
eff() {
  "$SSHD" -T -f "$D/sshd_config" -h "$D/host_key" -C "user=$1,host=client.example.com,addr=203.0.113.9"
}

@test "drop-in is valid for sshd" {
  run "$SSHD" -t -f "$D/sshd_config" -h "$D/host_key"
  [ "$status" -eq 0 ]
}

@test "no X11, agent, stream-local forwarding or tunnels for any user" {
  for u in hermes adk-admin; do
    run eff "$u"
    [ "$status" -eq 0 ]
    for l in "x11forwarding no" "allowagentforwarding no" "allowstreamlocalforwarding no" \
             "permittunnel no" "passwordauthentication no" "permitrootlogin no" \
             "kbdinteractiveauthentication no" "authorizedkeysfile /etc/ssh/authorized_keys/%u"; do
      grep -qx "$l" <<< "$output" || { echo "$u: missing '$l'"; return 1; }
    done
  done
}

@test "hermes: local forwarding to 127.0.0.1 only" {
  run eff hermes
  [ "$status" -eq 0 ]
  grep -qx "allowtcpforwarding local" <<< "$output"
  grep -qx "permitopen 127.0.0.1:\*" <<< "$output"
}

@test "adk-admin: no TCP forwarding at all" {
  run eff adk-admin
  [ "$status" -eq 0 ]
  grep -qx "allowtcpforwarding no" <<< "$output"
}

@test "only adk-admin and hermes may log in" {
  run eff hermes
  grep -qx "allowusers adk-admin" <<< "$output"
  grep -qx "allowusers hermes" <<< "$output"
  [ "$(grep -c '^allowusers ' <<< "$output")" -eq 2 ]
}

@test "the drop-in ends with a Match all block" {
  [ "$(grep -E '^Match ' "$ROOT/agent/sshd-adk.conf" | tail -n1)" = "Match all" ]
}
