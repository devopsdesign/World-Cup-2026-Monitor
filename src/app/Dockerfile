# Pinned to an exact patch tag (not a floating `slim`/`latest`). For a
# fully immutable, supply-chain-pinned build, resolve and pin the digest
# yourself once and paste it in:
#   docker pull python:3.11.9-slim
#   docker inspect --format='{{index .RepoDigests 0}}' python:3.11.9-slim
#   # then: FROM python:3.11.9-slim@sha256:<the digest printed above>
FROM python:3.11.9-slim AS base

RUN groupadd --gid 10001 app && \
    useradd --uid 10001 --gid app --shell /usr/sbin/nologin --no-create-home app

WORKDIR /app

COPY requirements.txt .
# Versions are pinned exactly (see requirements.txt). For hash-pinned,
# fully reproducible installs, generate a hashed lockfile once with
# `pip-compile --generate-hashes` and swap this for `--require-hashes`.
RUN pip install --no-cache-dir -r requirements.txt

COPY main.py .
COPY static ./static

RUN chown -R app:app /app
USER app

EXPOSE 8080

HEALTHCHECK --interval=30s --timeout=5s --start-period=10s CMD python -c \
    "import urllib.request; urllib.request.urlopen('http://127.0.0.1:8080/healthz', timeout=3)"

CMD ["python", "-m", "uvicorn", "main:app", "--host", "0.0.0.0", "--port", "8080"]
