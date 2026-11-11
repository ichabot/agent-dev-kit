#!/usr/bin/env bats
# Tests for agent/lib/services.sh decisions that need no root: Caddy's env file with the DNS
# token and what happens to the running services when files change.
# shellcheck disable=SC2034,SC2317,SC2016  # globals/stubs used by the sourced library; literal $

setup() {
  ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  # shellcheck disable=SC1091  # linted on their own (make lint)
  source "$ROOT/agent/lib/host.sh"
  # shellcheck disable=SC1091
  source "$ROOT/agent/lib/services.sh"
  ADK_SECRETS_DIR="$BATS_TEST_TMPDIR/secrets"
  mkdir -p "$ADK_SECRETS_DIR"
  # adk_put_file without the root-only owner change
  adk_put_file() {
    local path="$1" tmp
    tmp="$(mktemp)"
    cat > "$tmp"
    if [[ -f "$path" ]] && cmp -s "$tmp" "$path"; then rm -f "$tmp"; adk_ok "$path"; return 1; fi
    mv "$tmp" "$path"
    chmod "$2" "$path"
    adk_changed "$path"
  }
}

@test "caddy env: the token is written single-quoted (no compose interpolation of \$)" {
  printf 'ab$cd"ef\\gh' > "$ADK_SECRETS_DIR/dns-api-token"
  adk_caddy_env dns01 > /dev/null
  [ "$(cat "$ADK_SECRETS_DIR/caddy.env")" = "DNS_API_TOKEN='ab\$cd\"ef\\gh'" ]
  [ "$(stat -c %a "$ADK_SECRETS_DIR/caddy.env")" = "600" ]
  [ "$ADK_CADDY_ENV_CHANGED" = true ]
}

@test "caddy env: a token with a single quote is refused" {
  printf "ab'cd" > "$ADK_SECRETS_DIR/dns-api-token"
  run adk_caddy_env dns01
  [ "$status" -ne 0 ]
  [[ "$output" == *"single quote"* ]]
  [[ "$output" != *"ab'cd"* ]]
  [ ! -e "$ADK_SECRETS_DIR/caddy.env" ]
}

@test "caddy env: unchanged token -> not changed; rotated token -> changed" {
  printf 'one' > "$ADK_SECRETS_DIR/dns-api-token"
  adk_caddy_env dns01 > /dev/null
  adk_caddy_env dns01 > /dev/null
  [ "$ADK_CADDY_ENV_CHANGED" = false ]
  printf 'two' > "$ADK_SECRETS_DIR/dns-api-token"
  adk_caddy_env dns01 > /dev/null
  [ "$ADK_CADDY_ENV_CHANGED" = true ]
}

@test "caddy env: http01 removes the file" {
  printf 'x' > "$ADK_SECRETS_DIR/caddy.env"
  adk_caddy_env http01 > /dev/null
  [ ! -e "$ADK_SECRETS_DIR/caddy.env" ]
  [ "$ADK_CADDY_ENV_CHANGED" = true ]
}

@test "services action: a rotated DNS token recreates caddy (restart would keep the old env)" {
  [ "$(adk_services_action 'caddy gitea ' false false true)" = "recreate-caddy" ]
  # Caddyfile and token both changed: recreate covers the Caddyfile as well
  [ "$(adk_services_action 'caddy gitea ' false true true)" = "recreate-caddy" ]
}

@test "services action: compose change or a stopped service -> up; Caddyfile only -> restart" {
  [ "$(adk_services_action 'caddy gitea ' true false false)" = "up" ]
  [ "$(adk_services_action 'gitea ' false false true)" = "up" ]
  [ "$(adk_services_action '' false false false)" = "up" ]
  [ "$(adk_services_action 'caddy gitea ' false true false)" = "restart-caddy" ]
  [ "$(adk_services_action 'caddy gitea ' false false false)" = "none" ]
}

@test "host key pinning keeps only the scanned key with the confirmed fingerprint" {
  ssh-keygen -q -t ed25519 -N '' -f "$BATS_TEST_TMPDIR/hk1"
  ssh-keygen -q -t ecdsa -N '' -f "$BATS_TEST_TMPDIR/hk2"
  scan="$(printf '# box:23 SSH-2.0\n[box.example.com]:23 %s\n[box.example.com]:23 %s\n' \
    "$(cut -d' ' -f1,2 "$BATS_TEST_TMPDIR/hk1.pub")" "$(cut -d' ' -f1,2 "$BATS_TEST_TMPDIR/hk2.pub")")"
  fp="$(ssh-keygen -l -E sha256 -f "$BATS_TEST_TMPDIR/hk2.pub" | awk '{print $2}')"
  run adk_hostkey_matching "$fp" <<< "$scan"
  [ "$status" -eq 0 ]
  [ "$output" = "[box.example.com]:23 $(cut -d' ' -f1,2 "$BATS_TEST_TMPDIR/hk2.pub")" ]
  run adk_hostkey_matching "SHA256:AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA" <<< "$scan"
  [ -z "$output" ]
}

@test "backup target parts: user@host, port (default 22) and path" {
  [ "$(adk_backup_target_parts sftp://u1@box.example.com:23/backups/adk)" = "u1@box.example.com 23 /backups/adk" ]
  [ "$(adk_backup_target_parts sftp://u1@box.example.com)" = "u1@box.example.com 22 ." ]
}

@test "backup keys: the .pub is always derived from the private key (missing, replaced, symlinked)" {
  # shellcheck disable=SC1091  # the real adk_put_file (with its symlink check)
  source "$ROOT/agent/lib/host.sh"
  k="$BATS_TEST_TMPDIR/adk-backup-sign"
  ssh-keygen -q -t ed25519 -N '' -C sign -f "$k"
  ssh-keygen -q -t ed25519 -N '' -C other -f "$BATS_TEST_TMPDIR/other"
  want="$(ssh-keygen -y -f "$k")"
  cp "$BATS_TEST_TMPDIR/other.pub" "$k.pub"
  run adk_pub_from_private "$k"
  [ "$status" -eq 0 ]
  [ "$(cat "$k.pub")" = "$want" ]
  rm "$k.pub"
  adk_pub_from_private "$k" > /dev/null
  [ "$(cat "$k.pub")" = "$want" ]
  run adk_pub_from_private "$k"
  [[ "$output" == "ok: "* ]]
  rm "$k.pub"
  ln -s "$BATS_TEST_TMPDIR/other.pub" "$k.pub"
  run adk_pub_from_private "$k"
  [ "$status" -ne 0 ]
  [ "$(cut -d' ' -f3 "$BATS_TEST_TMPDIR/other.pub")" = "other" ]
}
