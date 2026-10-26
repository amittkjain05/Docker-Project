FROM python:3.12-slim-bookworm

ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    DB_HOST=localhost \
    DB_NAME=linkly \
    DB_USER=linkly \
    DB_PASSWORD="" \
    DB_PASSWORD_FILE= \
    REDIS_HOST=localhost \
    REPORT_DIR=reports \
    REPORT_INTERVAL=86400 \
    WEBHOOK_URL="https://httpbin.org/post" \
    HEARTBEAT_FILE=/tmp/worker-heartbeat 


WORKDIR /app

COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt \
    && useradd --create-home --shell /usr/sbin/nologin worker \
    && mkdir -p "$REPORT_DIR" \
    && chown worker:worker "$REPORT_DIR"

COPY worker.py healthcheck.py ./

USER worker

HEALTHCHECK --interval=30s --timeout=5s --start-period=20s --retries=3 \
    CMD ["python", "healthcheck.py"]

CMD ["python", "worker.py"]