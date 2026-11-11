"""Helpers for test/deploy.sh (runs as root on the TEST VM). Run with python3 -I.

  extract ARCHIVE DEST     extract the deploy/ directory of a Gitea repository archive
                           (tar.gz, one top-level directory) into DEST (must not exist).
                           Only regular files and directories; refused (exit 3, nothing left
                           behind): links, devices, fifos, absolute paths, "..", names with
                           control characters, more than MAX_FILES entries or MAX_BYTES in
                           deploy/, no deploy/update.sh or deploy/adk.json. Modes: dirs 0755,
                           files 0644 (0755 if executable in the archive), owner = caller.
  http-port FILE           print http_port of deploy/adk.json (strict: a JSON object with
                           exactly the key "http_port", an integer 1024-65535)
  docker-auth HOST USER    print a docker config.json with credentials for HOST; the token
                           is read from stdin (never argv)
"""
import base64
import json
import os
import stat
import sys
import tarfile

MAX_FILES = 2000
MAX_BYTES = 50 * 1024 * 1024
REQUIRED = ("update.sh", "adk.json")


class Refused(Exception):
    pass


def safe_parts(name):
    if name.startswith("/") or "\\" in name:
        raise Refused(f"unsafe path in the archive: {name!r}")
    parts = [p for p in name.split("/") if p not in ("", ".")]
    for p in parts:
        if p == ".." or any(ord(c) < 32 or ord(c) == 127 for c in p):
            raise Refused(f"unsafe path in the archive: {name!r}")
    return parts


def extract(archive, dest):
    if os.path.lexists(dest):
        raise Refused(f"{dest} exists")
    try:
        tf = tarfile.open(archive, mode="r:gz")
    except (OSError, tarfile.TarError) as e:
        raise Refused(f"not a tar.gz archive ({e.__class__.__name__})")
    entries, top, total = [], None, 0
    with tf:
        for m in tf:
            if m.type == tarfile.XGLTYPE or m.name == "pax_global_header":
                continue
            parts = safe_parts(m.name)
            if not parts:
                continue
            if top is None:
                top = parts[0]
            elif parts[0] != top:
                raise Refused("archive has more than one top-level directory")
            if len(parts) < 2 or parts[1] != "deploy":
                continue
            rel = parts[2:]
            if not (m.isreg() or m.isdir()):
                raise Refused(f"deploy/{'/'.join(rel)}: only regular files and directories are allowed (no links or devices)")
            if len(entries) >= MAX_FILES:
                raise Refused(f"deploy/ has more than {MAX_FILES} entries")
            data = None
            if m.isreg():
                total += m.size
                if total > MAX_BYTES:
                    raise Refused(f"deploy/ is larger than {MAX_BYTES} bytes")
                data = tf.extractfile(m).read()
            entries.append((rel, m.isdir(), bool(m.mode & 0o111), data))
    files = {"/".join(rel) for rel, is_dir, _, _ in entries if not is_dir}
    for r in REQUIRED:
        if r not in files:
            raise Refused(f"deploy/{r} is missing at this ref (deployment contract, docs/test-vm.md)")
    os.mkdir(dest, 0o700)
    try:
        for rel, is_dir, _, _ in sorted(entries, key=lambda e: len(e[0])):
            if is_dir and rel:
                os.makedirs(os.path.join(dest, *rel), 0o755, exist_ok=True)
        for rel, is_dir, executable, data in entries:
            if is_dir:
                continue
            path = os.path.join(dest, *rel)
            os.makedirs(os.path.dirname(path), 0o755, exist_ok=True)
            mode = 0o755 if executable or rel == ["update.sh"] else 0o644
            fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600)
            with os.fdopen(fd, "wb") as f:
                f.write(data)
            os.chmod(path, mode)
        for d, dirs, _ in os.walk(dest):
            for x in dirs:
                os.chmod(os.path.join(d, x), 0o755)
        os.chmod(dest, 0o755)
    except Exception:
        import shutil
        shutil.rmtree(dest, ignore_errors=True)
        raise


def http_port(path):
    st = os.lstat(path)
    if not stat.S_ISREG(st.st_mode) or st.st_size > 4096:
        raise Refused("deploy/adk.json must be a small regular file")
    try:
        with open(path, encoding="utf-8") as f:
            d = json.load(f)
    except (ValueError, UnicodeDecodeError):
        raise Refused("deploy/adk.json is not valid JSON")
    if not isinstance(d, dict) or set(d) != {"http_port"}:
        raise Refused('deploy/adk.json must be exactly {"http_port": <port>}')
    p = d["http_port"]
    if isinstance(p, bool) or not isinstance(p, int) or not 1024 <= p <= 65535:
        raise Refused("deploy/adk.json: http_port must be an integer 1024-65535")
    return p


def docker_auth(host, user):
    token = sys.stdin.readline().strip()
    if not token.isalnum() or len(token) > 200:
        raise Refused("invalid token")
    auth = base64.b64encode(f"{user}:{token}".encode()).decode()
    return json.dumps({"auths": {host: {"auth": auth}}})


def main(a):
    try:
        if a[0] == "extract" and len(a) == 3:
            extract(a[1], a[2])
        elif a[0] == "http-port" and len(a) == 2:
            print(http_port(a[1]))
        elif a[0] == "docker-auth" and len(a) == 3:
            print(docker_auth(a[1], a[2]))
        else:
            print("usage: deploy.py extract ARCHIVE DEST | http-port FILE | docker-auth HOST USER", file=sys.stderr)
            return 2
    except Refused as e:
        print(f"ERROR: {e}", file=sys.stderr)
        return 3
    except OSError as e:
        print(f"ERROR: {e.__class__.__name__}: {e.strerror or e}", file=sys.stderr)
        return 3
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
