#!/usr/bin/env bats
# Tests for test/deploy.sh and test/lib/deploy.py (root step of a TEST deployment), run as
# non-root with ADK_TEST_ROOT (all paths below it) and fake curl/docker in PATH.

setup() {
  ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  DEPLOY="$ROOT/test/deploy.sh"
  PY="$ROOT/test/lib/deploy.py"
  export ADK_TEST_ROOT="$BATS_TEST_TMPDIR/root"
  T="$ADK_TEST_ROOT"
  mkdir -p "$T/opt/adk/secrets" "$T/opt/adk/test-services/sites" "$BATS_TEST_TMPDIR/bin"
  cp "$ROOT/tests/fixtures/valid.env" "$T/opt/adk/kit.env"
  sed -i 's/^ACME_MODE=.*/ACME_MODE=http01/' "$T/opt/adk/kit.env"
  TOKEN=0123456789abcdef0123456789abcdef01234567
  printf '%s\n' "$TOKEN" > "$T/opt/adk/secrets/gitea-pull-token"
  chmod 0600 "$T/opt/adk/secrets/gitea-pull-token"
  SHA=89abcdef0123456789abcdef0123456789abcdef
  export CALLS="$BATS_TEST_TMPDIR/calls"
  : > "$CALLS"
  # project archive like Gitea's: one top-level directory "shop"
  SRC="$BATS_TEST_TMPDIR/src/shop"
  mkdir -p "$SRC"
  cp -r "$ROOT/tests/fixtures/test-project/." "$SRC/"
  export FAKE_ARCHIVE="$BATS_TEST_TMPDIR/archive.tar.gz"
  pack
  cat > "$BATS_TEST_TMPDIR/bin/curl" <<'FAKE'
#!/usr/bin/env bash
out="" url=""
args=("$@")
for ((i = 0; i < ${#args[@]}; i++)); do
  case "${args[i]}" in
    -o) out="${args[i+1]}" ;;
    -H) [[ "${args[i+1]}" == @- ]] && cat > "$CALLS.header" ;;
    http*://*) url="${args[i]}" ;;
  esac
done
echo "curl $*" >> "$CALLS"
case "$url" in
  https://*) [[ -z "${FAKE_FETCH_FAIL:-}" ]] || exit 22; cp "$FAKE_ARCHIVE" "$out" ;;
  http://127.0.0.1:*) exit "${FAKE_HEALTH_RC:-0}" ;;
esac
FAKE
  # (update.sh runs with env -i: the fake docker finds its files by fixed paths)
  cat > "$BATS_TEST_TMPDIR/bin/docker" <<'FAKE'
#!/usr/bin/env bash
D=@D@
echo "docker $*" >> "$D/calls"
[[ "$*" == *" validate "* && -n "${FAKE_CADDY_INVALID:-}" ]] && { echo "Error: bad site" >&2; exit 1; }
[[ "$*" == *" reload "* && -n "${FAKE_RELOAD_FAIL:-}" ]] && { echo "Error: reload" >&2; exit 1; }
[[ "$*" == *" up "* && -e "$D/up-fail" ]] && exit 1
exit 0
FAKE
  sed -i "s|@D@|$BATS_TEST_TMPDIR|" "$BATS_TEST_TMPDIR/bin/docker"
  chmod +x "$BATS_TEST_TMPDIR/bin/curl" "$BATS_TEST_TMPDIR/bin/docker"
  export PATH="$BATS_TEST_TMPDIR/bin:$PATH"
}

pack() {
  tar -C "$BATS_TEST_TMPDIR/src" -czf "$FAKE_ARCHIVE" shop
}

no_match() {
  if grep -q "$@"; then return 1; fi
}

# --- arguments ---------------------------------------------------------------------

@test "arguments are validated again (same grammar as the gate)" {
  for a in "shop" "shop $SHA x" "../x $SHA" "Shop $SHA" "shop main" "shop ${SHA:1}" \
      "shop v1.2" "x $SHA"; do
    # shellcheck disable=SC2086  # split on purpose
    run "$DEPLOY" $a
    [ "$status" -eq 2 ] || { echo "accepted: $a"; return 1; }
  done
  run "$DEPLOY" "shop $SHA"
  [ "$status" -eq 2 ]
  run "$DEPLOY" "shop" "$SHA"$'\n'
  [ "$status" -eq 2 ]
  [ ! -s "$CALLS" ]
}

@test "refuses to run as non-root without the test root" {
  run env -u ADK_TEST_ROOT "$DEPLOY" shop "$SHA"
  [ "$status" -eq 2 ]
  [[ "$output" == *"root"* ]]
}

# --- happy path --------------------------------------------------------------------

@test "deploys: fetch with the pull token on stdin, update.sh, health, caddy site" {
  run "$DEPLOY" shop "$SHA"
  [ "$status" -eq 0 ]
  grep -q "https://git.example.com/api/v1/repos/acme/shop/archive/$SHA.tar.gz" "$CALLS"
  no_match -F "$TOKEN" "$CALLS"
  grep -qx "Authorization: token $TOKEN" "$CALLS.header"
  # files installed: deploy/ only, .env from the example, port and version recorded
  [ -x "$T/srv/test/shop/deploy/update.sh" ]
  [ ! -e "$T/srv/test/shop/deploy/../.gitea" ]
  [ ! -e "$T/srv/test/shop/README.md" ]
  [ "$(cat "$T/srv/test/shop/.env")" = "GREETING=hello from TEST" ]
  [ "$(cat "$T/srv/test/shop/http_port")" = 18080 ]
  [ "$(cat "$T/srv/test/shop/VERSION")" = "$SHA" ]
  [ "$(cat "$T/srv/test/shop/state/version")" = "$SHA" ]
  # update.sh ran compose up with the project's compose file
  grep -q "docker compose -f deploy/compose.yaml --env-file .env up -d" "$CALLS"
  grep -q "curl .*http://127.0.0.1:18080/healthz" "$CALLS"
  # caddy: site written, validated, then reloaded over the admin socket
  site="$T/opt/adk/test-services/sites/shop.caddy"
  grep -q '^shop.test.example.com {' "$site"
  grep -q 'reverse_proxy 127.0.0.1:18080' "$site"
  grep -q 'import adk_site' "$site"
  v="$(grep -n 'caddy validate' "$CALLS" | cut -d: -f1)"
  r="$(grep -n 'caddy reload --address unix//run/caddy/admin.sock' "$CALLS" | cut -d: -f1)"
  [ -n "$v" ] && [ -n "$r" ] && [ "$v" -lt "$r" ]
  [[ "$output" == *"https://shop.test.example.com/"* ]]
  [[ "$output" != *"$TOKEN"* ]]
  # temporary registry credentials are gone
  [ -z "$(find "$T/run" -maxdepth 1 -name 'adk-deploy-docker.*')" ]
}

@test "dns01: the site is a handler inside the wildcard block" {
  sed -i 's/^ACME_MODE=.*/ACME_MODE=dns01/' "$T/opt/adk/kit.env"
  run "$DEPLOY" shop "$SHA"
  [ "$status" -eq 0 ]
  site="$T/opt/adk/test-services/sites/shop.caddy"
  grep -q '^@adk-shop host shop.test.example.com$' "$site"
  grep -q '^handle @adk-shop {$' "$site"
  no_match '^shop.test.example.com {' "$site"
}

@test "a tag ref is fetched as such; the registry login is for test-pull" {
  # shellcheck disable=SC2016  # expanded by the stub
  printf '#!/bin/sh\ncp "$DOCKER_CONFIG/config.json" "%s"\nexit 0\n' "$BATS_TEST_TMPDIR/docker-config" > "$SRC/deploy/update.sh"
  chmod +x "$SRC/deploy/update.sh"
  pack
  run "$DEPLOY" shop v1.4.0
  [ "$status" -eq 0 ]
  grep -q "/repos/acme/shop/archive/v1.4.0.tar.gz" "$CALLS"
  auth="$(python3 -c 'import json,sys,base64; print(base64.b64decode(json.load(open(sys.argv[1]))["auths"]["git.example.com"]["auth"]).decode())' "$BATS_TEST_TMPDIR/docker-config")"
  [ "$auth" = "test-pull:$TOKEN" ]
}

@test "second deploy of the same port: idempotent caddy (no reload), .env kept" {
  "$DEPLOY" shop "$SHA"
  printf 'GREETING=changed by the tester\n' > "$T/srv/test/shop/.env"
  : > "$CALLS"
  run "$DEPLOY" shop v1.0.0
  [ "$status" -eq 0 ]
  no_match 'caddy reload' "$CALLS"
  [ "$(cat "$T/srv/test/shop/.env")" = "GREETING=changed by the tester" ]
  [ "$(cat "$T/srv/test/shop/VERSION")" = "v1.0.0" ]
}

# --- refusals --------------------------------------------------------------------------

@test "missing pull token: clear error, no request" {
  rm "$T/opt/adk/secrets/gitea-pull-token"
  run "$DEPLOY" shop "$SHA"
  [ "$status" -eq 1 ]
  [[ "$output" == *"test-pull-token"* ]]
  [ ! -s "$CALLS" ]
}

@test "fetch failure: nothing installed" {
  FAKE_FETCH_FAIL=1 run "$DEPLOY" shop "$SHA"
  [ "$status" -eq 1 ]
  [ ! -e "$T/srv/test/shop/deploy" ]
}

@test "archive with a symlink, missing adk.json or bad port is refused before anything runs" {
  ln -s /etc/shadow "$SRC/deploy/site/evil"
  pack
  run "$DEPLOY" shop "$SHA"
  [ "$status" -eq 1 ]
  [[ "$output" == *"links"* ]]
  rm "$SRC/deploy/site/evil"
  for j in '{"http_port": 80}' '{"http_port": "8080"}' '{"http_port": true}' \
      '{"http_port": 8080, "cmd": "x"}' '[8080]' 'nonsense'; do
    printf '%s\n' "$j" > "$SRC/deploy/adk.json"
    pack
    run "$DEPLOY" shop "$SHA"
    [ "$status" -eq 1 ] || { echo "accepted: $j"; return 1; }
  done
  rm "$SRC/deploy/adk.json"
  pack
  run "$DEPLOY" shop "$SHA"
  [ "$status" -eq 1 ]
  [[ "$output" == *"adk.json is missing"* ]]
  [ ! -e "$T/srv/test/shop" ]
  no_match 'docker' "$CALLS"
}

@test "a port used by another project is refused" {
  mkdir -p "$T/srv/test/other"
  echo 18080 > "$T/srv/test/other/http_port"
  run "$DEPLOY" shop "$SHA"
  [ "$status" -eq 1 ]
  [[ "$output" == *"other"* ]]
  no_match 'docker' "$CALLS"
}

@test "update.sh failure: previous deploy/ restored, caddy untouched" {
  "$DEPLOY" shop "$SHA"
  before="$(cat "$T/opt/adk/test-services/sites/shop.caddy")"
  echo "version 2" > "$SRC/deploy/site/index.html"
  printf '{"http_port": 18081}\n' > "$SRC/deploy/adk.json"
  pack
  : > "$CALLS"
  touch "$BATS_TEST_TMPDIR/up-fail"
  run "$DEPLOY" shop v2.0.0
  [ "$status" -eq 1 ]
  [[ "$output" == *"update.sh failed"* ]]
  grep -q "adk-fixture-app version 1" "$T/srv/test/shop/deploy/site/index.html"
  [ "$(cat "$T/srv/test/shop/VERSION")" = "$SHA" ]
  [ "$(cat "$T/opt/adk/test-services/sites/shop.caddy")" = "$before" ]
  no_match 'caddy' "$CALLS"
}

@test "unhealthy app: caddy untouched" {
  FAKE_HEALTH_RC=7 run "$DEPLOY" shop "$SHA"
  [ "$status" -eq 1 ]
  [[ "$output" == *"healthz"* ]]
  [ ! -e "$T/opt/adk/test-services/sites/shop.caddy" ]
}

@test "caddy rejects the site: previous site file restored, no reload" {
  "$DEPLOY" shop "$SHA"
  before="$(cat "$T/opt/adk/test-services/sites/shop.caddy")"
  printf '{"http_port": 18081}\n' > "$SRC/deploy/adk.json"
  pack
  : > "$CALLS"
  FAKE_CADDY_INVALID=1 run "$DEPLOY" shop v2.0.0
  [ "$status" -eq 1 ]
  [ "$(cat "$T/opt/adk/test-services/sites/shop.caddy")" = "$before" ]
  no_match 'caddy reload' "$CALLS"
}

@test "first deploy rejected by caddy: no site file left behind" {
  FAKE_CADDY_INVALID=1 run "$DEPLOY" shop "$SHA"
  [ "$status" -eq 1 ]
  [ ! -e "$T/opt/adk/test-services/sites/shop.caddy" ]
}

@test "caddy reload fails: previous site restored and reloaded again" {
  "$DEPLOY" shop "$SHA"
  before="$(cat "$T/opt/adk/test-services/sites/shop.caddy")"
  printf '{"http_port": 18081}\n' > "$SRC/deploy/adk.json"
  pack
  : > "$CALLS"
  FAKE_RELOAD_FAIL=1 run "$DEPLOY" shop v2.0.0
  [ "$status" -eq 1 ]
  [ "$(cat "$T/opt/adk/test-services/sites/shop.caddy")" = "$before" ]
  [ "$(grep -c 'caddy reload' "$CALLS")" -eq 2 ]
}

# --- deploy.py extract ---------------------------------------------------------------

mk_tar() {  # mk_tar NAME PYTHON-BODY (tf = open tarfile)
  python3 - "$BATS_TEST_TMPDIR/$1.tar.gz" "$2" <<'PYX'
import io, sys, tarfile
def add(tf, name, data=b"x", **kw):
    i = tarfile.TarInfo(name); i.size = len(data)
    for k, v in kw.items(): setattr(i, k, v)
    tf.addfile(i, io.BytesIO(data) if i.isreg() else None)
with tarfile.open(sys.argv[1], "w:gz") as tf:
    add(tf, "p/deploy/update.sh", b"#!/bin/sh\n", mode=0o755)
    add(tf, "p/deploy/adk.json", b'{"http_port": 8080}')
    exec(sys.argv[2])
PYX
}

@test "extract refuses traversal, absolute paths, links, devices and two top dirs" {
  mk_tar dotdot 'add(tf, "p/deploy/../../etc/x")'
  mk_tar abs 'add(tf, "/etc/x")'
  mk_tar hard 'add(tf, "p/deploy/h", type=tarfile.LNKTYPE, linkname="p/deploy/adk.json")'
  mk_tar sym 'add(tf, "p/deploy/s", type=tarfile.SYMTYPE, linkname="/etc/shadow")'
  mk_tar dev 'add(tf, "p/deploy/d", type=tarfile.CHRTYPE)'
  mk_tar fifo 'add(tf, "p/deploy/f", type=tarfile.FIFOTYPE)'
  mk_tar twotop 'add(tf, "q/deploy/x")'
  mk_tar ctrl 'add(tf, "p/deploy/a\nb")'
  for t in dotdot abs hard sym dev fifo twotop ctrl; do
    run python3 -I "$PY" extract "$BATS_TEST_TMPDIR/$t.tar.gz" "$BATS_TEST_TMPDIR/out-$t"
    [ "$status" -eq 3 ] || { echo "accepted: $t"; return 1; }
    [ ! -e "$BATS_TEST_TMPDIR/out-$t" ]
  done
}

@test "extract: only deploy/, sane modes, links outside deploy/ ignored" {
  mk_tar ok 'add(tf, "p/README", b"r"); add(tf, "p/src/l", type=tarfile.SYMTYPE, linkname="/"); add(tf, "p/deploy/sub/f", b"y", mode=0o4777)'
  run python3 -I "$PY" extract "$BATS_TEST_TMPDIR/ok.tar.gz" "$BATS_TEST_TMPDIR/out"
  [ "$status" -eq 0 ]
  [ "$(cd "$BATS_TEST_TMPDIR/out" && find . | sort | tr '\n' ' ')" = ". ./adk.json ./sub ./sub/f ./update.sh " ]
  [ "$(stat -c %a "$BATS_TEST_TMPDIR/out/sub/f")" = 755 ]
  [ "$(stat -c %a "$BATS_TEST_TMPDIR/out/adk.json")" = 644 ]
  [ "$(stat -c %a "$BATS_TEST_TMPDIR/out")" = 755 ]
  # destination must not exist
  run python3 -I "$PY" extract "$BATS_TEST_TMPDIR/ok.tar.gz" "$BATS_TEST_TMPDIR/out"
  [ "$status" -eq 3 ]
}

@test "extract refuses oversize deploy/ and garbage" {
  mk_tar big 'add(tf, "p/deploy/big", b"0" * (51 * 1024 * 1024))'
  run python3 -I "$PY" extract "$BATS_TEST_TMPDIR/big.tar.gz" "$BATS_TEST_TMPDIR/out-big"
  [ "$status" -eq 3 ]
  printf 'not a tarball' > "$BATS_TEST_TMPDIR/junk.tar.gz"
  run python3 -I "$PY" extract "$BATS_TEST_TMPDIR/junk.tar.gz" "$BATS_TEST_TMPDIR/out-junk"
  [ "$status" -eq 3 ]
  [[ "$output" != *"Traceback"* ]]
}

@test "the fixture workflow is the kit's workflow template" {
  cmp "$ROOT/test/deploy-test.workflow.yaml" "$ROOT/tests/fixtures/test-project/.gitea/workflows/ci.yaml"
}
