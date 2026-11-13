#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# capture.sh - Envoltorio para llamar capture.ps1 desde WSL
# ---------------------------------------------------------------------------
# Las capturas de pantalla solo las puede tomar Windows, pero el resto del
# flujo de trabajo (kubectl, minikube, los demas scripts) vive en WSL. Cambiar
# de terminal a cada paso es una fuente constante de errores, asi que este
# envoltorio invoca powershell.exe desde WSL: la interoperabilidad de WSL2
# permite ejecutar binarios de Windows directamente.
#
# Uso, identico al del script de PowerShell:
#   bash scripts/capture.sh                    ver el progreso
#   bash scripts/capture.sh 7 -Delay 8 -Window capturar la evidencia 7
# ---------------------------------------------------------------------------

set -uo pipefail

DIR_SCRIPT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if ! command -v powershell.exe >/dev/null 2>&1; then
  cat >&2 <<'MSG'
ERROR: no se encuentra powershell.exe

Este envoltorio necesita la interoperabilidad con Windows de WSL2. Si esta
desactivada, ejecuta el script desde una ventana de PowerShell:

  cd "<carpeta del proyecto>"
  Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass -Force
  .\scripts\capture.ps1
MSG
  exit 1
fi

if ! command -v wslpath >/dev/null 2>&1; then
  echo "ERROR: falta wslpath. Ejecutalo desde WSL2." >&2
  exit 1
fi

# wslpath traduce /mnt/c/... al formato C:\... que PowerShell entiende.
RUTA_PS1="$(wslpath -w "$DIR_SCRIPT/capture.ps1")"

# -NoProfile evita cargar el perfil del usuario, que puede tardar o fallar.
# -ExecutionPolicy Bypass permite ejecutar el .ps1 sin cambiar nada de forma
# permanente en el equipo.
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "$RUTA_PS1" "$@"
