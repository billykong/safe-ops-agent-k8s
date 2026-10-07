FROM python:3.13-slim
COPY requirements.txt /opt/agent/
RUN pip install --no-cache-dir --no-compile -r /opt/agent/requirements.txt
COPY shared.py workflows.py activities.py worker.py /opt/agent/
USER 65534:65534
ENTRYPOINT ["python", "-B", "/opt/agent/worker.py"]
