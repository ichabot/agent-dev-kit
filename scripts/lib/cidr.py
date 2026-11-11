"""Firewall source network validation shared by the agent-dev-kit shell scripts.

Always run isolated so nothing from the working directory or the environment is
imported:  python3 -I scripts/lib/cidr.py check|normalize LIST

  check      print one "entry: reason" line per rejected entry ("EMPTY" if the list
             has no entries); exit 0 (the caller decides how to report)
  normalize  print the normalized networks, one per line (bare IPs become /32 or
             /128); rejected entries go to stderr and the exit code is 1

LIST is comma separated. Rules: strict CIDR (no host bits), IPv4 at least /24,
IPv6 at least /48, public addresses only. The documentation ranges are allowed
because they are unroutable and used by the tests.
"""
import ipaddress
import sys

MIN_PREFIX = {4: 24, 6: 48}
DOC_RANGES = [ipaddress.ip_network(n) for n in
              ("192.0.2.0/24", "198.51.100.0/24", "203.0.113.0/24", "2001:db8::/32")]


def check(raw):
    """Return (networks, errors) for a comma separated list."""
    nets, errors = [], []
    entries = [e.strip() for e in raw.split(",") if e.strip()]
    if not entries:
        errors.append("EMPTY")
    for e in entries:
        try:
            net = ipaddress.ip_network(e, strict=True)
        except ValueError as ex:
            reason = "host bits set (prefix typo?)" if "host bits" in str(ex) else "not a network"
            errors.append(f"{e}: {reason}")
            continue
        if isinstance(net, ipaddress.IPv6Network) and net.network_address.ipv4_mapped is not None:
            errors.append(f"{e}: IPv4-mapped IPv6 is not allowed")
            continue
        if net.prefixlen < MIN_PREFIX[net.version]:
            errors.append(f"{e}: too broad (minimum /{MIN_PREFIX[net.version]})")
            continue
        documentation = any(net.subnet_of(d) for d in DOC_RANGES if d.version == net.version)
        if not documentation and (not net.is_global or net.is_multicast):
            errors.append(f"{e}: not a public address")
            continue
        nets.append(net)
    return nets, errors


def main(argv):
    if len(argv) != 3 or argv[1] not in ("check", "normalize"):
        print("usage: cidr.py check|normalize LIST", file=sys.stderr)
        return 2
    nets, errors = check(argv[2])
    if argv[1] == "check":
        for e in errors:
            print(e)
        return 0
    for e in errors:
        print("no network given" if e == "EMPTY" else e, file=sys.stderr)
    if errors:
        return 1
    seen = []
    for n in nets:
        if str(n) not in seen:
            seen.append(str(n))
    print("\n".join(seen))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
