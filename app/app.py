"""
SRE Academy - Final Project
Aplicacion de demostracion instrumentada para Prometheus.

Expone metricas en /metrics usando prometheus_client y ofrece endpoints
disenados para producir trafico, latencia y errores de forma controlada,
de modo que las reglas de alerta de Prometheus se puedan disparar a demanda.

Metricas expuestas (los cuatro Golden Signals):
  - http_requests_total          Counter   -> Trafico y Errores
  - http_request_duration_seconds Histogram -> Latencia
  - app_inflight_requests        Gauge     -> Saturacion
  - app_up                       Gauge     -> Disponibilidad declarada
"""

import logging
import os
import random
import time

from flask import Flask, Response, jsonify, request
from prometheus_client import (
    CONTENT_TYPE_LATEST,
    Counter,
    Gauge,
    Histogram,
    generate_latest,
)

# --------------------------------------------------------------------------
# Configuracion
# --------------------------------------------------------------------------

# Las variables de entorno permiten ajustar el comportamiento sin reconstruir
# la imagen: utiles para demostrar distintos escenarios de alerta en el cluster.
APP_NAME = os.getenv("APP_NAME", "sre-final-project-app")
APP_PORT = int(os.getenv("APP_PORT", "5000"))
# Probabilidad de que /work devuelva un error 500 (0.0 a 1.0).
ERROR_RATE = float(os.getenv("ERROR_RATE", "0.1"))
# Rango de latencia artificial en segundos para /work.
MIN_LATENCY = float(os.getenv("MIN_LATENCY", "0.05"))
MAX_LATENCY = float(os.getenv("MAX_LATENCY", "0.4"))

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s %(levelname)s [%(name)s] %(message)s",
)
logger = logging.getLogger(APP_NAME)

app = Flask(__name__)

# --------------------------------------------------------------------------
# Definicion de metricas
# --------------------------------------------------------------------------

# Counter: solo incrementa. Con labels de method/endpoint/status podemos
# calcular tasa de peticiones y tasa de error con una sola metrica.
REQUEST_COUNT = Counter(
    "http_requests_total",
    "Total de peticiones HTTP procesadas",
    ["method", "endpoint", "status"],
)

# Histogram: agrupa las duraciones en buckets. Permite calcular percentiles
# con histogram_quantile() en PromQL, que es lo que usan los SLO de latencia.
REQUEST_LATENCY = Histogram(
    "http_request_duration_seconds",
    "Duracion de las peticiones HTTP en segundos",
    ["method", "endpoint"],
    buckets=(0.05, 0.1, 0.25, 0.5, 1.0, 2.5, 5.0, 10.0),
)

# Gauge: sube y baja. Representa saturacion (peticiones concurrentes).
INFLIGHT_REQUESTS = Gauge(
    "app_inflight_requests",
    "Peticiones en curso en este momento",
)

# Gauge fijo en 1: sirve como senal de vida para alertas de tipo "absent()".
APP_UP = Gauge(
    "app_up",
    "Indica que la aplicacion esta levantada (siempre 1 mientras responde)",
)
APP_UP.set(1)


# --------------------------------------------------------------------------
# Instrumentacion automatica via hooks de Flask
# --------------------------------------------------------------------------

@app.before_request
def _start_timer():
    """Marca el inicio de la peticion y suma una peticion en curso."""
    request.start_time = time.time()
    INFLIGHT_REQUESTS.inc()


@app.after_request
def _record_metrics(response):
    """Registra duracion y resultado de cada peticion.

    Se usa request.endpoint en lugar de request.path para evitar explosion de
    cardinalidad: un path con IDs variables crearia una serie temporal nueva
    por cada ID, que es uno de los errores mas comunes al instrumentar.
    """
    INFLIGHT_REQUESTS.dec()

    # El endpoint /metrics no se mide a si mismo para no contaminar los datos.
    if request.endpoint == "metrics":
        return response

    endpoint = request.endpoint or "unknown"
    elapsed = time.time() - getattr(request, "start_time", time.time())

    REQUEST_LATENCY.labels(
        method=request.method, endpoint=endpoint
    ).observe(elapsed)
    REQUEST_COUNT.labels(
        method=request.method, endpoint=endpoint, status=response.status_code
    ).inc()

    return response


# --------------------------------------------------------------------------
# Endpoints
# --------------------------------------------------------------------------

@app.route("/")
def index():
    """Pagina de inicio con el indice de endpoints disponibles."""
    return jsonify(
        {
            "app": APP_NAME,
            "message": "SRE Academy - Final Project",
            "endpoints": {
                "/": "este indice",
                "/health": "liveness y readiness probe",
                "/work": "simula trabajo con latencia y errores aleatorios",
                "/slow": "respuesta lenta deliberada para alertas de latencia",
                "/error": "devuelve siempre 500 para alertas de error rate",
                "/metrics": "metricas en formato Prometheus",
            },
        }
    )


@app.route("/health")
def health():
    """Endpoint ligero para las probes de Kubernetes.

    Se mantiene sin latencia artificial a proposito: si tuviera delays,
    Kubernetes podria reiniciar el pod durante las demos de alta latencia.
    """
    return jsonify({"status": "ok"}), 200


@app.route("/work")
def work():
    """Carga de trabajo realista: la mayoria OK, algunas fallan.

    ERROR_RATE controla el porcentaje de fallos, de modo que la tasa de error
    observada en Grafana se pueda subir o bajar sin tocar el codigo.
    """
    latency = random.uniform(MIN_LATENCY, MAX_LATENCY)
    time.sleep(latency)

    if random.random() < ERROR_RATE:
        logger.error("fallo simulado en /work (latencia %.3fs)", latency)
        return jsonify({"status": "error", "latency_seconds": latency}), 500

    logger.info("/work completado en %.3fs", latency)
    return jsonify({"status": "ok", "latency_seconds": latency}), 200


@app.route("/slow")
def slow():
    """Respuesta deliberadamente lenta para disparar alertas de latencia.

    Acepta ?seconds=N (maximo 10) para controlar la demora desde la URL.
    """
    seconds = min(float(request.args.get("seconds", 2.0)), 10.0)
    time.sleep(seconds)
    logger.warning("/slow respondio despues de %.2fs", seconds)
    return jsonify({"status": "ok", "slept_seconds": seconds}), 200


@app.route("/error")
def error():
    """Devuelve siempre 500 para forzar la alerta de tasa de error."""
    logger.error("fallo forzado en /error")
    return jsonify({"status": "error", "message": "fallo forzado"}), 500


@app.route("/metrics")
def metrics():
    """Expone las metricas para que Prometheus las recolecte (modelo pull)."""
    return Response(generate_latest(), mimetype=CONTENT_TYPE_LATEST)


if __name__ == "__main__":
    logger.info("iniciando %s en el puerto %s", APP_NAME, APP_PORT)
    logger.info(
        "error_rate=%s latencia=%s-%ss", ERROR_RATE, MIN_LATENCY, MAX_LATENCY
    )
    app.run(host="0.0.0.0", port=APP_PORT)
