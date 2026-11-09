<#
.SYNOPSIS
    Captura los screenshots de evidencia del proyecto con el nombre correcto.

.DESCRIPTION
    Guarda una captura de pantalla en docs/images/ usando los nombres que
    espera el README. Evita tener que renombrar archivos a mano y asegura que
    la evidencia quede consistente.

.PARAMETER Name
    Nombre de la evidencia. Acepta el numero (1 a 9) o el nombre completo.
    Sin este parametro, muestra la lista de capturas pendientes.

.PARAMETER Delay
    Segundos de espera antes de capturar, para acomodar la ventana.
    Por defecto 3.

.PARAMETER Window
    Captura solo la ventana activa en lugar de toda la pantalla.

.EXAMPLE
    .\scripts\capture.ps1
    Muestra que capturas faltan.

.EXAMPLE
    .\scripts\capture.ps1 3
    Captura la pantalla completa como 03-prometheus-targets.png

.EXAMPLE
    .\scripts\capture.ps1 5 -Delay 8 -Window
    Espera 8 segundos y captura solo la ventana activa.
#>

param(
    [Parameter(Position = 0)]
    [string]$Name,
    [int]$Delay = 3,
    [switch]$Window
)

$ErrorActionPreference = 'Stop'

# Las nueve evidencias que pide el README, en orden.
$Evidencias = [ordered]@{
    '1' = @{ archivo = '01-minikube-pods';            desc = 'kubectl get pods -A con todos los pods en Running' }
    '2' = @{ archivo = '02-app-metrics';              desc = 'El endpoint /metrics en el navegador' }
    '3' = @{ archivo = '03-prometheus-targets';       desc = 'Status > Targets con los pods en UP' }
    '4' = @{ archivo = '04-prometheus-query';         desc = 'Una consulta PromQL con datos' }
    '5' = @{ archivo = '05-grafana-dashboard';        desc = 'El dashboard de Golden Signals con trafico' }
    '6' = @{ archivo = '06-prometheus-alert-firing';  desc = 'Una alerta en estado firing' }
    '7' = @{ archivo = '07-alertmanager-alerts';      desc = 'La alerta agrupada en Alertmanager' }
    '8' = @{ archivo = '08-alert-notification';       desc = 'La notificacion recibida en el receptor' }
    '9' = @{ archivo = '09-github-actions';           desc = 'El pipeline de CI en verde' }
}

# La carpeta de destino se resuelve desde la ubicacion del script, para que
# funcione sin importar desde donde se invoque.
$RaizProyecto = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
$Destino = Join-Path $RaizProyecto 'docs\images'

if (-not (Test-Path $Destino)) {
    New-Item -ItemType Directory -Path $Destino -Force | Out-Null
}

# --------------------------------------------------------------------------
# Sin argumentos: mostrar el progreso
# --------------------------------------------------------------------------
if (-not $Name) {
    Write-Host ''
    Write-Host 'Evidencias del proyecto' -ForegroundColor Cyan
    Write-Host '-----------------------' -ForegroundColor Cyan
    $hechas = 0
    foreach ($clave in $Evidencias.Keys) {
        $e = $Evidencias[$clave]
        $ruta = Join-Path $Destino "$($e.archivo).png"
        if (Test-Path $ruta) {
            $hechas++
            Write-Host ("  [LISTA]    {0}  {1}" -f $clave, $e.archivo) -ForegroundColor Green
        } else {
            Write-Host ("  [PENDIENTE] {0}  {1}" -f $clave, $e.archivo) -ForegroundColor Yellow
            Write-Host ("              {0}" -f $e.desc) -ForegroundColor DarkGray
        }
    }
    Write-Host ''
    Write-Host ("Progreso: {0} de {1}" -f $hechas, $Evidencias.Count)
    Write-Host ''
    Write-Host 'Para capturar:  .\scripts\capture.ps1 <numero> [-Delay 5] [-Window]'
    Write-Host ''
    exit 0
}

# --------------------------------------------------------------------------
# Resolver que evidencia se pidio
# --------------------------------------------------------------------------
$elegida = $null
if ($Evidencias.Contains($Name)) {
    $elegida = $Evidencias[$Name].archivo
} else {
    foreach ($clave in $Evidencias.Keys) {
        if ($Evidencias[$clave].archivo -eq $Name) { $elegida = $Name; break }
    }
}

if (-not $elegida) {
    Write-Host "Nombre no reconocido: $Name" -ForegroundColor Red
    Write-Host 'Corre el script sin argumentos para ver la lista.' -ForegroundColor Yellow
    exit 1
}

$RutaSalida = Join-Path $Destino "$elegida.png"

# --------------------------------------------------------------------------
# Capturar
# --------------------------------------------------------------------------
Add-Type -AssemblyName System.Windows.Forms, System.Drawing

if ($Delay -gt 0) {
    Write-Host ''
    Write-Host "Acomoda la ventana que quieres capturar." -ForegroundColor Cyan
    for ($i = $Delay; $i -gt 0; $i--) {
        Write-Host "  capturando en $i..." -NoNewline
        Start-Sleep -Seconds 1
        Write-Host "`r" -NoNewline
    }
    Write-Host '                              ' -NoNewline
    Write-Host "`r" -NoNewline
}

if ($Window) {
    # Solo la ventana en primer plano: evidencia mas limpia, sin el escritorio.
    Add-Type @'
using System;
using System.Runtime.InteropServices;
public class Win32 {
    [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
    [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr hWnd, out RECT lpRect);
    public struct RECT { public int Left, Top, Right, Bottom; }
}
'@
    $hwnd = [Win32]::GetForegroundWindow()
    $rect = New-Object Win32+RECT
    [void][Win32]::GetWindowRect($hwnd, [ref]$rect)
    $x = $rect.Left; $y = $rect.Top
    $ancho = $rect.Right - $rect.Left
    $alto  = $rect.Bottom - $rect.Top
} else {
    # Pantalla completa, incluyendo varios monitores si los hay.
    $limites = [System.Windows.Forms.SystemInformation]::VirtualScreen
    $x = $limites.X; $y = $limites.Y
    $ancho = $limites.Width; $alto = $limites.Height
}

if ($ancho -le 0 -or $alto -le 0) {
    Write-Host 'No se pudo determinar el area a capturar.' -ForegroundColor Red
    exit 1
}

$bitmap  = New-Object System.Drawing.Bitmap $ancho, $alto
$grafico = [System.Drawing.Graphics]::FromImage($bitmap)
$grafico.CopyFromScreen($x, $y, 0, 0, $bitmap.Size)
$bitmap.Save($RutaSalida, [System.Drawing.Imaging.ImageFormat]::Png)
$grafico.Dispose()
$bitmap.Dispose()

$kb = [math]::Round((Get-Item $RutaSalida).Length / 1KB, 1)
Write-Host ''
Write-Host "Guardada: docs/images/$elegida.png  (${ancho}x${alto}, $kb KB)" -ForegroundColor Green
Write-Host ''
