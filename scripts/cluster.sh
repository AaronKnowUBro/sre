#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# cluster.sh - Despliega el stack completo del proyecto final en Minikube
# ---------------------------------------------------------------------------
# Un solo comando levanta todo: cluster, imagen de la aplicacion, Prometheus,
# Alertmanager y Grafana. El script es idempotente: se puede volver a correr
# sin dejar el cluster en un estado inconsistente.
# ---------------------------------------------------------------------------

# -e  aborta en el primer error, para no seguir desplegando sobre una falla.
# -u  falla si se usa una variable sin definir, atrapa errores de tipeo.
# -o pipefail  propaga el error de cualquier comando dentro de una tuberia.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(dirname "$SCRIPT_DIR")"
IMAGE_NAME="sre-final-project-app:latest"

# Colores para que la salida sea legible durante la demo.
GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
NC='\033[0m'

log()  { echo -e "${BLUE}==>${NC} $*"; }
ok()   { echo -e "${GREEN}OK${NC} $*"; }
warn() { echo -e "${YELLOW}!${NC} $*"; }

# ---------------------------------------------------------------------------
# 1. Verificar herramientas
# ---------------------------------------------------------------------------
log "Verificando herramientas requeridas"
for tool in docker minikube kubectl; do
  if ! command -v "$tool" >/dev/null 2>&1; then
    echo "ERROR: falta '$tool'. Instalalo antes de continuar." >&2
    exit 1
  fi
done
ok "docker, minikube y kubectl disponibles"

# ---------------------------------------------------------------------------
# 2. Arrancar Minikube
# ---------------------------------------------------------------------------
if minikube status >/dev/null 2>&1; then
  ok "Minikube ya esta corriendo"
else
  log "Iniciando Minikube"
  minikube start --driver=docker --cpus=2 --memory=4096
fi

# El addon metrics-server habilita 'kubectl top', util para demostrar
# saturacion sin depender solo de cAdvisor.
log "Habilitando el addon metrics-server"
minikube addons enable metrics-server >/dev/null 2>&1 || warn "no se pudo habilitar metrics-server"

# ---------------------------------------------------------------------------
# 3. Construir la imagen dentro del daemon de Minikube
# ---------------------------------------------------------------------------
# Al apuntar el cliente Docker al daemon interno de Minikube, la imagen queda
# disponible para el cluster sin necesidad de un registro ni de 'docker push'.
log "Construyendo la imagen $IMAGE_NAME dentro de Minikube"
eval "$(minikube docker-env)"
docker build -t "$IMAGE_NAME" "$ROOT_DIR/app"
ok "imagen construida"

# ---------------------------------------------------------------------------
# 4. Aplicar los manifests en orden
# ---------------------------------------------------------------------------
# El prefijo numerico garantiza el orden: los namespaces primero, luego la
# aplicacion, despues Prometheus con su RBAC, Alertmanager y Grafana.
log "Aplicando los manifests de Kubernetes"
kubectl apply -f "$ROOT_DIR/k8s/"
ok "manifests aplicados"

# ---------------------------------------------------------------------------
# 5. Esperar a que los despliegues esten listos
# ---------------------------------------------------------------------------
log "Esperando a que los pods esten listos (hasta 3 minutos por despliegue)"
kubectl rollout status deployment/sre-app       -n sre-app     --timeout=180s
kubectl rollout status deployment/prometheus    -n monitoring  --timeout=180s
kubectl rollout status deployment/alertmanager  -n monitoring  --timeout=180s
kubectl rollout status deployment/alert-logger  -n monitoring  --timeout=180s
kubectl rollout status deployment/grafana       -n monitoring  --timeout=180s
ok "todos los despliegues estan listos"

# ---------------------------------------------------------------------------
# 6. Mostrar los accesos
# ---------------------------------------------------------------------------
MINIKUBE_IP="$(minikube ip)"

cat <<RESUMEN

$(echo -e "${GREEN}")=======================================================
 Stack desplegado correctamente
=======================================================$(echo -e "${NC}")

 Aplicacion    http://${MINIKUBE_IP}:30500
 Prometheus    http://${MINIKUBE_IP}:30909
 Alertmanager  http://${MINIKUBE_IP}:30903
 Grafana       http://${MINIKUBE_IP}:30300   (admin / admin)

 En Windows o macOS con el driver docker, la IP de Minikube no es
 alcanzable directamente. Usa port-forward en su lugar:

   kubectl port-forward -n sre-app     svc/sre-app      5000:5000
   kubectl port-forward -n monitoring  svc/prometheus   9090:9090
   kubectl port-forward -n monitoring  svc/alertmanager 9093:9093
   kubectl port-forward -n monitoring  svc/grafana      3000:3000

 Siguientes pasos:

   1. Generar trafico:        ./scripts/load-test.sh
   2. Disparar alertas:       ./scripts/load-test.sh errors
   3. Ver alertas recibidas:  kubectl logs -n monitoring deploy/alert-logger -f
   4. Abrir el dashboard:     Grafana > Dashboards > SRE > Golden Signals

RESUMEN
