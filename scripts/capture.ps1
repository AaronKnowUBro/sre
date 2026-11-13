<#
.SYNOPSIS
    Captura los screenshots de evidencia del proyecto con el nombre correcto.

.DESCRIPTION
    Guarda una captura en docs/images/ usando los nombres que espera el README.

    El modo recomendado es -Title: el script busca la ventana cuyo titulo
    contenga el texto dado, la trae al frente el mismo y captura solo esa
    ventana. Asi la evidencia no depende de que ventana tenga el foco cuando
    vence la cuenta regresiva, que es la forma mas facil de capturar por
    error una conversacion, un correo o el escritorio entero.

.PARAMETER Name
    Numero (1 a 9) o nombre completo de la evidencia. Sin este parametro,
    muestra la lista de capturas pendientes.

.PARAMETER Title
    Captura la ventana cuyo titulo contenga este texto, sin distinguir
    mayusculas. El script la trae al frente antes de capturar.

.PARAMETER Delay
    Segundos de espera antes de capturar. Por defecto 3, o 1 si se usa -Title,
    donde no hace falta acomodar nada a mano.

.PARAMETER Window
    Captura la ventana activa en el momento del disparo. Menos fiable que
    -Title: depende de donde quede el foco.

.PARAMETER Primary
    Captura solo el monitor principal en lugar de todos los monitores.

.PARAMETER ListWindows
    Muestra los titulos de las ventanas visibles, para saber que pasar a -Title.

.EXAMPLE
    .\capture.ps1 -ListWindows
.EXAMPLE
    .\capture.ps1 3 -Title "Targets"
.EXAMPLE
    .\capture.ps1 1 -Title "WSL" -Delay 2
#>

param(
    [Parameter(Position = 0)]
    [string]$Name,
    [string]$Title,
    [int]$Delay = -1,
    [switch]$Window,
    [switch]$Primary,
    [switch]$ListWindows
)

$ErrorActionPreference = 'Stop'

Add-Type -AssemblyName System.Windows.Forms, System.Drawing

# --------------------------------------------------------------------------
# Interoperabilidad con la API de ventanas de Windows
# --------------------------------------------------------------------------
if (-not ([System.Management.Automation.PSTypeName]'Win32Ventanas').Type) {
    Add-Type @'
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;
using System.Text;

public class Win32Ventanas {
    public struct RECT { public int Left, Top, Right, Bottom; }

    [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
    [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr hWnd);
    [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr hWnd, int nCmdShow);
    [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr hWnd);
    [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr hWnd, out RECT lpRect);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)]
    public static extern int GetWindowText(IntPtr hWnd, StringBuilder lpString, int nMaxCount);
    [DllImport("user32.dll")] public static extern int GetWindowTextLength(IntPtr hWnd);

    private delegate bool EnumProc(IntPtr hWnd, IntPtr lParam);
    [DllImport("user32.dll")] private static extern bool EnumWindows(EnumProc cb, IntPtr lParam);

    // Devuelve las ventanas visibles con titulo, que son las que un usuario
    // puede reconocer y elegir.
    public static List<string[]> Listar() {
        var salida = new List<string[]>();
        EnumWindows(delegate(IntPtr h, IntPtr l) {
            if (!IsWindowVisible(h)) return true;
            int largo = GetWindowTextLength(h);
            if (largo == 0) return true;
            var sb = new StringBuilder(largo + 1);
            GetWindowText(h, sb, sb.Capacity);
            RECT r;
            GetWindowRect(h, out r);
            // Las ventanas diminutas suelen ser auxiliares, no reales.
            if (r.Right - r.Left < 200 || r.Bottom - r.Top < 100) return true;
            salida.Add(new string[] { h.ToString(), sb.ToString() });
            return true;
        }, IntPtr.Zero);
        return salida;
    }
}
'@
}

# --------------------------------------------------------------------------
# Catalogo de evidencias
# --------------------------------------------------------------------------
$Evidencias = [ordered]@{
    '1' = @{ archivo = '01-minikube-pods';           desc = 'kubectl get pods -A con todos los pods en Running' }
    '2' = @{ archivo = '02-app-metrics';             desc = 'El endpoint /metrics en el navegador' }
    '3' = @{ archivo = '03-prometheus-targets';      desc = 'Status > Targets con los pods en UP' }
    '4' = @{ archivo = '04-prometheus-query';        desc = 'Una consulta PromQL con datos' }
    '5' = @{ archivo = '05-grafana-dashboard';       desc = 'El dashboard de Golden Signals con trafico' }
    '6' = @{ archivo = '06-prometheus-alert-firing'; desc = 'Una alerta en estado firing' }
    '7' = @{ archivo = '07-alertmanager-alerts';     desc = 'La alerta agrupada en Alertmanager' }
    '8' = @{ archivo = '08-alert-notification';      desc = 'La notificacion recibida en el receptor' }
    '9' = @{ archivo = '09-github-actions';          desc = 'El pipeline de CI en verde' }
}

$RaizProyecto = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
$Destino = Join-Path $RaizProyecto 'docs\images'
if (-not (Test-Path $Destino)) { New-Item -ItemType Directory -Path $Destino -Force | Out-Null }

# --------------------------------------------------------------------------
# Listar ventanas disponibles
# --------------------------------------------------------------------------
if ($ListWindows) {
    Write-Host ''
    Write-Host 'Ventanas visibles' -ForegroundColor Cyan
    Write-Host '-----------------' -ForegroundColor Cyan
    foreach ($v in [Win32Ventanas]::Listar()) {
        Write-Host ("  {0}" -f $v[1])
    }
    Write-Host ''
    Write-Host 'Usa una parte del titulo con -Title, por ejemplo:' -ForegroundColor DarkGray
    Write-Host '  .\scripts\capture.ps1 3 -Title "Targets"' -ForegroundColor DarkGray
    Write-Host ''
    exit 0
}

# --------------------------------------------------------------------------
# Progreso
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
            Write-Host ("  [LISTA]     {0}  {1}" -f $clave, $e.archivo) -ForegroundColor Green
        } else {
            Write-Host ("  [PENDIENTE] {0}  {1}" -f $clave, $e.archivo) -ForegroundColor Yellow
            Write-Host ("              {0}" -f $e.desc) -ForegroundColor DarkGray
        }
    }
    Write-Host ''
    Write-Host ("Progreso: {0} de {1}" -f $hechas, $Evidencias.Count)
    Write-Host ''
    Write-Host 'Recomendado:  .\scripts\capture.ps1 <numero> -Title "<parte del titulo>"'
    Write-Host 'Ver ventanas: .\scripts\capture.ps1 -ListWindows'
    Write-Host ''
    exit 0
}

# --------------------------------------------------------------------------
# Resolver la evidencia pedida
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
# Determinar el area a capturar
# --------------------------------------------------------------------------
if ($Delay -lt 0) { $Delay = if ($Title) { 1 } else { 3 } }

$x = 0; $y = 0; $ancho = 0; $alto = 0

if ($Title) {
    # Se busca por coincidencia parcial del titulo y se exige que sea unica:
    # capturar la ventana equivocada en silencio es peor que fallar.
    $coincidencias = @([Win32Ventanas]::Listar() | Where-Object { $_[1] -like "*$Title*" })

    if ($coincidencias.Count -eq 0) {
        Write-Host ''
        Write-Host "No hay ninguna ventana cuyo titulo contenga '$Title'." -ForegroundColor Red
        Write-Host 'Lista las ventanas disponibles con:' -ForegroundColor Yellow
        Write-Host '  .\scripts\capture.ps1 -ListWindows' -ForegroundColor Yellow
        Write-Host ''
        exit 1
    }
    if ($coincidencias.Count -gt 1) {
        Write-Host ''
        Write-Host "Hay $($coincidencias.Count) ventanas que coinciden con '$Title':" -ForegroundColor Yellow
        foreach ($c in $coincidencias) { Write-Host ("  {0}" -f $c[1]) }
        Write-Host 'Usa un texto mas especifico.' -ForegroundColor Yellow
        Write-Host ''
        exit 1
    }

    $hwnd = [IntPtr]::new([int64]$coincidencias[0][0])
    Write-Host ''
    Write-Host ("Capturando: {0}" -f $coincidencias[0][1]) -ForegroundColor Cyan

    # 9 = SW_RESTORE: si estaba minimizada, la restaura.
    [void][Win32Ventanas]::ShowWindow($hwnd, 9)
    [void][Win32Ventanas]::SetForegroundWindow($hwnd)
    Start-Sleep -Milliseconds 700
    if ($Delay -gt 0) { Start-Sleep -Seconds $Delay }

    $rect = New-Object Win32Ventanas+RECT
    [void][Win32Ventanas]::GetWindowRect($hwnd, [ref]$rect)
    $x = $rect.Left; $y = $rect.Top
    $ancho = $rect.Right - $rect.Left
    $alto  = $rect.Bottom - $rect.Top
}
else {
    if ($Delay -gt 0) {
        Write-Host ''
        Write-Host 'Acomoda la ventana que quieres capturar.' -ForegroundColor Cyan
        for ($i = $Delay; $i -gt 0; $i--) {
            Write-Host ("  capturando en $i...  ") -NoNewline
            Start-Sleep -Seconds 1
            Write-Host "`r" -NoNewline
        }
        Write-Host '                              ' -NoNewline
        Write-Host "`r" -NoNewline
    }

    if ($Window) {
        $hwnd = [Win32Ventanas]::GetForegroundWindow()
        $rect = New-Object Win32Ventanas+RECT
        [void][Win32Ventanas]::GetWindowRect($hwnd, [ref]$rect)
        $x = $rect.Left; $y = $rect.Top
        $ancho = $rect.Right - $rect.Left
        $alto  = $rect.Bottom - $rect.Top

        $titulo = New-Object System.Text.StringBuilder 512
        [void][Win32Ventanas]::GetWindowText($hwnd, $titulo, 512)
        Write-Host ("Ventana capturada: {0}" -f $titulo.ToString()) -ForegroundColor DarkGray
    }
    elseif ($Primary) {
        $p = [System.Windows.Forms.Screen]::PrimaryScreen.Bounds
        $x = $p.X; $y = $p.Y; $ancho = $p.Width; $alto = $p.Height
    }
    else {
        $v = [System.Windows.Forms.SystemInformation]::VirtualScreen
        $x = $v.X; $y = $v.Y; $ancho = $v.Width; $alto = $v.Height
        if ([System.Windows.Forms.Screen]::AllScreens.Count -gt 1) {
            Write-Host ''
            Write-Host 'AVISO: se van a capturar los ' -NoNewline -ForegroundColor Yellow
            Write-Host ("{0} monitores" -f [System.Windows.Forms.Screen]::AllScreens.Count) -NoNewline -ForegroundColor Yellow
            Write-Host ', incluido todo lo que haya abierto en ellos.' -ForegroundColor Yellow
            Write-Host 'Usa -Title "<parte del titulo>" para capturar solo una ventana.' -ForegroundColor Yellow
            Write-Host ''
        }
    }
}

if ($ancho -le 0 -or $alto -le 0) {
    Write-Host 'No se pudo determinar el area a capturar.' -ForegroundColor Red
    exit 1
}

# --------------------------------------------------------------------------
# Capturar y guardar
# --------------------------------------------------------------------------
$bitmap  = New-Object System.Drawing.Bitmap $ancho, $alto
$grafico = [System.Drawing.Graphics]::FromImage($bitmap)
$grafico.CopyFromScreen($x, $y, 0, 0, $bitmap.Size)
$bitmap.Save($RutaSalida, [System.Drawing.Imaging.ImageFormat]::Png)
$grafico.Dispose()
$bitmap.Dispose()

$kb = [math]::Round((Get-Item $RutaSalida).Length / 1KB, 1)
Write-Host ("Guardada: docs/images/{0}.png  ({1}x{2}, {3} KB)" -f $elegida, $ancho, $alto, $kb) -ForegroundColor Green
Write-Host ''
