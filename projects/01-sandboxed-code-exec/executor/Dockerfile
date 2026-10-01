FROM python:3.13-slim
COPY executor.py /opt/executor/executor.py
USER 65534:65534
EXPOSE 8888
ENTRYPOINT ["python", "-I", "-B", "/opt/executor/executor.py"]
