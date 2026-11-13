#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# diagnose.sh - Recolecta en una sola salida todo lo necesario para depurar
# ---------------------------------------------------------------------------
# Pensado para cuando algo falla y hay que compartir el estado completo. Reune
# entorno, red, estado del cluster, descripciones, logs y eventos, con los
# volumenes recortados para que la salida siga siendo manejable.
#
# Uso:
#   bash scripts/diagnose.sh                          en pantalla
#   bash scripts/diagnose.sh > /tmp/diagnostico.txt   a un archivo
# ---------------------------------------------------------------------------

set -uo pipefail

seccion() { printf '\n\n############ %s ############\n' "$1"; }
sub()     { printf '\n--- %s ---\n' "$1"; }

# Ejecuta un comando mostrandolo primero, y nunca aborta el reporte.
corre() {
  sub "$*"
  "$@" 2>&1 || echo "(el comando fallo con codigo $?)"
}

echo "==============================================================="
echo " Diagnostico - Proyecto Final SRE"
echo " Fecha:   $(date '+%Y-%m-%d %H:%M:%S %z')"
echo " Usuario: $(whoami)@$(hostname)"
echo " Carpeta: $(pwd)"
echo "==============================================================="

# ---------------------------------------------------------------------------
seccion "1. ENTORNO"
sub "sistema"
uname -a 2>&1
[ -f /etc/os-release ] && (. /etc/os-release && echo "distro: $PRETTY_NAME")
if grep -qi microsoft /proc/version 2>/dev/null; then
  echo "entorno: WSL"
  echo "kernel WSL: $(grep -oi 'microsoft.*' /proc/version 2>/dev/null | head -1)"
else
  echo "entorno: Linux nativo"
fi
sub "recursos"
echo "CPUs: $(nproc 2>/dev/null)"
free -h 2>/dev/null | head -2
df -h / 2>/dev/null | head -2

sub "versiones de herramientas"
for t in docker minikube kubectl helm python3; do
  if command -v "$t" >/dev/null 2>&1; then
    printf '%-10s %s\n' "$t" "$($t --version 2>&1 | head -1)"
  else
    printf '%-10s NO INSTALADO\n' "$t"
  fi
done

# ---------------------------------------------------------------------------
seccion "2. RED"
# El bloqueo del proxy corporativo es la causa mas frecuente de fallo, asi que
# se comprueban los destinos que el proyecto necesita.
for host in https://registry-1.docker.io/v2/ https://pypi.org https://github.com \
            https://storage.googleapis.com; do
  codigo=$(curl -sS -o /dev/null -w '%{http_code}' --max-time 12 "$host" 2>/dev/null)
  printf '  %-45s HTTP %s\n' "$host" "${codigo:-sin respuesta}"
done
sub "prueba real de descarga de imagen"
if command -v docker >/dev/null 2>&1; then
  docker pull -q hello-world >/dev/null 2>&1 \
    && echo "docker pull hello-world: OK" \
    || echo "docker pull hello-world: FALLO (el proxy probablemente bloquea Docker Hub)"
fi

# ---------------------------------------------------------------------------
seccion "3. DOCKER"
corre docker info
sub "imagenes presentes"
docker images 2>&1 | head -25

# ---------------------------------------------------------------------------
seccion "4. MINIKUBE"
corre minikube status
corre minikube profile list
sub "imagenes dentro del daemon de Minikube"
if eval "$(minikube docker-env 2>/dev/null)" 2>/dev/null; then
  docker images 2>&1 | head -25
else
  echo "(no se pudo apuntar al daemon de Minikube)"
fi
sub "ultimas lineas del log de Minikube"
minikube logs --length=40 2>&1 | tail -40

# ---------------------------------------------------------------------------
seccion "5. ESTADO DEL CLUSTER"
corre kubectl cluster-info
corre kubectl get nodes -o wide
corre kubectl get namespaces
sub "todos los pods del cluster"
kubectl get pods -A -o wide 2>&1

# ---------------------------------------------------------------------------
seccion "6. RECURSOS DEL PROYECTO"
for ns in sre-app monitoring; do
  sub "namespace $ns: todo"
  kubectl get all -n "$ns" 2>&1
  sub "namespace $ns: configmaps"
  kubectl get cm -n "$ns" 2>&1
  sub "namespace $ns: endpoints (vacios = el Service no encuentra pods)"
  kubectl get endpoints -n "$ns" 2>&1
done

sub "RBAC de Prometheus"
kubectl get sa prometheus -n monitoring 2>&1
kubectl get clusterrole prometheus-discovery 2>&1
kubectl get clusterrolebinding prometheus-discovery 2>&1
echo "puede el ServiceAccount listar pods?"
kubectl auth can-i list pods --as=system:serviceaccount:monitoring:prometheus -A 2>&1

sub "anotaciones de los pods de la aplicacion (las usa el service discovery)"
kubectl get pods -n sre-app -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.metadata.annotations}{"\n"}{end}' 2>&1

# ---------------------------------------------------------------------------
seccion "7. DESCRIPCIONES Y LOGS"
for ns_dep in "sre-app/sre-app" "monitoring/prometheus" "monitoring/alertmanager" \
              "monitoring/alert-logger" "monitoring/grafana"; do
  ns="${ns_dep%%/*}"; dep="${ns_dep##*/}"
  sub "DEPLOYMENT $dep (namespace $ns)"
  if ! kubectl get deploy "$dep" -n "$ns" >/dev/null 2>&1; then
    echo "NO EXISTE"
    continue
  fi
  kubectl get deploy "$dep" -n "$ns" 2>&1
  echo
  echo "condiciones:"
  kubectl describe deploy "$dep" -n "$ns" 2>&1 | sed -n '/Conditions:/,/^[A-Z]/p' | head -12
  for pod in $(kubectl get pods -n "$ns" -l "app=$dep" -o name 2>/dev/null); do
    echo
    echo ">>> $pod"
    kubectl describe "$pod" -n "$ns" 2>&1 | sed -n '/Containers:/,$p' | head -50
    echo
    echo ">>> logs de $pod (ultimas 30)"
    kubectl logs "$pod" -n "$ns" --tail=30 --all-containers 2>&1 | sed 's/^/    /'
    anterior=$(kubectl logs "$pod" -n "$ns" --previous --tail=20 2>/dev/null)
    if [ -n "$anterior" ]; then
      echo ">>> logs del contenedor anterior (indica reinicios)"
      echo "$anterior" | sed 's/^/    /'
    fi
  done
done

# ---------------------------------------------------------------------------
seccion "8. EVENTOS"
for ns in sre-app monitoring; do
  sub "eventos de $ns (los mas recientes al final)"
  kubectl get events -n "$ns" --sort-by=.lastTimestamp 2>&1 | tail -30
done

# ---------------------------------------------------------------------------
seccion "9. APIS DEL STACK"
# Solo tiene sentido si Prometheus esta corriendo.
if kubectl get deploy prometheus -n monitoring >/dev/null 2>&1; then
  kubectl port-forward -n monitoring svc/prometheus 9090:9090 >/dev/null 2>&1 &
  PF=$!
  sleep 6
  sub "targets de Prometheus"
  curl -fsS --max-time 15 http://localhost:9090/api/v1/targets 2>&1 | head -c 4000
  echo
  sub "reglas cargadas"
  curl -fsS --max-time 15 http://localhost:9090/api/v1/rules 2>&1 | head -c 3000
  echo
  sub "alertmanagers vistos por Prometheus"
  curl -fsS --max-time 15 http://localhost:9090/api/v1/alertmanagers 2>&1 | head -c 1000
  echo
  kill $PF 2>/dev/null || true
else
  echo "(Prometheus no esta desplegado: se omite)"
fi

# ---------------------------------------------------------------------------
seccion "10. REPOSITORIO"
corre git log --oneline -5
corre git status -sb
echo
echo "==============================================================="
echo " Fin del diagnostico"
echo "==============================================================="
