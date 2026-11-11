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
