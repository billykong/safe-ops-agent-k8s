FROM python:3.13-slim
COPY agent.py /opt/agent/agent.py
USER 65534:65534
ENTRYPOINT ["python", "-I", "-B", "/opt/agent/agent.py"]
