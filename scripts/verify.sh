#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# verify.sh - Comprueba de extremo a extremo que el stack funciona
# ---------------------------------------------------------------------------
# Levanta sus propios port-forward temporales, consulta las APIs de
# Prometheus, Alertmanager y Grafana, y emite un reporte completo.
#
# Uso:
#   ./scripts/verify.sh              reporte en pantalla
#   ./scripts/verify.sh > reporte.txt   guardarlo en un archivo
# ---------------------------------------------------------------------------

set -uo pipefail   # sin -e: queremos que el reporte termine aunque algo falle

PASADAS=0
FALLIDAS=0
PIDS=()

limpiar() {
  for pid in "${PIDS[@]:-}"; do kill "$pid" 2>/dev/null || true; done
}
trap limpiar EXIT

titulo() { printf '\n========== %s ==========\n' "$1"; }

# comprueba <descripcion> <comando...>
comprueba() {
  local desc="$1"; shift
  if "$@" >/dev/null 2>&1; then
    printf '  [OK]    %s\n' "$desc"; PASADAS=$((PASADAS + 1))
  else
    printf '  [FALLA] %s\n' "$desc"; FALLIDAS=$((FALLIDAS + 1))
  fi
}

# Extrae valores de JSON sin depender de jq, que no siempre esta instalado.
json() {
  if command -v python3 >/dev/null 2>&1; then python3 -c "$1"
  elif command -v python >/dev/null 2>&1; then python -c "$1"
  else cat; fi
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
echo
kubectl version --short 2>/dev/null || kubectl version --client 2>/dev/null | head -2
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

# Los reinicios repetidos delatan CrashLoopBackOff u OOMKilled.
echo
echo "Reinicios por pod (un valor alto indica un problema):"
kubectl get pods -A -o custom-columns='NS:.metadata.namespace,POD:.metadata.name,REINICIOS:.status.containerStatuses[0].restartCount' 2>/dev/null \
  | grep -E 'sre-app|monitoring|NS' || true

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
curl -fsS --max-time 15 http://localhost:9090/api/v1/targets 2>/dev/null | json '
import json,sys
d=json.load(sys.stdin)
activos=d["data"]["activeTargets"]
arriba=[t for t in activos if t["health"]=="up"]
for t in sorted(activos, key=lambda x: x["labels"].get("job","")):
    l=t["labels"]
    marca="[OK]   " if t["health"]=="up" else "[FALLA]"
    print(f"  {marca} job={l.get(\"job\"):22} instance={l.get(\"instance\",\"?\"):24} salud={t[\"health\"]}")
    if t["health"]!="up" and t.get("lastError"):
        print(f"          error: {t[\"lastError\"]}")
print(f"\n  TOTAL: {len(arriba)}/{len(activos)} targets en UP")
app=[t for t in arriba if t["labels"].get("app")=="sre-app"]
print(f"  Pods de la aplicacion recolectados: {len(app)} (se esperan 2)")
' 2>&1

echo
echo "Reglas de alerta cargadas:"
curl -fsS --max-time 15 http://localhost:9090/api/v1/rules 2>/dev/null | json '
import json,sys
d=json.load(sys.stdin)
n=0
for g in d["data"]["groups"]:
    print(f"  grupo: {g[\"name\"]}")
    for r in g["rules"]:
        n+=1
        print(f"    - {r[\"name\"]:20} estado={r.get(\"state\",\"?\")}")
print(f"\n  TOTAL: {n} reglas cargadas (se esperan 6)")
' 2>&1

echo
echo "Consulta de prueba (tasa de peticiones):"
curl -fsS --max-time 15 -G http://localhost:9090/api/v1/query \
  --data-urlencode 'query=sum(rate(http_requests_total[5m]))' 2>/dev/null | json '
import json,sys
d=json.load(sys.stdin)
r=d["data"]["result"]
if r: print(f"  [OK]    hay datos: {float(r[0][\"value\"][1]):.4f} req/s")
else: print("  [AVISO] sin datos todavia: genera trafico con ./scripts/load-test.sh")
' 2>&1

# ---------------------------------------------------------------------------
titulo "6. ALERTMANAGER"
comprueba "API responde" curl -fsS --max-time 10 http://localhost:9093/-/ready
echo
echo "Prometheus ve a Alertmanager:"
curl -fsS --max-time 15 http://localhost:9090/api/v1/alertmanagers 2>/dev/null | json '
import json,sys
d=json.load(sys.stdin)
a=d["data"]["activeAlertmanagers"]
if a:
    for x in a: print(f"  [OK]    {x[\"url\"]}")
else:
    print("  [FALLA] Prometheus no tiene Alertmanager activo")
' 2>&1

echo
echo "Alertas actualmente en Alertmanager:"
curl -fsS --max-time 15 http://localhost:9093/api/v2/alerts 2>/dev/null | json '
import json,sys
d=json.load(sys.stdin)
if not d: print("  (ninguna: normal si no has disparado alertas todavia)")
for a in d:
    l=a.get("labels",{})
    print(f"  - {l.get(\"alertname\")} [{l.get(\"severity\")}] estado={a[\"status\"][\"state\"]}")
' 2>&1

# ---------------------------------------------------------------------------
titulo "7. GRAFANA"
comprueba "API de salud responde" curl -fsS --max-time 10 http://localhost:3000/api/health
echo
echo "Datasource aprovisionado:"
curl -fsS --max-time 15 -u admin:admin http://localhost:3000/api/datasources 2>/dev/null | json '
import json,sys
d=json.load(sys.stdin)
if not d: print("  [FALLA] no hay datasources")
for x in d: print(f"  [OK]    {x[\"name\"]} ({x[\"type\"]}) -> {x[\"url\"]}  default={x[\"isDefault\"]}")
' 2>&1

echo
echo "Prueba de conexion del datasource a Prometheus:"
curl -fsS --max-time 20 -u admin:admin \
  -H 'Content-Type: application/json' \
  "http://localhost:3000/api/ds/query" \
  -d '{"queries":[{"refId":"A","datasource":{"type":"prometheus"},"expr":"up","instant":true}],"from":"now-5m","to":"now"}' \
  >/dev/null 2>&1 && echo "  [OK]    Grafana consulta a Prometheus correctamente" \
                   || echo "  [AVISO] la consulta de prueba no respondio como se esperaba"

echo
echo "Dashboard aprovisionado:"
curl -fsS --max-time 15 -u admin:admin 'http://localhost:3000/api/search?query=Golden' 2>/dev/null | json '
import json,sys
d=json.load(sys.stdin)
if not d: print("  [FALLA] el dashboard no aparece")
for x in d: print(f"  [OK]    {x[\"title\"]}  carpeta={x.get(\"folderTitle\",\"General\")}  url={x[\"url\"]}")
' 2>&1

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
