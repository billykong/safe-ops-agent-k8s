FROM python:3.13-slim
# tini as PID 1 reaps orphaned processes. Without it the executor is PID 1,
# killed user processes stay as zombies, and zombies count against the
# RLIMIT_NPROC cap, so one fork bomb leaves the sandbox unable to fork.
RUN apt-get update && apt-get install -y --no-install-recommends tini && rm -rf /var/lib/apt/lists/*
COPY executor.py /opt/executor/executor.py
# Only set inside the sandbox image: after each run, kill every process of
# this uid except the executor (see executor.py). Never set on a dev host.
ENV EXECUTOR_KILL_ALL_AFTER_RUN=1
USER 65534:65534
EXPOSE 8888
ENTRYPOINT ["/usr/bin/tini", "--", "python", "-I", "-B", "/opt/executor/executor.py"]
