FROM python:3.12-slim-bookworm

ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    LOG_FILE=- \
    LOG_FORMAT=json \
    DB_HOST=pgsql \
    DB_NAME=linkly \
    DB_USER=linkly \
    DB_PASSWORD="" \
    DB_PASSWORD_FILE=/run/secrets/DB_PASSWORD \
    REDIS_HOST=redis 

WORKDIR /app

COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt \
    && useradd --uid 10001 --no-create-home --shell /usr/sbin/nologin app
    
COPY app.py healthcheck.py ./

USER 10001

EXPOSE 5000

HEALTHCHECK --interval=10s --timeout=3s --start-period=15s --retries=3 \
    CMD ["python", "healthcheck.py"]

CMD ["gunicorn", "--bind", "0.0.0.0:5000", "--workers", "1", "--graceful-timeout", "20", "--access-logfile", "-", "--error-logfile", "-", "app:app"]
