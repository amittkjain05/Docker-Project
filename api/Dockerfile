FROM python:3.12-slim-bookworm

ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    LOG_FILE=logs/api.log \
    LOG_FORMAT=text \
    DB_HOST=db \
    DB_NAME=linkly \
    DB_USER=linkly \
    DB_PASSWORD="" \
    DB_PASSWORD_FILE=/run/secrets/DB_PASSWORD \
    REDIS_HOST=redis 

WORKDIR /app

COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt \
    && useradd --create-home --shell /usr/sbin/nologin app
    
COPY app.py healthcheck.py ./
RUN mkdir -p logs \
    && chown app:app logs

USER app

EXPOSE 5000

HEALTHCHECK --interval=30s --timeout=5s --start-period=20s --retries=3 \
    CMD ["python", "healthcheck.py"]

CMD ["gunicorn", "--bind", "0.0.0.0:5000", "--workers", "1", "--access-logfile", "-", "--error-logfile", "-", "app:app"]
