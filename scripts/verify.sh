#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# verify.sh - Comprueba de extremo a extremo que el stack funciona
# ---------------------------------------------------------------------------
# Levanta sus propios port-forward temporales, consulta las APIs de
# Prometheus, Alertmanager y Grafana, y emite un reporte completo.
#
# El formateo de las respuestas JSON vive en scripts/_report.py, no incrustado
# aqui: el codigo Python dentro de comillas de shell obliga a escapar las
# comillas internas, y un backslash dentro de una expresion de f-string es un
# error de sintaxis de Python.
#
# Uso:
#   bash scripts/verify.sh                      reporte en pantalla
#   bash scripts/verify.sh > docs/verificacion.txt
# ---------------------------------------------------------------------------

set -uo pipefail   # sin -e: queremos el reporte completo aunque algo falle

DIR_SCRIPT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPORTE="$DIR_SCRIPT/_report.py"

PASADAS=0
FALLIDAS=0
PIDS=()

limpiar() {
  for pid in "${PIDS[@]:-}"; do kill "$pid" 2>/dev/null || true; done
}
trap limpiar EXIT

titulo() { printf '\n========== %s ==========\n' "$1"; }

comprueba() {
  local desc="$1"; shift
  if "$@" >/dev/null 2>&1; then
    printf '  [OK]    %s\n' "$desc"; PASADAS=$((PASADAS + 1))
  else
    printf '  [FALLA] %s\n' "$desc"; FALLIDAS=$((FALLIDAS + 1))
  fi
}

# Formatea una respuesta JSON con el ayudante de Python.
formatea() {
  if [ -n "${PY:-}" ] && [ -f "$REPORTE" ]; then
    "$PY" "$REPORTE" "$1"
  else
    echo "  (sin python3: no se puede formatear la respuesta)"
    cat >/dev/null
  fi
}

echo "==============================================================="
echo " Verificacion del stack - Proyecto Final SRE"
echo " Fecha: $(date '+%Y-%m-%d %H:%M:%S %z')"
echo "==============================================================="

# ---------------------------------------------------------------------------
titulo "1. HERRAMIENTAS Y CLUSTER"
comprueba "docker disponible"   command -v docker
comprueba "minikube disponible" command -v minikube
comprueba "kubectl disponible"  command -v kubectl
comprueba "cluster accesible"   kubectl cluster-info

PY=""
for cand in python3 python; do
  command -v "$cand" >/dev/null 2>&1 && { PY="$cand"; break; }
done
if [ -n "$PY" ]; then
  printf '  [OK]    %s disponible para formatear el reporte\n' "$PY"
else
  printf '  [AVISO] sin python3: las secciones de API saldran sin formato\n'
fi

echo
kubectl version --client 2>/dev/null | head -2
minikube status 2>&1 | head -6

# ---------------------------------------------------------------------------
titulo "2. ESTADO DE LOS PODS"
kubectl get pods -n sre-app -o wide 2>&1
echo
kubectl get pods -n monitoring -o wide 2>&1
echo

for ns_dep in "sre-app/sre-app" "monitoring/prometheus" "monitoring/alertmanager" \
              "monitoring/alert-logger" "monitoring/grafana"; do
  ns="${ns_dep%%/*}"; dep="${ns_dep##*/}"
  listas=$(kubectl get deploy "$dep" -n "$ns" -o jsonpath='{.status.readyReplicas}' 2>/dev/null)
  if [ "${listas:-0}" -ge 1 ] 2>/dev/null; then
    printf '  [OK]    %-14s listo (%s replica/s)\n' "$dep" "$listas"; PASADAS=$((PASADAS + 1))
  else
    printf '  [FALLA] %-14s sin replicas listas\n' "$dep"; FALLIDAS=$((FALLIDAS + 1))
  fi
done

# Los ejercicios del curso despliegan en el mismo namespace 'monitoring' con
# nombres terminados en '-deployment'. Si quedaron de una sesion anterior,
# compiten por los NodePorts y confunden la evidencia.
VIEJOS=$(kubectl get deploy -n monitoring -o name 2>/dev/null | grep -- '-deployment$' || true)
if [ -n "$VIEJOS" ]; then
  echo
  echo "  [AVISO] hay despliegues de los ejercicios del curso en 'monitoring':"
  echo "$VIEJOS" | sed 's/^/            /'
  echo "          Pueden chocar en los NodePorts con este proyecto."
  echo "          Para quitarlos:"
  echo "            kubectl delete deploy,svc,cm -n monitoring --all"
  echo "            bash scripts/cluster.sh"
fi

echo
echo "Reinicios por pod (un valor alto indica un problema):"
kubectl get pods -A -o custom-columns='NS:.metadata.namespace,POD:.metadata.name,REINICIOS:.status.containerStatuses[0].restartCount' 2>/dev/null \
  | grep -E 'sre-app|monitoring|NS' || true

# Si no hay nada desplegado, el resto del reporte seria ruido.
if ! kubectl get deploy sre-app -n sre-app >/dev/null 2>&1; then
  titulo "RESUMEN"
  echo "  El despliegue no existe todavia: no hay Deployment 'sre-app' en el"
  echo "  namespace 'sre-app'."
  echo
  echo "  Ejecuta primero el despliegue y vuelve a correr esta verificacion:"
  echo
  echo "    bash scripts/cluster.sh"
  echo "    bash scripts/verify.sh"
  echo
  echo "==============================================================="
  exit 0
fi

# ---------------------------------------------------------------------------
titulo "3. PORT-FORWARD TEMPORALES"
kubectl port-forward -n sre-app    svc/sre-app      5000:5000  >/dev/null 2>&1 & PIDS+=($!)
kubectl port-forward -n monitoring svc/prometheus   9090:9090  >/dev/null 2>&1 & PIDS+=($!)
kubectl port-forward -n monitoring svc/alertmanager 9093:9093  >/dev/null 2>&1 & PIDS+=($!)
kubectl port-forward -n monitoring svc/grafana      3000:3000  >/dev/null 2>&1 & PIDS+=($!)
echo "  esperando a que los tuneles respondan..."
sleep 8

# ---------------------------------------------------------------------------
titulo "4. APLICACION"
comprueba "/health responde"  curl -fsS --max-time 10 http://localhost:5000/health
comprueba "/metrics responde" curl -fsS --max-time 10 http://localhost:5000/metrics
echo
echo "Metricas expuestas (debe aparecer OK en las cuatro):"
METRICAS=$(curl -fsS --max-time 10 http://localhost:5000/metrics 2>/dev/null)
for m in http_requests_total http_request_duration_seconds app_inflight_requests app_up; do
  if echo "$METRICAS" | grep -q "^$m"; then
    printf '  [OK]    %s\n' "$m"; PASADAS=$((PASADAS + 1))
  else
    printf '  [FALLA] %s no aparece\n' "$m"; FALLIDAS=$((FALLIDAS + 1))
  fi
done

# ---------------------------------------------------------------------------
titulo "5. PROMETHEUS"
comprueba "API responde" curl -fsS --max-time 10 http://localhost:9090/-/ready
echo
echo "Targets activos:"
curl -fsS --max-time 15 http://localhost:9090/api/v1/targets 2>/dev/null | formatea targets
echo
echo "Reglas de alerta cargadas:"
curl -fsS --max-time 15 http://localhost:9090/api/v1/rules 2>/dev/null | formatea rules
echo
echo "Consulta de prueba (tasa de peticiones):"
curl -fsS --max-time 15 -G http://localhost:9090/api/v1/query \
  --data-urlencode 'query=sum(rate(http_requests_total[5m]))' 2>/dev/null | formatea query

# ---------------------------------------------------------------------------
titulo "6. ALERTMANAGER"
comprueba "API responde" curl -fsS --max-time 10 http://localhost:9093/-/ready
echo
echo "Prometheus ve a Alertmanager:"
curl -fsS --max-time 15 http://localhost:9090/api/v1/alertmanagers 2>/dev/null | formatea alertmanagers
echo
echo "Alertas actualmente en Alertmanager:"
curl -fsS --max-time 15 http://localhost:9093/api/v2/alerts 2>/dev/null | formatea alerts

# ---------------------------------------------------------------------------
titulo "7. GRAFANA"
comprueba "API de salud responde" curl -fsS --max-time 10 http://localhost:3000/api/health
echo
echo "Datasource aprovisionado:"
curl -fsS --max-time 15 -u admin:admin http://localhost:3000/api/datasources 2>/dev/null | formatea datasources
echo
echo "Prueba de conexion del datasource a Prometheus:"
# Se usa el proxy de datasources de Grafana: reenvia la consulta al Prometheus
# configurado y prueba el camino real que usan los paneles. La API /api/ds/query
# exige el uid del datasource, no basta con el tipo, por eso se obtiene primero.
UID_DS=""
if [ -n "${PY:-}" ]; then
  UID_DS=$(curl -fsS --max-time 15 -u admin:admin http://localhost:3000/api/datasources 2>/dev/null \
    | "$PY" -c 'import json,sys
try:
    d = json.load(sys.stdin)
    print(d[0]["uid"] if d else "")
except Exception:
    print("")' 2>/dev/null)
fi

if [ -n "$UID_DS" ]; then
  RESP=$(curl -fsS --max-time 20 -u admin:admin \
    "http://localhost:3000/api/datasources/proxy/uid/$UID_DS/api/v1/query?query=up" 2>/dev/null)
  if echo "$RESP" | grep -q '"status":"success"'; then
    SERIES=$(echo "$RESP" | grep -o '"metric"' | wc -l)
    echo "  [OK]    Grafana consulta a Prometheus correctamente ($SERIES series)"
    PASADAS=$((PASADAS + 1))
  else
    echo "  [FALLA] el datasource respondio pero sin exito:"
    echo "          $(echo "$RESP" | head -c 200)"
    FALLIDAS=$((FALLIDAS + 1))
  fi
else
  echo "  [FALLA] no se pudo obtener el uid del datasource"
  FALLIDAS=$((FALLIDAS + 1))
fi
echo
echo "Dashboard aprovisionado:"
curl -fsS --max-time 15 -u admin:admin 'http://localhost:3000/api/search?query=Golden' 2>/dev/null | formatea dashboards

# ---------------------------------------------------------------------------
titulo "8. RECEPTOR DE ALERTAS"
echo "Ultimas lineas del alert-logger:"
kubectl logs -n monitoring deploy/alert-logger --tail=25 2>&1 | sed 's/^/  /'

# ---------------------------------------------------------------------------
titulo "RESUMEN"
printf '  Comprobaciones pasadas: %s\n' "$PASADAS"
printf '  Comprobaciones falladas: %s\n' "$FALLIDAS"
echo
if [ "$FALLIDAS" -eq 0 ]; then
  echo "  Todo en orden. Puedes capturar los screenshots de evidencia."
else
  echo "  Hay fallas. Revisa la seccion correspondiente arriba y consulta"
  echo "  la seccion 'Solucion de problemas' del README."
fi
echo
echo "==============================================================="
