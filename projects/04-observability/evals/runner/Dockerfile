# The eval runner (P4-10). Its own image and identity: it shares no code
# with the agent it grades, only Temporal's workflow and query names.
FROM python:3.13-slim
COPY requirements.txt /opt/evals/
RUN pip install --no-cache-dir --no-compile -r /opt/evals/requirements.txt
COPY runner.py judge.py /opt/evals/
USER 65534:65534
ENTRYPOINT ["python", "-B", "/opt/evals/runner.py"]
