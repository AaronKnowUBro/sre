#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# setup-wsl.sh - Instala Docker Engine, kubectl, Minikube y Helm en WSL2
# ---------------------------------------------------------------------------
# Pensado para Ubuntu en WSL2 sobre Windows, donde Docker Desktop no esta
# disponible. Docker Engine es open source y no requiere la licencia comercial
# que Docker Desktop exige en empresas grandes.
#
# Uso (dentro de WSL, no en PowerShell):
#   bash scripts/setup-wsl.sh
#
# Pedira la contrasena de sudo de tu usuario de Ubuntu.
# ---------------------------------------------------------------------------

set -uo pipefail

GREEN='\033[0;32m'; BLUE='\033[0;34m'; YELLOW='\033[1;33m'; RED='\033[0;31m'; NC='\033[0m'
log()  { echo -e "\n${BLUE}==>${NC} $*"; }
ok()   { echo -e "${GREEN}  OK${NC} $*"; }
warn() { echo -e "${YELLOW}  AVISO${NC} $*"; }
err()  { echo -e "${RED}  ERROR${NC} $*"; }

# ---------------------------------------------------------------------------
log "Comprobando el entorno"
# ---------------------------------------------------------------------------
if ! grep -qi microsoft /proc/version 2>/dev/null; then
  err "Esto no parece WSL. Ejecutalo dentro de Ubuntu, no en PowerShell ni Git Bash."
  exit 1
fi
ok "corriendo en WSL"
ok "distribucion: $(. /etc/os-release && echo "$PRETTY_NAME")"
ok "arquitectura: $(uname -m)"

# ---------------------------------------------------------------------------
log "Comprobando salida a internet"
# ---------------------------------------------------------------------------
# Si la red corporativa bloquea alguno de estos, lo mejor es saberlo ahora y no
# a mitad de una instalacion.
FALLOS_RED=0
for host in https://download.docker.com https://dl.k8s.io https://storage.googleapis.com https://registry-1.docker.io/v2/; do
  codigo=$(curl -sS -o /dev/null -w '%{http_code}' --max-time 15 "$host" 2>/dev/null)
  if [ "$codigo" != "000" ] && [ -n "$codigo" ]; then
    ok "$host  (HTTP $codigo)"
  else
    err "$host  sin respuesta"
    FALLOS_RED=$((FALLOS_RED + 1))
  fi
done
if [ "$FALLOS_RED" -gt 0 ]; then
  warn "$FALLOS_RED destino(s) sin respuesta. Puede ser el proxy corporativo."
  warn "Si la instalacion falla mas adelante, ese es el motivo probable."
fi

# ---------------------------------------------------------------------------
log "Actualizando indices de paquetes"
# ---------------------------------------------------------------------------
sudo apt-get update -qq || { err "apt-get update fallo"; exit 1; }
sudo apt-get install -y -qq ca-certificates curl gnupg lsb-release conntrack >/dev/null
ok "dependencias base instaladas (conntrack lo necesita Minikube)"

# ---------------------------------------------------------------------------
log "Instalando Docker Engine"
# ---------------------------------------------------------------------------
if command -v docker >/dev/null 2>&1; then
  ok "docker ya esta instalado: $(docker --version)"
else
  # Se intenta el repositorio oficial de Docker, que trae la version actual.
  # Si el proxy lo bloquea, se recurre al paquete docker.io de Ubuntu, que es
  # mas antiguo pero suficiente para Minikube.
  INSTALADO=0
  sudo install -m 0755 -d /etc/apt/keyrings
  if curl -fsSL --max-time 30 https://download.docker.com/linux/ubuntu/gpg \
       | sudo gpg --dearmor -o /etc/apt/keyrings/docker.gpg 2>/dev/null; then
    sudo chmod a+r /etc/apt/keyrings/docker.gpg
    echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu $(. /etc/os-release && echo "$VERSION_CODENAME") stable" \
      | sudo tee /etc/apt/sources.list.d/docker.list >/dev/null
    if sudo apt-get update -qq 2>/dev/null && \
       sudo apt-get install -y -qq docker-ce docker-ce-cli containerd.io docker-buildx-plugin >/dev/null 2>&1; then
      INSTALADO=1
      ok "Docker Engine instalado desde el repositorio oficial"
    fi
  fi

  if [ "$INSTALADO" -eq 0 ]; then
    warn "el repositorio oficial no funciono, probando el paquete de Ubuntu"
    sudo rm -f /etc/apt/sources.list.d/docker.list
    sudo apt-get update -qq
    if sudo apt-get install -y -qq docker.io >/dev/null 2>&1; then
      ok "docker.io instalado desde los repositorios de Ubuntu"
    else
      err "no se pudo instalar Docker por ninguna via"
      exit 1
    fi
  fi
fi

# ---------------------------------------------------------------------------
log "Configurando el acceso a Docker sin sudo"
# ---------------------------------------------------------------------------
sudo groupadd -f docker
sudo usermod -aG docker "$USER"
ok "usuario $USER agregado al grupo docker"

# WSL en Ubuntu 24.04 trae systemd activo; en configuraciones mas viejas hay
# que arrancar el servicio a mano. Se cubren ambos casos.
if command -v systemctl >/dev/null 2>&1 && systemctl is-system-running --quiet 2>/dev/null; then
  sudo systemctl enable --now docker >/dev/null 2>&1
  ok "docker arrancado con systemd"
else
  sudo service docker start >/dev/null 2>&1
  ok "docker arrancado con service"
  # Sin systemd el daemon no sobrevive al reinicio de WSL: conviene
  # arrancarlo al abrir la shell.
  if ! grep -q "service docker start" "$HOME/.bashrc" 2>/dev/null; then
    cat >> "$HOME/.bashrc" <<'BRC'

# Arranca el daemon de Docker si no esta corriendo (WSL sin systemd)
if ! service docker status >/dev/null 2>&1; then
  sudo service docker start >/dev/null 2>&1
fi
BRC
    ok "arranque automatico agregado a ~/.bashrc"
  fi
fi

sleep 3
if sudo docker info >/dev/null 2>&1; then
  ok "el daemon de Docker responde"
else
  err "el daemon de Docker no responde. Intenta: sudo service docker start"
fi

# ---------------------------------------------------------------------------
log "Instalando kubectl"
# ---------------------------------------------------------------------------
if command -v kubectl >/dev/null 2>&1; then
  ok "kubectl ya esta instalado: $(kubectl version --client -o json 2>/dev/null | grep -o '"gitVersion":"[^"]*"' | head -1)"
else
  VER=$(curl -fsSL --max-time 20 https://dl.k8s.io/release/stable.txt 2>/dev/null)
  if [ -n "$VER" ] && curl -fsSLo /tmp/kubectl --max-time 120 "https://dl.k8s.io/release/${VER}/bin/linux/amd64/kubectl"; then
    sudo install -o root -g root -m 0755 /tmp/kubectl /usr/local/bin/kubectl
    rm -f /tmp/kubectl
    ok "kubectl $VER instalado"
  else
    err "no se pudo descargar kubectl"
  fi
fi

# ---------------------------------------------------------------------------
log "Instalando Minikube"
# ---------------------------------------------------------------------------
if command -v minikube >/dev/null 2>&1; then
  ok "minikube ya esta instalado: $(minikube version --short 2>/dev/null)"
else
  if curl -fsSLo /tmp/minikube --max-time 180 https://storage.googleapis.com/minikube/releases/latest/minikube-linux-amd64; then
    sudo install -o root -g root -m 0755 /tmp/minikube /usr/local/bin/minikube
    rm -f /tmp/minikube
    ok "minikube instalado: $(minikube version --short 2>/dev/null)"
  else
    err "no se pudo descargar minikube"
  fi
fi

# ---------------------------------------------------------------------------
log "Instalando Helm (opcional, para el bonus de IaC)"
# ---------------------------------------------------------------------------
if command -v helm >/dev/null 2>&1; then
  ok "helm ya esta instalado: $(helm version --short 2>/dev/null)"
else
  if curl -fsSLo /tmp/helm.tar.gz --max-time 120 https://get.helm.sh/helm-v3.15.4-linux-amd64.tar.gz; then
    tar -xzf /tmp/helm.tar.gz -C /tmp
    sudo install -o root -g root -m 0755 /tmp/linux-amd64/helm /usr/local/bin/helm
    rm -rf /tmp/helm.tar.gz /tmp/linux-amd64
    ok "helm instalado: $(helm version --short 2>/dev/null)"
  else
    warn "no se pudo descargar helm; es opcional, el proyecto funciona sin el"
  fi
fi

# ---------------------------------------------------------------------------
log "Resumen"
# ---------------------------------------------------------------------------
for t in docker kubectl minikube helm; do
  if command -v $t >/dev/null 2>&1; then
    printf '  [OK]    %s\n' "$t"
  else
    printf '  [FALTA] %s\n' "$t"
  fi
done

cat <<'FINAL'

---------------------------------------------------------------
IMPORTANTE: el grupo docker no aplica a esta sesion todavia.

Cierra esta terminal de WSL y abre una nueva, o ejecuta:

    newgrp docker

Despues comprueba que funciona sin sudo:

    docker run --rm hello-world

Y cuando eso pase, despliega el stack:

    bash scripts/cluster.sh
    bash scripts/verify.sh

Nota: usa 'bash scripts/...' y no './scripts/...'. Los archivos estan en el
sistema de archivos de Windows (/mnt/c), que no conserva el bit de ejecucion.
---------------------------------------------------------------

FINAL
