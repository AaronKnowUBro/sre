#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# load-test.sh - Genera trafico contra la aplicacion para poblar las metricas
# ---------------------------------------------------------------------------
# Modos disponibles:
#   normal  (por defecto) trafico mixto, la mayoria exitoso
#   errors  solo errores, para disparar la alerta HighErrorRate
#   slow    peticiones lentas, para disparar HighLatencyP95
#   burst   muchas peticiones en paralelo, para disparar HighSaturation
#
# Uso:
#   bash scripts/load-test.sh [modo] [duracion_en_segundos]
#
# Requiere un port-forward activo:
#   kubectl port-forward -n sre-app svc/sre-app 5000:5000
# ---------------------------------------------------------------------------

set -uo pipefail

MODO="${1:-normal}"
DURACION="${2:-120}"
BASE_URL="${BASE_URL:-http://localhost:5000}"

case "$MODO" in
  normal|errors|slow|burst) ;;
  *) echo "Modo desconocido: $MODO. Usa normal, errors, slow o burst." >&2; exit 1 ;;
esac

if ! curl -fsS --max-time 10 "${BASE_URL}/health" >/dev/null 2>&1; then
  cat >&2 <<MSG
ERROR: la aplicacion no responde en ${BASE_URL}

Abre un port-forward en otra terminal:
  kubectl port-forward -n sre-app svc/sre-app 5000:5000
MSG
  exit 1
fi

echo "Modo: ${MODO} | Duracion: ${DURACION}s | Destino: ${BASE_URL}"
echo "Ctrl+C para detener."
echo

# Devuelve solo el codigo HTTP. Sin -f a proposito: en el modo 'errors' un 500
# es el resultado buscado, no un fallo, y -f hace que curl escriba a stderr y
# ensucie la salida con decenas de lineas de error esperadas.
peticion() {
  curl -sS -o /dev/null -w '%{http_code}' --max-time 30 "$1" 2>/dev/null || echo "000"
}

FIN=$(( $(date +%s) + DURACION ))
TOTAL=0; EXITO=0; ERROR=0; SIN_RESPUESTA=0

# Tabula el resultado de cada peticion por familia de codigo.
contabiliza() {
  TOTAL=$((TOTAL + 1))
  case "$1" in
    2*) EXITO=$((EXITO + 1)) ;;
    5*) ERROR=$((ERROR + 1)) ;;
    *)  SIN_RESPUESTA=$((SIN_RESPUESTA + 1)) ;;
  esac
}

progreso() {
  printf '\r  %d peticiones  |  2xx: %d  5xx: %d  sin respuesta: %d   ' \
    "$TOTAL" "$EXITO" "$ERROR" "$SIN_RESPUESTA"
}

while [ "$(date +%s)" -lt "$FIN" ]; do
  case "$MODO" in
    normal)
      # /work trae su propio 10% de errores: trafico realista.
      contabiliza "$(peticion "${BASE_URL}/work")"
      sleep 0.2
      ;;
    errors)
      # Solo 500: lleva la tasa de error muy por encima del umbral de 20%.
      contabiliza "$(peticion "${BASE_URL}/error")"
      sleep 0.1
      ;;
    slow)
      # Respuestas de 3 segundos: empujan el p95 arriba del umbral de 1s.
      contabiliza "$(peticion "${BASE_URL}/slow?seconds=3")"
      ;;
    burst)
      # 30 peticiones lentas en paralelo elevan app_inflight_requests.
      for _ in $(seq 1 30); do
        curl -sS -o /dev/null --max-time 30 "${BASE_URL}/slow?seconds=5" >/dev/null 2>&1 &
      done
      wait
      TOTAL=$((TOTAL + 30)); EXITO=$((EXITO + 30))
      ;;
  esac
  progreso
done

echo
echo
echo "Resumen: ${TOTAL} peticiones  |  2xx: ${EXITO}  5xx: ${ERROR}  sin respuesta: ${SIN_RESPUESTA}"
if [ "$TOTAL" -gt 0 ]; then
  echo "Tasa de error observada: $(( ERROR * 100 / TOTAL ))%"
fi
echo
echo "Las alertas necesitan que la condicion se sostenga durante su 'for':"
echo "  HighErrorRate   1 min    HighLatencyP95  2 min"
echo "  HighSaturation  2 min    NoTraffic       5 min"
echo
echo "Revisa el estado en Prometheus > Alerts y en Alertmanager."
