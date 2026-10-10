"""Run in the agent's pod by scripts/test-observability.sh, as a
compromised agent would act:

  span TRACE_ID CANARY [SERVICE]
                         send one span to the collector carrying CANARY in
                         content attributes and an exception event (P4-03),
                         as SERVICE (default safe-ops-agent; GAP-06)
  connect HOST PORT      try a TCP connection; prints "connected" or why not

Standard library only."""
import json
import os
import socket
import sys
import time
import urllib.request

COLLECTOR = "http://otel-collector.observability.svc.cluster.local:4318/v1/traces"

mode = sys.argv[1]
if mode == "span":
    trace_id, canary = sys.argv[2], sys.argv[3]
    service = sys.argv[4] if len(sys.argv) > 4 else "safe-ops-agent"
    now = time.time_ns()
    s = lambda k, v: {"key": k, "value": {"stringValue": v}}
    body = {"resourceSpans": [{
        "resource": {"attributes": [s("service.name", service)]},
        "scopeSpans": [{"scope": {"name": "redaction-probe"}, "spans": [{
            "traceId": trace_id, "spanId": os.urandom(8).hex(), "name": "redaction probe", "kind": 1,
            "startTimeUnixNano": str(now - 1_000_000), "endTimeUnixNano": str(now),
            "attributes": [s("safeops.task", "redaction-probe"), s("gen_ai.input.messages", canary),
                           s("gen_ai.output.messages", canary), s("gen_ai.tool.call.arguments", canary),
                           s("customer.account", canary)],
            "events": [{"name": "exception", "timeUnixNano": str(now),
                        "attributes": [s("exception.type", "ValueError"), s("exception.message", canary)]}],
        }]}],
    }]}
    req = urllib.request.Request(COLLECTOR, data=json.dumps(body).encode(), method="POST",
                                 headers={"Content-Type": "application/json"})
    with urllib.request.urlopen(req, timeout=10) as r:
        print(r.status)
elif mode == "connect":
    host, port = sys.argv[2], int(sys.argv[3])
    try:
        socket.create_connection((host, port), timeout=3).close()
        print("connected")
    except socket.gaierror as e:
        print(f"dns error: {e}")
    except OSError as e:
        print(f"no connection: {e}")
else:
    sys.exit(f"unknown mode {mode}")
