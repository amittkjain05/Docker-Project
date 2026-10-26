FROM nginxinc/nginx-unprivileged:1.27-alpine

COPY default.conf /etc/nginx/conf.d/default.conf
COPY certs/tls.crt /etc/nginx/certs/tls.crt
COPY certs/tls.key /etc/nginx/certs/tls.key

USER nginx

EXPOSE 8080 8443

HEALTHCHECK --interval=30s --timeout=5s --start-period=10s --retries=3 \
    CMD wget -q -O /dev/null http://127.0.0.1:8080/healthz || exit 1