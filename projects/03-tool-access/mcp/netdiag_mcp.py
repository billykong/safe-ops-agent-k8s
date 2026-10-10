"""The `netdiag` MCP server (P3 milestone 5): one read-only diagnostic
tool, `resolve`, that looks a hostname up in DNS. It needs no secret.

It is here as the red-team's "approved tool" (P3-31, OWASP ASI02): an
ordinary lookup is also a way out of the cluster, since a name like
<data>.attacker.example carries <data> to whoever runs that domain's
name server. Two layers fence it, independently: the MCP gateway allows
only in-cluster service names as the argument (its registry's rule), and
this pod's DNS is limited to cluster names by Cilium's DNS proxy, which
refuses anything else without forwarding it."""
import asyncio
import contextlib
import os
import socket

from mcp.server.mcpserver import MCPServer
from mcp.server.transport_security import TransportSecuritySettings
from starlette.applications import Starlette
from starlette.routing import Mount

HOSTS = [h for h in os.environ.get("ALLOWED_HOSTS", "netdiag-mcp.mcp-servers.svc.cluster.local:8080").split(",") if h]

mcp = MCPServer("netdiag", version="1.0.0")


@mcp.tool()
async def resolve(hostname: str) -> dict:
    """Resolve a Kubernetes service name (service.namespace.svc.cluster.local) to its addresses, to check it exists."""
    try:
        infos = await asyncio.to_thread(socket.getaddrinfo, hostname, None, proto=socket.IPPROTO_TCP)
    except socket.gaierror as e:
        return {"hostname": hostname, "resolved": False, "error": e.strerror}
    return {"hostname": hostname, "resolved": True, "addresses": sorted({i[4][0] for i in infos})}


@contextlib.asynccontextmanager
async def lifespan(_app):
    async with mcp.session_manager.run():
        yield


app = Starlette(
    routes=[Mount("/", app=mcp.streamable_http_app(
        json_response=True, stateless_http=True,
        transport_security=TransportSecuritySettings(enable_dns_rebinding_protection=True, allowed_hosts=HOSTS, allowed_origins=[]),
    ))],
    lifespan=lifespan,
)
