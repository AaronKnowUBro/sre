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
#   ./scripts/load-test.sh [modo] [duracion_en_segundos]
# ---------------------------------------------------------------------------

set -euo pipefail

MODE="${1:-normal}"
DURATION="${2:-120}"
# Se asume un port-forward activo en el puerto 5000. Puede sobrescribirse:
#   BASE_URL=http://192.168.49.2:30500 ./scripts/load-test.sh
BASE_URL="${BASE_URL:-http://localhost:5000}"

if ! curl -fsS "${BASE_URL}/health" >/dev/null 2>&1; then
  cat >&2 <<MSG
ERROR: la aplicacion no responde en ${BASE_URL}

Abre un port-forward en otra terminal:
  kubectl port-forward -n sre-app svc/sre-app 5000:5000

O apunta a la IP de Minikube:
  BASE_URL=http://\$(minikube ip):30500 ./scripts/load-test.sh
MSG
  exit 1
fi

echo "Modo: ${MODE} | Duracion: ${DURATION}s | Destino: ${BASE_URL}"
echo "Ctrl+C para detener."

END=$(( $(date +%s) + DURATION ))
COUNT=0

while [ "$(date +%s)" -lt "$END" ]; do
  case "$MODE" in
    normal)
      # Trafico realista: /work ya trae su propio 10% de errores.
      curl -fsS -o /dev/null "${BASE_URL}/work" || true
      sleep 0.2
      ;;
    errors)
      # Solo errores: lleva la tasa de error muy por encima del umbral de 20%.
      curl -fsS -o /dev/null "${BASE_URL}/error" || true
      sleep 0.1
      ;;
    slow)
      # Respuestas de 3 segundos: empuja el p95 arriba del umbral de 1s.
      curl -fsS -o /dev/null "${BASE_URL}/slow?seconds=3" || true
      ;;
    burst)
      # 30 peticiones lentas en paralelo elevan app_inflight_requests.
      for _ in $(seq 1 30); do
        curl -fsS -o /dev/null "${BASE_URL}/slow?seconds=5" &
      done
      wait
      ;;
    *)
      echo "Modo desconocido: ${MODE}. Usa normal, errors, slow o burst." >&2
      exit 1
      ;;
  esac

  COUNT=$((COUNT + 1))
  if [ $((COUNT % 25)) -eq 0 ]; then
    echo "  ... ${COUNT} iteraciones"
  fi
done

echo "Listo: ${COUNT} iteraciones en modo ${MODE}."
echo "Revisa Grafana y espera el 'for:' de cada alerta antes de verla en Alertmanager."
