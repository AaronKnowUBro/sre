#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# cluster.sh - Despliega el stack completo del proyecto final en Minikube
# ---------------------------------------------------------------------------
# Un solo comando levanta todo: cluster, imagen de la aplicacion, Prometheus,
# Alertmanager y Grafana. Es idempotente: se puede volver a correr sin dejar el
# cluster en un estado inconsistente.
#
# El script esta pensado para diagnosticarse solo. Si un despliegue no llega a
# estar listo, imprime el describe, los eventos y los logs de ese pod antes de
# terminar, para que el motivo quede en la misma salida.
#
# Uso:
#   bash scripts/cluster.sh
#   bash scripts/cluster.sh 2>&1 | tee /tmp/cluster.log
# ---------------------------------------------------------------------------

set -uo pipefail

DIR_SCRIPT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DIR_RAIZ="$(dirname "$DIR_SCRIPT")"
IMAGEN="sre-final-project-app:latest"

GREEN='\033[0;32m'; BLUE='\033[0;34m'; YELLOW='\033[1;33m'; RED='\033[0;31m'; NC='\033[0m'
log()  { echo -e "\n${BLUE}==>${NC} $*"; }
ok()   { echo -e "${GREEN}  OK${NC} $*"; }
warn() { echo -e "${YELLOW}  AVISO${NC} $*"; }
err()  { echo -e "${RED}  ERROR${NC} $*"; }

# ---------------------------------------------------------------------------
# 1. Herramientas
# ---------------------------------------------------------------------------
log "Verificando herramientas requeridas"
FALTA=0
for t in docker minikube kubectl; do
  if command -v "$t" >/dev/null 2>&1; then
    ok "$t"
  else
    err "falta '$t'"
    FALTA=1
  fi
done
if [ "$FALTA" -eq 1 ]; then
  err "Instala lo que falta. En WSL2: bash scripts/setup-wsl.sh"
  exit 1
fi

if ! docker info >/dev/null 2>&1; then
  err "El daemon de Docker no responde."
  err "En WSL sin systemd:  sudo service docker start"
  err "Si da permiso denegado, abre una terminal nueva o ejecuta: newgrp docker"
  exit 1
fi
ok "el daemon de Docker responde"

# ---------------------------------------------------------------------------
# 2. Minikube
# ---------------------------------------------------------------------------
if minikube status >/dev/null 2>&1; then
  ok "Minikube ya esta corriendo"
else
  log "Iniciando Minikube"
  if ! minikube start --driver=docker --cpus=2 --memory=4096; then
    err "Minikube no arranco. Revisa la salida de arriba."
    err "Diagnostico completo:  bash scripts/diagnose.sh"
    exit 1
  fi
fi

log "Habilitando el addon metrics-server"
minikube addons enable metrics-server >/dev/null 2>&1 \
  && ok "metrics-server habilitado" \
  || warn "no se pudo habilitar metrics-server (opcional)"

# ---------------------------------------------------------------------------
# 3. Imagen de la aplicacion
# ---------------------------------------------------------------------------
# Apuntar el cliente Docker al daemon interno de Minikube deja la imagen
# disponible para el cluster sin registro ni 'docker push'.
log "Construyendo la imagen $IMAGEN dentro de Minikube"
eval "$(minikube docker-env)" || { err "no se pudo apuntar al daemon de Minikube"; exit 1; }
if ! docker build -t "$IMAGEN" "$DIR_RAIZ/app"; then
  err "La construccion de la imagen fallo."
  err "Si el error es de red al instalar las dependencias de Python, el proxy"
  err "esta bloqueando pypi.org."
  exit 1
fi
ok "imagen construida"

# ---------------------------------------------------------------------------
# 4. Imagenes del stack de observabilidad
# ---------------------------------------------------------------------------
# Se descargan por adelantado y con reporte individual. Si el proxy bloquea
# Docker Hub, conviene saberlo aqui y no como un ImagePullBackOff silencioso
# cinco minutos despues.
log "Descargando las imagenes del stack"
IMAGENES=(
  "prom/prometheus:v2.54.1"
  "prom/alertmanager:v0.27.0"
  "grafana/grafana:11.2.0"
  "python:3.12-slim"
)
FALLO_PULL=0
for img in "${IMAGENES[@]}"; do
  if docker image inspect "$img" >/dev/null 2>&1; then
    ok "$img (ya presente)"
    continue
  fi
  printf '  descargando %s ... ' "$img"
  if docker pull -q "$img" >/dev/null 2>&1; then
    echo -e "${GREEN}OK${NC}"
  else
    echo -e "${RED}FALLO${NC}"
    FALLO_PULL=$((FALLO_PULL + 1))
  fi
done

if [ "$FALLO_PULL" -gt 0 ]; then
  err "$FALLO_PULL imagen(es) no se pudieron descargar."
  err "Causa mas probable: el proxy de red bloquea registry-1.docker.io."
  err "Comprobalo con:  docker pull hello-world"
  err "Sin estas imagenes el stack no puede arrancar."
  exit 1
fi

# ---------------------------------------------------------------------------
# 5. Manifests
# ---------------------------------------------------------------------------
# Los ejercicios del curso usan el mismo namespace 'monitoring' con nombres
# terminados en '-deployment'. Si quedaron de antes, compiten por los NodePorts.
VIEJOS=$(kubectl get deploy -n monitoring -o name 2>/dev/null | grep -- '-deployment$' || true)
if [ -n "$VIEJOS" ]; then
  warn "hay despliegues de los ejercicios del curso en 'monitoring':"
  echo "$VIEJOS" | sed 's/^/          /'
  warn "pueden chocar en los NodePorts. Para quitarlos:"
  warn "  kubectl delete deploy,svc,cm -n monitoring --all"
fi

log "Aplicando los manifests de Kubernetes"
# El prefijo numerico garantiza el orden: namespaces, aplicacion, Prometheus
# con su RBAC, Alertmanager y Grafana.
if ! kubectl apply -f "$DIR_RAIZ/k8s/"; then
  err "kubectl apply fallo. Revisa el error de arriba."
  exit 1
fi
ok "manifests aplicados"

# ---------------------------------------------------------------------------
# 6. Espera con diagnostico automatico
# ---------------------------------------------------------------------------
# Si un despliegue no llega a estar listo, el motivo casi siempre esta en los
# eventos o en los logs del pod. Se imprimen aqui para no obligar a una
# segunda ronda de comandos.
diagnosticar() {
  local ns="$1" dep="$2"
  err "El despliegue '$dep' no quedo listo. Diagnostico:"
  echo
  echo "--- kubectl describe deploy/$dep -n $ns ---"
  kubectl describe deploy "$dep" -n "$ns" 2>&1 | tail -25
  echo
  echo "--- pods de $dep ---"
  kubectl get pods -n "$ns" -l "app=$dep" -o wide 2>&1
  echo
  echo "--- describe de cada pod (estado de los contenedores y eventos) ---"
  for pod in $(kubectl get pods -n "$ns" -l "app=$dep" -o name 2>/dev/null); do
    echo "=== $pod ==="
    kubectl describe "$pod" -n "$ns" 2>&1 \
      | sed -n '/Containers:/,$p' | head -45
    echo
    echo "--- logs de $pod ---"
    kubectl logs "$pod" -n "$ns" --tail=30 2>&1 | sed 's/^/    /'
    kubectl logs "$pod" -n "$ns" --previous --tail=20 2>/dev/null | sed 's/^/    [anterior] /'
    echo
  done
  echo "--- eventos recientes del namespace $ns ---"
  kubectl get events -n "$ns" --sort-by=.lastTimestamp 2>&1 | tail -20
}

log "Esperando a que los pods esten listos"
ERRORES=0
for ns_dep in "sre-app/sre-app" "monitoring/prometheus" "monitoring/alertmanager" \
              "monitoring/alert-logger" "monitoring/grafana"; do
  ns="${ns_dep%%/*}"; dep="${ns_dep##*/}"
  printf '  %-14s ' "$dep"
  if kubectl rollout status "deployment/$dep" -n "$ns" --timeout=180s >/dev/null 2>&1; then
    echo -e "${GREEN}listo${NC}"
  else
    echo -e "${RED}FALLO${NC}"
    echo
    diagnosticar "$ns" "$dep"
    ERRORES=$((ERRORES + 1))
  fi
done

if [ "$ERRORES" -gt 0 ]; then
  echo
  err "$ERRORES despliegue(s) no quedaron listos."
  err "El diagnostico de arriba tiene la causa. Para un reporte completo:"
  err "  bash scripts/diagnose.sh > /tmp/diagnostico.txt"
  exit 1
fi

# ---------------------------------------------------------------------------
# 7. Accesos
# ---------------------------------------------------------------------------
IP_MINIKUBE="$(minikube ip 2>/dev/null || echo 'no disponible')"

cat <<RESUMEN

$(echo -e "${GREEN}")=======================================================
 Stack desplegado correctamente
=======================================================$(echo -e "${NC}")

 IP de Minikube: ${IP_MINIKUBE}

 Desde WSL2 o Windows, usa port-forward: los puertos quedan
 accesibles como localhost en el navegador de Windows.

   kubectl port-forward -n sre-app     svc/sre-app      5000:5000
   kubectl port-forward -n monitoring  svc/prometheus   9090:9090
   kubectl port-forward -n monitoring  svc/alertmanager 9093:9093
   kubectl port-forward -n monitoring  svc/grafana      3000:3000

 Aplicacion    http://localhost:5000
 Prometheus    http://localhost:9090
 Alertmanager  http://localhost:9093
 Grafana       http://localhost:3000   (admin / admin)

 Siguientes pasos:

   1. Verificar todo:         bash scripts/verify.sh
   2. Generar trafico:        bash scripts/load-test.sh normal 180
   3. Disparar alertas:       bash scripts/load-test.sh errors 120
   4. Ver alertas recibidas:  kubectl logs -n monitoring deploy/alert-logger -f
   5. Abrir el dashboard:     Grafana > Dashboards > SRE > Golden Signals

RESUMEN
