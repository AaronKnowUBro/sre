# Imagen slim para reducir superficie de ataque y tamano final.
FROM python:3.12-slim

# Evita archivos .pyc y fuerza logs sin buffer para que kubectl logs
# muestre la salida en tiempo real.
ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1

WORKDIR /app

# Las dependencias se copian primero para aprovechar la cache de capas:
# si solo cambia app.py, Docker no reinstala los paquetes.
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

COPY app.py .

# Usuario sin privilegios: buena practica de seguridad en contenedores.
RUN useradd --create-home --shell /bin/bash appuser
USER appuser

EXPOSE 5000

# IMPORTANTE: un solo worker, a proposito.
# prometheus_client mantiene el registro de metricas en memoria del proceso.
# Con varios workers de Gunicorn, cada scrape de Prometheus cae en uno u otro
# y /metrics devolveria solo los contadores de ese worker: Prometheus veria el
# valor subir y bajar, lo interpretaria como un reinicio del contador y rate()
# produciria picos falsos.
# La concurrencia se consigue con hilos, que comparten el mismo registro, y el
# escalado horizontal con replicas del pod, que Prometheus si recolecta como
# targets independientes y se agregan con sum() en PromQL.
# La alternativa en produccion es el modo multiproceso de prometheus_client
# (PROMETHEUS_MULTIPROC_DIR sobre un volumen compartido).
CMD ["gunicorn", "--bind", "0.0.0.0:5000", "--workers", "1", "--threads", "8", "--timeout", "120", "app:app"]
