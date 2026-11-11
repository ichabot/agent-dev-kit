#!/usr/bin/env bats
# Tests for agent/render-services.sh (compose.yaml, Caddyfile, Caddy Dockerfile, runner config)

setup() {
  ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  RENDER="$ROOT/agent/render-services.sh"
  CFG="$BATS_TEST_TMPDIR/kit.env"
  OUT="$BATS_TEST_TMPDIR/out"
  mkdir -p "$OUT"
  cp "$ROOT/tests/fixtures/valid.env" "$CFG"
  unset ADK_TLS_INTERNAL ADK_RUNNER_ADD_HOST
}

set_var() {
  K="$1" V="$2" awk 'index($0, ENVIRON["K"]"=")==1 {print ENVIRON["K"]"="ENVIRON["V"]; next} {print}' "$CFG" > "$CFG.tmp"
  mv "$CFG.tmp" "$CFG"
}

# refute CMD...: fail if CMD succeeds (a bare "! cmd" does not fail a bats test)
refute() {
  if "$@"; then return 1; fi
}

# code FILE: the file without comment lines
code() { grep -vE '^[[:space:]]*#' "$1"; }

need_yaml() {
  python3 -c 'import yaml' 2>/dev/null || skip "python3-yaml not installed"
}

# y FILE PYTHON_EXPR: evaluate an expression over the parsed YAML file (variable c)
y() {
  python3 -c 'import sys, yaml; c = yaml.safe_load(open(sys.argv[1])); print(eval(sys.argv[2]))' "$1" "$2"
}

@test "renders all files for dns01 without placeholders left" {
  run "$RENDER" --config "$CFG" --out "$OUT"
  [ "$status" -eq 0 ]
  [ -f "$OUT/compose.yaml" ]
  [ -f "$OUT/Caddyfile" ]
  [ -f "$OUT/caddy/Dockerfile" ]
  [ -f "$OUT/runner.yaml" ]
  refute grep -rq '@@' "$OUT"
}

@test "Caddyfile: admin API off, DNS-01 with the token from the environment" {
  "$RENDER" --config "$CFG" --out "$OUT"
  grep -qx '	admin off' "$OUT/Caddyfile"
  grep -qx '	email admin@example.com' "$OUT/Caddyfile"
  grep -qx '	acme_dns hetzner {env.DNS_API_TOKEN}' "$OUT/Caddyfile"
  grep -qx 'git.example.com {' "$OUT/Caddyfile"
  refute grep -q 'tls internal' "$OUT/Caddyfile"
  code "$OUT/Caddyfile" > "$OUT/Caddyfile.code"
  refute grep -q '2019' "$OUT/Caddyfile.code"
}

@test "Caddyfile: security headers and a plain reverse proxy to gitea:3000" {
  "$RENDER" --config "$CFG" --out "$OUT"
  grep -q 'Strict-Transport-Security "max-age=31536000"' "$OUT/Caddyfile"
  grep -q 'X-Content-Type-Options "nosniff"' "$OUT/Caddyfile"
  grep -q 'X-Frame-Options "DENY"' "$OUT/Caddyfile"
  grep -q 'Referrer-Policy "strict-origin-when-cross-origin"' "$OUT/Caddyfile"
  grep -qE '^		-Server$' "$OUT/Caddyfile"
  grep -q 'reverse_proxy gitea:3000' "$OUT/Caddyfile"
  # no body size limit anywhere (registry layers can be large)
  code "$OUT/Caddyfile" > "$OUT/Caddyfile.code"
  refute grep -q 'max_size' "$OUT/Caddyfile.code"
  refute grep -q 'request_body' "$OUT/Caddyfile.code"
}

@test "Caddyfile: http01 has no DNS challenge" {
  set_var ACME_MODE http01
  set_var DNS_PROVIDER ""
  "$RENDER" --config "$CFG" --out "$OUT"
  refute grep -q 'acme_dns' "$OUT/Caddyfile"
  grep -qx '	admin off' "$OUT/Caddyfile"
  [ ! -e "$OUT/caddy/Dockerfile" ]
}

@test "ADK_TLS_INTERNAL=1 switches to Caddy's internal CA (lab only)" {
  ADK_TLS_INTERNAL=1 "$RENDER" --config "$CFG" --out "$OUT"
  grep -qx '	tls internal' "$OUT/Caddyfile"
  refute grep -q 'acme_dns' "$OUT/Caddyfile"
}

@test "ADK_TLS_INTERNAL accepts only 1 or empty" {
  ADK_TLS_INTERNAL=yes run "$RENDER" --config "$CFG" --out "$OUT"
  [ "$status" -eq 2 ]
  [[ "$output" == *"ADK_TLS_INTERNAL"* ]]
}

@test "ADK_TLS_INTERNAL and ADK_RUNNER_ADD_HOST are not kit.env keys" {
  run "$ROOT/scripts/check-config.sh" --list-keys
  [[ "$output" != *"ADK_"* ]]
  refute grep -q 'ADK_' "$ROOT/kit.env.example"
}

@test "compose: Gitea has no host port, Caddy publishes only 443 for dns01" {
  need_yaml
  "$RENDER" --config "$CFG" --out "$OUT"
  [ "$(y "$OUT/compose.yaml" '"ports" in c["services"]["gitea"]')" = "False" ]
  [ "$(y "$OUT/compose.yaml" '"network_mode" in c["services"]["gitea"]')" = "False" ]
  [ "$(y "$OUT/compose.yaml" 'c["services"]["caddy"]["ports"]')" = "['443:443/tcp']" ]
  [ "$(y "$OUT/compose.yaml" 'sorted(c["services"])')" = "['caddy', 'gitea']" ]
}

@test "compose: http01 publishes 80 and 443, stock Caddy image" {
  need_yaml
  set_var ACME_MODE http01
  set_var DNS_PROVIDER ""
  "$RENDER" --config "$CFG" --out "$OUT"
  [ "$(y "$OUT/compose.yaml" 'c["services"]["caddy"]["ports"]')" = "['80:80/tcp', '443:443/tcp']" ]
  [ "$(y "$OUT/compose.yaml" '"build" in c["services"]["caddy"]')" = "False" ]
  [[ "$(y "$OUT/compose.yaml" 'c["services"]["caddy"]["image"]')" == docker.io/library/caddy:2.*@sha256:* ]]
  [ "$(y "$OUT/compose.yaml" '"env_file" in c["services"]["caddy"]')" = "False" ]
}

@test "compose: every pulled image is pinned by tag and digest" {
  need_yaml
  "$RENDER" --config "$CFG" --out "$OUT"
  [[ "$(y "$OUT/compose.yaml" 'c["services"]["gitea"]["image"]')" =~ ^docker\.io/gitea/gitea:[0-9.]+@sha256:[0-9a-f]{64}$ ]]
  grep -qE '^FROM docker\.io/library/caddy:[0-9.]+-builder-alpine@sha256:[0-9a-f]{64} AS builder$' "$OUT/caddy/Dockerfile"
  grep -qE '^FROM docker\.io/library/caddy:[0-9.]+-alpine@sha256:[0-9a-f]{64}$' "$OUT/caddy/Dockerfile"
  grep -qE '^RUN xcaddy build v[0-9.]+ --with github\.com/caddy-dns/hetzner/v2@v[0-9.]+$' "$OUT/caddy/Dockerfile"
  # the locally built image is tagged with a hash of its Dockerfile (rebuild on change)
  [[ "$(y "$OUT/compose.yaml" 'c["services"]["caddy"]["image"]')" =~ ^adk/caddy-hetzner:[0-9.]+-[0-9a-f]{12}$ ]]
  [ "$(y "$OUT/compose.yaml" 'c["services"]["caddy"]["env_file"]')" = "['/opt/adk/secrets/caddy.env']" ]
}

@test "compose: Gitea settings (HTTPS only, no registration, sign-in, actions, packages)" {
  need_yaml
  "$RENDER" --config "$CFG" --out "$OUT"
  e() { y "$OUT/compose.yaml" "c['services']['gitea']['environment']['$1']"; }
  [ "$(e GITEA__server__ROOT_URL)" = "https://git.example.com/" ]
  [ "$(e GITEA__server__DOMAIN)" = "git.example.com" ]
  [ "$(e GITEA__server__DISABLE_SSH)" = "true" ]
  [ "$(e GITEA__server__START_SSH_SERVER)" = "false" ]
  [ "$(e GITEA__security__INSTALL_LOCK)" = "true" ]
  [ "$(e GITEA__service__DISABLE_REGISTRATION)" = "true" ]
  [ "$(e GITEA__service__REQUIRE_SIGNIN_VIEW)" = "true" ]
  [ "$(e GITEA__actions__ENABLED)" = "true" ]
  [ "$(e GITEA__packages__ENABLED)" = "true" ]
  [ "$(e GITEA__database__DB_TYPE)" = "sqlite3" ]
  [ "$(e GITEA__security__SECRET_KEY__FILE)" = "/run/secrets/gitea_secret_key" ]
  [ "$(e GITEA__security__INTERNAL_TOKEN__FILE)" = "/run/secrets/gitea_internal_token" ]
  [ "$(e GITEA__oauth2__JWT_SECRET__FILE)" = "/run/secrets/gitea_jwt_secret" ]
  [ "$(e GITEA__server__LFS_JWT_SECRET__FILE)" = "/run/secrets/gitea_lfs_jwt_secret" ]
  [ "$(y "$OUT/compose.yaml" 'c["secrets"]["gitea_secret_key"]["file"]')" = "/opt/adk/secrets/gitea-secret-key" ]
  [ "$(y "$OUT/compose.yaml" 'c["services"]["gitea"]["volumes"]')" = "['/var/lib/adk/gitea:/data']" ]
  # no secret values in the rendered file
  refute grep -qE '^ +GITEA__[a-z0-9]+__(SECRET_KEY|INTERNAL_TOKEN|JWT_SECRET|LFS_JWT_SECRET):' "$OUT/compose.yaml"
}

@test "compose: Gitea runs as the given host uid (default 1000), never root" {
  need_yaml
  "$RENDER" --config "$CFG" --out "$OUT"
  [ "$(y "$OUT/compose.yaml" 'c["services"]["gitea"]["environment"]["USER_UID"]')" = "1000" ]
  "$RENDER" --config "$CFG" --out "$OUT" --gitea-uid 997 --gitea-gid 994
  [ "$(y "$OUT/compose.yaml" 'c["services"]["gitea"]["environment"]["USER_UID"]')" = "997" ]
  [ "$(y "$OUT/compose.yaml" 'c["services"]["gitea"]["environment"]["USER_GID"]')" = "994" ]
  run "$RENDER" --config "$CFG" --out "$OUT" --gitea-gid 0
  [ "$status" -eq 2 ]
  run "$RENDER" --config "$CFG" --out "$OUT" --gitea-uid 0
  [ "$status" -eq 2 ]
  run "$RENDER" --config "$CFG" --out "$OUT" --gitea-uid "1 x"
  [ "$status" -eq 2 ]
}

@test "Caddyfile: token syntax per provider (desec only takes a block with token)" {
  for p in hetzner cloudflare ionos; do
    set_var DNS_PROVIDER "$p"
    "$RENDER" --config "$CFG" --out "$OUT"
    grep -qx "	acme_dns $p {env.DNS_API_TOKEN}" "$OUT/Caddyfile"
  done
  set_var DNS_PROVIDER desec
  "$RENDER" --config "$CFG" --out "$OUT"
  grep -qx '	acme_dns desec {' "$OUT/Caddyfile"
  grep -qx '		token {env.DNS_API_TOKEN}' "$OUT/Caddyfile"
  refute grep -q 'acme_dns desec {env' "$OUT/Caddyfile"
  grep -q 'github.com/caddy-dns/desec@' "$OUT/caddy/Dockerfile"
}

@test "compose: Gitea drops all capabilities except those its s6 entrypoint needs" {
  need_yaml
  "$RENDER" --config "$CFG" --out "$OUT"
  [ "$(y "$OUT/compose.yaml" 'c["services"]["gitea"]["cap_drop"]')" = "['ALL']" ]
  [ "$(y "$OUT/compose.yaml" 'sorted(c["services"]["gitea"]["cap_add"])')" = "['CHOWN', 'DAC_OVERRIDE', 'FOWNER', 'KILL', 'SETGID', 'SETUID']" ]
}

@test "unknown DNS provider without a pinned module is refused" {
  set_var DNS_PROVIDER route53
  run "$RENDER" --config "$CFG" --out "$OUT"
  [ "$status" -eq 1 ]
  [[ "$output" == *"route53"* ]]
}

@test "runner config: rootless-safe defaults and a pinned job image" {
  need_yaml
  "$RENDER" --config "$CFG" --out "$OUT"
  r() { y "$OUT/runner.yaml" "$1"; }
  # one job at a time: the runner process ends after it and the environment is wiped
  [ "$(r 'c["runner"]["capacity"]')" = "1" ]
  [ "$(r 'c["runner"]["file"]')" = "/var/lib/adk-runner/.runner" ]
  [ "$(r 'c["runner"]["insecure"]')" = "False" ]
  [[ "$(r 'c["runner"]["labels"][0]')" =~ ^ubuntu-latest:docker://docker\.io/gitea/runner-images:[^@]+@sha256:[0-9a-f]{64}$ ]]
  [ "$(r 'len(c["runner"]["labels"])')" = "1" ]
  [ "$(r 'c["container"]["network"]')" = "" ]
  [ "$(r 'c["container"]["privileged"]')" = "False" ]
  [ "$(r 'c["container"]["valid_volumes"]')" = "[]" ]
  [ "$(r 'c["container"]["docker_host"]')" = "" ]
  [ "$(r 'c["container"]["options"]')" = "" ]
  [ "$(r 'c["container"]["volumes"]')" = "[]" ]
  [ "$(r 'c["cache"]["enabled"]')" = "False" ]
}

@test "runner config: ADK_RUNNER_ADD_HOST and ADK_TLS_INTERNAL (lab only)" {
  need_yaml
  ADK_RUNNER_ADD_HOST=203.0.113.5 ADK_TLS_INTERNAL=1 "$RENDER" --config "$CFG" --out "$OUT"
  [ "$(y "$OUT/runner.yaml" 'c["container"]["options"]')" = "--add-host=git.example.com:203.0.113.5" ]
  [ "$(y "$OUT/runner.yaml" 'c["container"]["volumes"]')" = "['/etc/ssl/certs/ca-certificates.crt:/etc/ssl/certs/ca-certificates.crt:ro']" ]
  ADK_RUNNER_ADD_HOST='203.0.113.9 --privileged' run "$RENDER" --config "$CFG" --out "$OUT"
  [ "$status" -eq 2 ]
}

@test "invalid kit.env is refused" {
  set_var GITEA_DOMAIN ""
  run "$RENDER" --config "$CFG" --out "$OUT"
  [ "$status" -eq 1 ]
  [ ! -e "$OUT/compose.yaml" ]
}

@test "usage errors exit 2" {
  run "$RENDER" --config "$CFG"
  [ "$status" -eq 2 ]
  run "$RENDER" --out "$OUT" --bogus
  [ "$status" -eq 2 ]
}
