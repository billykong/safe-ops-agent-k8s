#!/usr/bin/env python3
"""Fetch a container image with resumable downloads and import it into a
kind node's containerd.

Usage: fetch_image.py IMAGE --node NODE [--cache DIR] [--platform OS/ARCH]

Why: pulls of large layers (kata-deploy has a 1.7 GiB one) kept failing with
"connection reset by peer" and long stalls. Traced to a NAT on the path (a
reset arriving with the TTL of the home router, not the server). Docker and
containerd restart a failed layer from zero, so a layer that needs minutes on
one connection never finishes. This downloads each blob with HTTP Range
requests, resuming where it stopped, verifies its sha256, and keeps finished
blobs in a cache across rebuilds.

Only the requested platform's manifest is imported, as an OCI layout tar
piped to `ctr images import`, so there are no missing-platform digests.
Standard library only.
"""
import argparse
import hashlib
import io
import json
import os
import re
import socket
import subprocess
import sys
import tarfile
import time
import urllib.error
import urllib.parse
import urllib.request

INDEX_TYPES = ("application/vnd.oci.image.index.v1+json",
               "application/vnd.docker.distribution.manifest.list.v2+json")
MANIFEST_TYPES = ("application/vnd.oci.image.manifest.v1+json",
                  "application/vnd.docker.distribution.manifest.v2+json")
READ_TIMEOUT_S = 30   # a stall longer than this reconnects and resumes
MAX_ATTEMPTS = 200    # per blob; each attempt resumes, so progress accumulates
CHUNK = 1 << 20


def log(msg):
    print(f"fetch_image: {msg}", file=sys.stderr, flush=True)


def parse_ref(image):
    """quay.io/a/b:tag -> (registry, repo, tag); python:3 -> Docker Hub."""
    name, _, tag = image.rpartition(":") if ":" in image.split("/")[-1] else (image, "", "latest")
    parts = name.split("/")
    if len(parts) > 1 and ("." in parts[0] or ":" in parts[0] or parts[0] == "localhost"):
        registry, repo = parts[0], "/".join(parts[1:])
    else:
        registry, repo = "docker.io", name if "/" in name else f"library/{name}"
    api = "registry-1.docker.io" if registry == "docker.io" else registry
    return registry, api, repo, tag


class NoRedirect(urllib.request.HTTPRedirectHandler):
    # Follow blob redirects by hand: the CDN URL is signed, and the registry
    # token must not be sent to it.
    def redirect_request(self, *args, **kwargs):
        return None


_opener = urllib.request.build_opener(NoRedirect)


class Registry:
    def __init__(self, api, repo):
        self.api, self.repo, self.token = api, repo, None

    def _auth(self, challenge):
        params = dict(re.findall(r'(\w+)="([^"]*)"', challenge))
        q = {"service": params.get("service", ""), "scope": params.get("scope", f"repository:{self.repo}:pull")}
        with urllib.request.urlopen(f"{params['realm']}?{urllib.parse.urlencode(q)}", timeout=30) as r:
            body = json.load(r)
        self.token = body.get("token") or body.get("access_token")

    def request(self, path, accept=None, range_from=None):
        """GET a registry path, handling token auth and one redirect.
        Returns the open response."""
        url = f"https://{self.api}/v2/{self.repo}/{path}"
        for _ in range(2):
            headers = {"Accept": ", ".join(accept)} if accept else {}
            if self.token:
                headers["Authorization"] = f"Bearer {self.token}"
            if range_from:
                headers["Range"] = f"bytes={range_from}-"
            try:
                return _opener.open(urllib.request.Request(url, headers=headers), timeout=READ_TIMEOUT_S)
            except urllib.error.HTTPError as e:
                if e.code == 401 and "Bearer" in e.headers.get("WWW-Authenticate", ""):
                    self._auth(e.headers["WWW-Authenticate"])
                    continue
                if e.code in (301, 302, 303, 307, 308):
                    loc = urllib.parse.urljoin(url, e.headers["Location"])
                    h = {"Range": f"bytes={range_from}-"} if range_from else {}
                    return urllib.request.urlopen(urllib.request.Request(loc, headers=h), timeout=READ_TIMEOUT_S)
                raise
        raise RuntimeError(f"authentication failed for {url}")

    def manifest(self, ref, accept):
        with self.request(f"manifests/{ref}", accept=accept) as r:
            return r.read(), r.headers.get("Content-Type", "").split(";")[0]


def fetch_blob(reg, digest, size, cache):
    path = os.path.join(cache, digest.replace(":", "_"))
    if os.path.exists(path) and os.path.getsize(path) == size:
        return path
    part = path + ".part"
    for attempt in range(1, MAX_ATTEMPTS + 1):
        have = os.path.getsize(part) if os.path.exists(part) else 0
        if have >= size:
            break
        try:
            with reg.request(f"blobs/{digest}", range_from=have or None) as r:
                if have and r.status != 206:
                    have = 0  # server ignored Range: start over
                with open(part, "ab" if have else "wb") as f:
                    last_report = time.monotonic()
                    while chunk := r.read(CHUNK):
                        f.write(chunk)
                        have += len(chunk)
                        if time.monotonic() - last_report > 15:
                            log(f"{digest[:19]} {have / 2**20:,.0f}/{size / 2**20:,.0f} MiB")
                            last_report = time.monotonic()
        except (OSError, urllib.error.URLError, socket.timeout) as e:
            log(f"{digest[:19]} attempt {attempt}: {type(e).__name__}: {e}; resuming at {have / 2**20:,.0f} MiB")
            time.sleep(min(30, 2 * attempt))
    if not os.path.exists(part) or os.path.getsize(part) < size:
        raise RuntimeError(f"{digest}: gave up after {MAX_ATTEMPTS} attempts; rerun to resume")
    h = hashlib.sha256()
    with open(part, "rb") as f:
        while chunk := f.read(CHUNK):
            h.update(chunk)
    if "sha256:" + h.hexdigest() != digest or os.path.getsize(part) != size:
        os.remove(part)
        raise RuntimeError(f"{digest}: checksum mismatch, partial file discarded; rerun to retry")
    os.replace(part, path)
    return path


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    ap.add_argument("image")
    ap.add_argument("--node", required=True, help="kind node container to import into")
    ap.add_argument("--cache", default=os.path.expanduser("~/.cache/safe-ops-agent-k8s/blobs"))
    ap.add_argument("--platform", default="linux/amd64")
    a = ap.parse_args()
    os.makedirs(a.cache, exist_ok=True)

    registry, api, repo, tag = parse_ref(a.image)
    full_name = f"{registry}/{repo}:{tag}"
    reg = Registry(api, repo)
    raw, mtype = reg.manifest(tag, INDEX_TYPES + MANIFEST_TYPES)
    if mtype in INDEX_TYPES:
        os_, arch = a.platform.split("/")
        entry = next((m for m in json.loads(raw)["manifests"]
                      if m.get("platform", {}).get("os") == os_ and m["platform"].get("architecture") == arch), None)
        if entry is None:
            sys.exit(f"fetch_image: no {a.platform} manifest for {full_name}")
        raw, mtype = reg.manifest(entry["digest"], MANIFEST_TYPES)
    manifest = json.loads(raw)
    mdigest = "sha256:" + hashlib.sha256(raw).hexdigest()

    blobs = [manifest["config"]] + manifest["layers"]
    log(f"{full_name} ({a.platform}): {len(manifest['layers'])} layers, "
        f"{sum(b['size'] for b in blobs) / 2**20:,.0f} MiB")
    paths = {b["digest"]: fetch_blob(reg, b["digest"], b["size"], a.cache) for b in blobs}

    # OCI image layout, streamed into containerd in the node.
    index = {"schemaVersion": 2, "manifests": [{
        "mediaType": mtype, "digest": mdigest, "size": len(raw),
        "annotations": {"io.containerd.image.name": full_name, "org.opencontainers.image.ref.name": tag}}]}
    proc = subprocess.Popen(["docker", "exec", "-i", a.node, "ctr", "-n", "k8s.io", "images", "import",
                             "--snapshotter=overlayfs", "-"], stdin=subprocess.PIPE)
    with tarfile.open(fileobj=proc.stdin, mode="w|") as tar:
        def add_bytes(name, data):
            ti = tarfile.TarInfo(name); ti.size = len(data); tar.addfile(ti, io.BytesIO(data))
        add_bytes("oci-layout", b'{"imageLayoutVersion": "1.0.0"}')
        add_bytes("index.json", json.dumps(index).encode())
        add_bytes(f"blobs/sha256/{mdigest[7:]}", raw)
        for digest, path in paths.items():
            tar.add(path, arcname=f"blobs/sha256/{digest[7:]}")
    proc.stdin.close()
    if proc.wait() != 0:
        sys.exit(f"fetch_image: import into {a.node} failed")
    log(f"imported {full_name} into {a.node}")


if __name__ == "__main__":
    main()
