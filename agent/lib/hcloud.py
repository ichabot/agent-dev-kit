"""JSON helpers for agent/provision.sh (Hetzner Cloud API). Run with python3 -I.

  get FILE PATH                 print a value by dotted path (a.0.b); "" if missing,
                                JSON for lists/objects, "null" stays ""
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


def get(path, expr):
    with open(path) as f:
        d = json.load(f)
    for part in expr.split("."):
        if isinstance(d, list) and part.isdigit() and int(part) < len(d):
            d = d[int(part)]
        elif isinstance(d, dict) and part in d:
            d = d[part]
        else:
            return ""
    if d is None:
        return ""
    if isinstance(d, (list, dict)):
        return json.dumps(d)
    return str(d)


def main(a):
    cmd = a[0]
    if cmd == "get":
        print(get(a[1], a[2]))
    elif cmd == "sshkey":
        print(json.dumps({"name": a[1], "public_key": a[2], "labels": labels(a[3])}))
    elif cmd == "firewall":
        with open(a[3]) as f:
            rules = json.load(f)
        print(json.dumps({"name": a[1], "labels": labels(a[2]), "rules": rules}))
    elif cmd == "set-rules":
        with open(a[1]) as f:
            print(json.dumps({"rules": json.load(f)}))
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
        with open(a[1]) as f:
            d = json.load(f)
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
