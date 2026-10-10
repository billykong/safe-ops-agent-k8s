"""Filter Kubernetes audit events (JSON lines on stdin).

    audit_events.py [--where PATH=VALUE]... [--print PATH]... [--count]

PATH walks into the event with '>' between keys, since keys contain dots
and slashes: user>extra>authentication.kubernetes.io/pod-name. A --where
matches if the value equals VALUE, or, for a list, contains it. --print
prints the given fields of each matching event, tab-separated (JSON for
objects); --count prints only how many matched.
"""
import argparse
import json
import sys


def get(event, path):
    v = event
    for key in path.split(">"):
        if not isinstance(v, dict) or key not in v:
            return None
        v = v[key]
    return v


def matches(event, where):
    for path, want in where:
        v = get(event, path)
        if isinstance(v, list):
            if want not in [str(x) for x in v]:
                return False
        elif v is None or str(v) != want:
            return False
    return True


def show(v):
    return v if isinstance(v, str) else json.dumps(v)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--where", action="append", default=[])
    ap.add_argument("--print", dest="fields", action="append", default=[])
    ap.add_argument("--count", action="store_true")
    a = ap.parse_args()
    where = [w.split("=", 1) for w in a.where]
    n = 0
    for line in sys.stdin:
        line = line.strip()
        if not line:
            continue
        e = json.loads(line)
        if not matches(e, where):
            continue
        n += 1
        if not a.count:
            print("\t".join(show(get(e, f)) for f in a.fields) if a.fields else line)
    if a.count:
        print(n)


if __name__ == "__main__":
    main()
