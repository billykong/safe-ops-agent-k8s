# The MCP servers (incidents, netdiag) and the mock tracker, one image.
FROM python:3.13-slim
COPY requirements.txt /opt/mcp/
RUN pip install --no-cache-dir --no-compile -r /opt/mcp/requirements.txt
COPY incidents_mcp.py netdiag_mcp.py tracker.py /opt/mcp/
WORKDIR /opt/mcp
USER 65534:65534
ENTRYPOINT ["python", "-B"]
CMD ["-m", "uvicorn", "incidents_mcp:app", "--host", "0.0.0.0", "--port", "8080", "--log-level", "warning"]
