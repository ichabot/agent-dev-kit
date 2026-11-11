"""JSON helpers for agent/provision.sh (Hetzner Cloud API). Run with python3 -I.

  check FILE                    exit 0 if FILE is a JSON document, else 1 (no output)
  get FILE PATH                 print a value by dotted path (a.0.b); "" if missing,
                                JSON for lists/objects, "null" stays ""
  id FILE PATH                  like get, but the value must be a numeric id (exit 3 if not)
  ids FILE PATH                 ids of the objects in the list at PATH, space separated
                                (all numeric, exit 3 if not)
  sshkey NAME PUBKEY CUSTOMER   body of POST /ssh_keys
  firewall NAME CUSTOMER RULES  body of POST /firewalls (RULES = file with the JSON array)
  set-rules RULES               body of POST /firewalls/{id}/actions/set_rules
  apply-to SERVER_ID            body of POST /firewalls/{id}/actions/apply_to_resources
  server NAME TYPE LOCATION CUSTOMER SSHKEY_REF FIREWALL_REF USER_DATA_FILE
                                body of POST /servers (refs: integer id or placeholder)
  truncate FILE                 print the JSON body with user_data shortened (dry run)
  ipv6-host NET                 first host address of an IPv6 network (Hetzner's ::1)
"""
import ipaddress
import json
import sys


def labels(customer):
    return {"managed-by": "agent-dev-kit", "customer": customer}


def ref(value):
    return int(value) if value.isdigit() else value


class Invalid(Exception):
    pass


def load(path):
    try:
        with open(path) as f:
            return json.load(f)
    except (OSError, ValueError) as e:  # JSONDecodeError is a ValueError
        raise Invalid(f"{path}: not a JSON document ({e.__class__.__name__})")


def lookup(d, expr):
    for part in expr.split("."):
        if isinstance(d, list) and part.isdigit() and int(part) < len(d):
            d = d[int(part)]
        elif isinstance(d, dict) and part in d:
            d = d[part]
        else:
            return None
    return d


def get(path, expr):
    d = lookup(load(path), expr)
    if d is None:
        return ""
    if isinstance(d, (list, dict)):
        return json.dumps(d)
    return str(d)


def numeric_id(value, where):
    if isinstance(value, bool) or not (
            isinstance(value, int) and value >= 0 or isinstance(value, str) and value.isascii() and value.isdigit()):
        raise Invalid(f"{where}: not a numeric id: {value!r}")
    return str(int(value))


def get_id(path, expr):
    d = lookup(load(path), expr)
    return "" if d is None else numeric_id(d, expr)


def get_ids(path, expr):
    d = lookup(load(path), expr)
    if d is None:
        return ""
    if not isinstance(d, list):
        raise Invalid(f"{expr}: not a list")
    return " ".join(numeric_id(o.get("id") if isinstance(o, dict) else None, expr) for o in d)


def main(a):
    cmd = a[0]
    try:
        return run(cmd, a)
    except Invalid as e:
        print(f"hcloud.py: {e}", file=sys.stderr)
        return 3


def run(cmd, a):
    if cmd == "check":
        try:
            load(a[1])
        except Invalid:
            return 1
    elif cmd == "get":
        print(get(a[1], a[2]))
    elif cmd == "id":
        print(get_id(a[1], a[2]))
    elif cmd == "ids":
        print(get_ids(a[1], a[2]))
    elif cmd == "sshkey":
        print(json.dumps({"name": a[1], "public_key": a[2], "labels": labels(a[3])}))
    elif cmd == "firewall":
        print(json.dumps({"name": a[1], "labels": labels(a[2]), "rules": load(a[3])}))
    elif cmd == "set-rules":
        print(json.dumps({"rules": load(a[1])}))
    elif cmd == "apply-to":
        print(json.dumps({"apply_to": [{"type": "server", "server": {"id": int(a[1])}}]}))
    elif cmd == "server":
        name, stype, location, customer, key, fw, ud = a[1:8]
        with open(ud) as f:
            user_data = f.read()
        print(json.dumps({
            "name": name,
            "server_type": stype,
            "image": "debian-13",
            "location": location,
            "ssh_keys": [ref(key)],
            "firewalls": [{"firewall": ref(fw)}],
            "labels": labels(customer),
            "user_data": user_data,
            "start_after_create": True,
            "public_net": {"enable_ipv4": True, "enable_ipv6": True},
        }))
    elif cmd == "truncate":
        d = load(a[1])
        if "user_data" in d:
            ud = d["user_data"]
            d["user_data"] = f"{ud.splitlines()[0]} ... ({len(ud.encode())} bytes)"
        print(json.dumps(d))
    elif cmd == "ipv6-host":
        print(ipaddress.ip_network(a[1], strict=False)[1])
    else:
        print(f"hcloud.py: unknown command {cmd}", file=sys.stderr)
        return 2
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
