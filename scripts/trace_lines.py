"""Flattens a trace from Jaeger's v3 API (OTLP JSON on stdin) to one line
per span, for scripts/test-observability.sh to grep:

  <service> | <span name> | key=value key=value ...

and, with --keys, the sorted set of attribute keys in the trace instead."""
import json
import sys

d = json.load(sys.stdin)
keys = set()
for rs in d.get("result", {}).get("resourceSpans", []):
    svc = next((a["value"].get("stringValue", "") for a in rs["resource"].get("attributes", []) if a["key"] == "service.name"), "")
    for ss in rs.get("scopeSpans", []):
        for sp in ss.get("spans", []):
            attrs = {a["key"]: next(iter(a["value"].values()), "") for a in sp.get("attributes", [])}
            for e in sp.get("events", []):
                keys.update("event:" + a["key"] for a in e.get("attributes", []))
            keys.update(attrs)
            if "--keys" not in sys.argv:
                print(f"{svc} | {sp['name']} | " + " ".join(f"{k}={v}" for k, v in sorted(attrs.items())))
if "--keys" in sys.argv:
    print("\n".join(sorted(keys)))
