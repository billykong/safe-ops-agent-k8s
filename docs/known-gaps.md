# Known gaps

Weaknesses we know about, have reproduced, and haven't closed yet. Each has an ID that tests and docs refer to. A test that reproduces a gap reports `GAP <id>` instead of passing or failing, so the gap stays visible in every run without blocking the suite. When a gap is closed, its test check becomes a normal PASS/FAIL and the entry moves to *Closed* with the commit that closed it.

| ID | Gap | Severity | Status | Requirement |
| --- | --- | --- | --- | --- |
| [GAP-01](#gap-01-domain-fronting-through-the-pypi-egress-allowlist) | Domain fronting through the PyPI egress allowlist | High for sandboxes with egress; none for default sandboxes | Open | [P1-13](prd/projects/p1-sandboxed-code-exec.md) |

## GAP-01: domain fronting through the PyPI egress allowlist

**Found:** 2026-10-04, P1 milestone 6. **Reproduced by:** `make test-egress`, check `domain fronting (SNI pypi.org, Host www.fastly.com)`, reported as `GAP GAP-01`.

### What's wrong

Sandboxes from the `python-gvisor-pypi` pool may reach `pypi.org` and `files.pythonhosted.org` on 443 (`projects/01-sandboxed-code-exec/manifests/65-networkpolicy-egress-pypi.yaml`). The policy works at three layers:

1. DNS: Cilium's DNS proxy answers only those exact names.
2. IP: TCP 443 only to addresses the proxy has returned for them (`toFQDNs`).
3. TLS: the SNI must be one of the names (`serverNames`, checked by Envoy without decrypting).

PyPI is served by Fastly, whose addresses are shared by many other customers. Code in the sandbox can open TLS to PyPI's address with SNI `pypi.org` (passing all three checks) and then send an HTTP `Host` header naming any other Fastly-hosted site. Fastly routes by the `Host` header, which is inside the encrypted stream, so Cilium can't see it.

### Impact

A sandbox with PyPI egress can send data to, and receive data from, any service on Fastly, including one an attacker sets up for a few dollars. That's an exfiltration and command-and-control channel for code that prompt injection or a malicious package got into the sandbox. Default sandboxes (no egress) are not affected.

### Evidence

From a `python-gvisor-pypi` sandbox, connecting to PyPI's address with SNI `pypi.org`:

| `Host` header | Response | Meaning |
| --- | --- | --- |
| `pypi.org` | `200`, `server: gunicorn` | Intended |
| `www.fastly.com` | `200`, `Server: Artisanal bits` | Another Fastly customer's site served |
| `www.nytimes.com` | `403`, `server: DataDome` | Request reached the NYT's origin (its bot wall answered) |
| `www.python.org` | `200`, `server: nginx` | Another site reached |

Without the SNI pin, even plain HTTPS by name to those sites worked through PyPI's address. The pin closed that, not fronting.

### Options

| Option | Closes it? | Cost |
| --- | --- | --- |
| **In-cluster package mirror or proxy** (e.g. devpi, or a pip-index proxy) as the sandbox's only egress destination; it fetches from PyPI itself and serves only package paths | Yes, for the sandbox: the sandbox has no internet route at all | A component to run; the mirror's own egress must be fenced the same way. Fits P3's tool gateway |
| **Cilium TLS interception** (`terminatingTLS`/`originatingTLS` with HTTP rules on `Host` and path) | Yes | The sandbox must trust a cluster CA; Envoy sees plaintext; keys to manage |
| **Pre-built images or wheels** for known dependencies, so most tasks need no egress | Avoids it for those tasks | Image rebuilds per dependency set |
| Keep the allowlist minimal and egress pools small | Narrows it, doesn't close it | — |

**Planned:** the mirror/proxy, with P3's gateway. Until then, treat the pypi pool as able to reach Fastly.

### Status

Open.
