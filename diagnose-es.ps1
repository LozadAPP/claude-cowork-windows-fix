# =============================================================================
# Herramienta de Diagnostico Claude Cowork Windows
# Version: 1.0.0
# Autor: @LozadAPP
# Proposito: Diagnosticar problemas comunes con Claude Desktop Cowork en Windows
# AVISO: Este script es SOLO LECTURA. NO modifica nada en tu sistema.
# =============================================================================

#Requires -Version 5.1

# --- Configuracion ---
$ScriptVersion = "1.0.0"
$MinBuild = 26200
$MinUBR = 8117

# --- Funciones auxiliares ---

function Write-Banner {
    Write-Host ""
    Write-Host "  ============================================================" -ForegroundColor Cyan
    Write-Host "  |                                                          |" -ForegroundColor Cyan
    Write-Host "  |    Herramienta de Diagnostico Claude Cowork Windows      |" -ForegroundColor Cyan
    Write-Host "  |    Version $ScriptVersion                                       |" -ForegroundColor Cyan
    Write-Host "  |    Autor: @LozadAPP                                     |" -ForegroundColor Cyan
    Write-Host "  |                                                          |" -ForegroundColor Cyan
    Write-Host "  |    Este script es SOLO DIAGNOSTICO - no modifica nada    |" -ForegroundColor Cyan
    Write-Host "  ============================================================" -ForegroundColor Cyan
    Write-Host ""
}

function Write-SectionHeader {
    param([string]$Number, [string]$Title)
    Write-Host ""
    Write-Host "  [$Number] $Title" -ForegroundColor White
    Write-Host "  $('-' * ($Title.Length + $Number.Length + 4))" -ForegroundColor DarkGray
}

function Write-OK {
    param([string]$Message)
    Write-Host "      [OK] $Message" -ForegroundColor Green
}

function Write-Warn {
    param([string]$Message)
    Write-Host "      [!!] $Message" -ForegroundColor Yellow
}

function Write-Err {
    param([string]$Message)
    Write-Host "      [XX] $Message" -ForegroundColor Red
}

function Write-Info {
    param([string]$Message)
    Write-Host "      [--] $Message" -ForegroundColor Gray
}

# --- Seguimiento del resumen ---
$summary = [ordered]@{}
$actions = @()

# Verificar si se ejecuta como administrador
$isAdmin = ([Security.Principal.WindowsPrincipal] [Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)

Write-Banner

if (-not $isAdmin) {
    Write-Host "  NOTA: Ejecutando sin privilegios de Administrador." -ForegroundColor Yellow
    Write-Host "  Algunas verificaciones (bcdedit, caracteristicas Hyper-V) pueden estar limitadas." -ForegroundColor Yellow
    Write-Host "  Para diagnostico completo, clic derecho en PowerShell -> Ejecutar como Administrador." -ForegroundColor Yellow
    Write-Host ""
}

# =============================================================================
# 1. VERSION DE WINDOWS
# =============================================================================
Write-SectionHeader "1" "Version de Windows"

try {
    $ntInfo = Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion'
    $displayVersion = $ntInfo.DisplayVersion
    $buildNumber = [int]$ntInfo.CurrentBuildNumber
    $ubr = [int]$ntInfo.UBR
    $fullBuild = "$buildNumber.$ubr"
    $productName = $ntInfo.ProductName

    Write-Info "Producto: $productName"
    Write-Info "Version: $displayVersion (Build $fullBuild)"

    if ($buildNumber -lt $MinBuild -or ($buildNumber -eq $MinBuild -and $ubr -lt $MinUBR)) {
        Write-Warn "El Build $fullBuild es mas antiguo que el recomendado $MinBuild.$MinUBR"
        Write-Warn "Por favor actualiza Windows a la ultima version."
        $summary["Version de Windows"] = @{ Status = "WARN"; Detail = "Build $fullBuild (actualizacion recomendada)" }
        $actions += "Actualizar Windows al build $MinBuild.$MinUBR o posterior via Configuracion > Windows Update."
    } else {
        Write-OK "El Build $fullBuild cumple con el requisito minimo."
        $summary["Version de Windows"] = @{ Status = "OK"; Detail = "Build $fullBuild" }
    }
} catch {
    Write-Err "No se pudo leer la version de Windows del registro."
    $summary["Version de Windows"] = @{ Status = "ERR"; Detail = "No se pudo leer" }
}

# =============================================================================
# 2. ACTIVACION DE WINDOWS
# =============================================================================
Write-SectionHeader "2" "Activacion de Windows"

try {
    $licenseProducts = Get-CimInstance SoftwareLicensingProduct -Filter "Name like 'Windows%'" -ErrorAction Stop |
        Where-Object { $_.PartialProductKey }

    if ($licenseProducts) {
        $licenseStatus = $licenseProducts | Select-Object -First 1 -ExpandProperty LicenseStatus
        # LicenseStatus: 0=Sin licencia, 1=Licenciado, 2=Periodo de gracia OOB, 3=Periodo de gracia OOT, 4=Periodo de gracia No Genuino, 5=Notificacion, 6=Periodo de gracia Extendido
        $statusMap = @{
            0 = "Sin licencia"
            1 = "Licenciado (Activado)"
            2 = "Periodo de gracia inicial"
            3 = "Periodo de gracia por tolerancia"
            4 = "Periodo de gracia No Genuino"
            5 = "Modo de notificacion"
            6 = "Periodo de gracia extendido"
        }
        $statusText = if ($statusMap.ContainsKey($licenseStatus)) { $statusMap[$licenseStatus] } else { "Desconocido ($licenseStatus)" }

        if ($licenseStatus -eq 1) {
            Write-OK "Windows esta activado: $statusText"
            $summary["Activacion de Windows"] = @{ Status = "OK"; Detail = "Activado" }
        } else {
            Write-Warn "Windows NO esta completamente activado: $statusText"
            Write-Warn "Algunas funciones de Cowork pueden fallar sin una activacion correcta."
            $summary["Activacion de Windows"] = @{ Status = "WARN"; Detail = $statusText }
            $actions += "Activar Windows con una clave de licencia valida via Configuracion > Activacion."
        }
    } else {
        Write-Warn "No se encontro ningun producto de licencia de Windows con clave parcial."
        $summary["Activacion de Windows"] = @{ Status = "WARN"; Detail = "No se encontro licencia" }
        $actions += "Activar Windows con una clave de licencia valida."
    }
} catch {
    Write-Warn "No se pudo consultar el estado de la licencia (puede necesitar admin): $($_.Exception.Message)"
    $summary["Activacion de Windows"] = @{ Status = "WARN"; Detail = "No se pudo verificar" }
}

# =============================================================================
# 3. UBICACION DE ALMACENAMIENTO DE APPS (CRITICO)
# =============================================================================
Write-SectionHeader "3" "Ubicacion de Almacenamiento de Apps (CRITICO)"

$appStorageProblem = $false
$claudePackagePath = Join-Path $env:LOCALAPPDATA "Packages\Claude_pzs8sxrjxfjjc"

if (Test-Path $claudePackagePath) {
    Write-Info "Carpeta del paquete Claude encontrada: $claudePackagePath"

    # Verificar symlinks (ReparsePoints) dentro de la carpeta del paquete
    try {
        $reparseItems = Get-ChildItem -Path $claudePackagePath -Force -ErrorAction SilentlyContinue |
            Where-Object { $_.Attributes -band [System.IO.FileAttributes]::ReparsePoint }

        if ($reparseItems -and $reparseItems.Count -gt 0) {
            Write-Err "Se encontraron symlinks (ReparsePoints) dentro de la carpeta del paquete Claude!"

            foreach ($item in $reparseItems) {
                $target = $null
                try {
                    $target = (Get-Item $item.FullName -Force).Target
                } catch {
                    $target = "destino desconocido"
                }
                Write-Err "  -> $($item.Name) => $target"

                # Verificar si el symlink apunta a una unidad diferente
                $itemDrive = (Split-Path $item.FullName -Qualifier)
                if ($target -and $target -is [string]) {
                    $targetDrive = if ($target -match '^([A-Z]:)') { $Matches[1] } else { $null }
                    if ($targetDrive -and $targetDrive -ne $itemDrive) {
                        $appStorageProblem = $true
                    }
                } elseif ($target -and $target -is [array]) {
                    foreach ($t in $target) {
                        $targetDrive = if ($t -match '^([A-Z]:)') { $Matches[1] } else { $null }
                        if ($targetDrive -and $targetDrive -ne $itemDrive) {
                            $appStorageProblem = $true
                        }
                    }
                }
            }

            if ($appStorageProblem) {
                Write-Host ""
                Write-Host "      !!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!" -ForegroundColor Red
                Write-Host "      !!  CRITICO: El almacenamiento de apps esta         !!" -ForegroundColor Red
                Write-Host "      !!  redirigido a otra unidad via symlinks! Esto es   !!" -ForegroundColor Red
                Write-Host "      !!  probablemente la causa de AMBOS errores:         !!" -ForegroundColor Red
                Write-Host "      !!  'signature verification failed' Y                !!" -ForegroundColor Red
                Write-Host "      !!  'EXDEV: cross-device link not permitted'.        !!" -ForegroundColor Red
                Write-Host "      !!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!" -ForegroundColor Red
                Write-Host ""
                Write-Err "Windows esta configurado para guardar nuevas apps en una unidad diferente."
                Write-Err "Los datos del paquete de Claude terminan en un volumen separado, causando"
                Write-Err "errores de enlace entre dispositivos cuando el servicio VM intenta acceder."
                $summary["Almacenamiento Apps"] = @{ Status = "ERR"; Detail = "Redirigido a otra unidad (PROBLEMA!)" }
                $actions += "CRITICO: Cambiar 'Las nuevas apps se guardaran en' de vuelta a C: en Configuracion > Sistema > Almacenamiento > Configuracion avanzada de almacenamiento > Donde se guarda el contenido nuevo. Luego desinstalar y reinstalar Claude Desktop."
            } else {
                Write-Warn "Se encontraron symlinks pero parecen estar en la misma unidad."
                $summary["Almacenamiento Apps"] = @{ Status = "WARN"; Detail = "Symlinks encontrados (misma unidad)" }
            }
        } else {
            Write-OK "No se encontraron symlinks en la carpeta del paquete Claude. La ubicacion de almacenamiento parece correcta."
            $summary["Almacenamiento Apps"] = @{ Status = "OK"; Detail = "Unidad C: (correcto)" }
        }
    } catch {
        Write-Warn "No se pudo inspeccionar el contenido de la carpeta del paquete Claude: $($_.Exception.Message)"
        $summary["Almacenamiento Apps"] = @{ Status = "WARN"; Detail = "No se pudo inspeccionar" }
    }
} else {
    Write-Info "Carpeta del paquete Claude no encontrada en la ubicacion esperada."

    # Verificar si D:\WpSystem tiene datos de Claude (sintoma alternativo)
    $dWpSystem = "D:\WpSystem"
    $dClaudeFound = $false
    if (Test-Path $dWpSystem) {
        try {
            $dClaudeItems = Get-ChildItem -Path $dWpSystem -Recurse -Directory -Filter "Claude_pzs8sxrjxfjjc" -ErrorAction SilentlyContinue
            if ($dClaudeItems) {
                $dClaudeFound = $true
                Write-Err "Se encontraron datos de Claude en la unidad D: en: $($dClaudeItems[0].FullName)"
                Write-Err "Esto sugiere fuertemente que el almacenamiento de apps esta redirigido a D:\"
                $appStorageProblem = $true
                $summary["Almacenamiento Apps"] = @{ Status = "ERR"; Detail = "Unidad D:\ (PROBLEMA!)" }
                $actions += "CRITICO: Cambiar 'Las nuevas apps se guardaran en' de vuelta a C: en Configuracion > Sistema > Almacenamiento > Configuracion avanzada de almacenamiento > Donde se guarda el contenido nuevo. Luego desinstalar y reinstalar Claude Desktop."
            }
        } catch {
            # Ignorar errores de acceso en D:\WpSystem
        }
    }

    if (-not $dClaudeFound) {
        Write-Info "Claude puede no estar instalado aun, o la carpeta del paquete usa un sufijo diferente."
        $summary["Almacenamiento Apps"] = @{ Status = "OK"; Detail = "No se detectaron problemas" }
    }
}

# =============================================================================
# 4. ESTADO DE HYPER-V
# =============================================================================
Write-SectionHeader "4" "Estado de Hyper-V"

$hyperVFeatures = @("Microsoft-Hyper-V", "VirtualMachinePlatform", "HypervisorPlatform")
$hyperVAllOK = $true

foreach ($feature in $hyperVFeatures) {
    try {
        $featureInfo = Get-WindowsOptionalFeature -Online -FeatureName $feature -ErrorAction Stop
        if ($featureInfo.State -eq "Enabled") {
            Write-OK "$feature : Habilitado"
        } else {
            Write-Err "$feature : $($featureInfo.State)"
            $hyperVAllOK = $false
        }
    } catch {
        Write-Warn "$feature : No se pudo verificar (puede requerir admin)"
        $hyperVAllOK = $false
    }
}

if ($hyperVAllOK) {
    $summary["Hyper-V"] = @{ Status = "OK"; Detail = "Todas las caracteristicas habilitadas" }
} else {
    $summary["Hyper-V"] = @{ Status = "ERR"; Detail = "Una o mas caracteristicas deshabilitadas/desconocidas" }
    $actions += "Habilitar caracteristicas de Hyper-V: Abrir PowerShell como Admin y ejecutar: Enable-WindowsOptionalFeature -Online -FeatureName Microsoft-Hyper-V -All"
}

# =============================================================================
# 5. ESTADO DE WSL2
# =============================================================================
Write-SectionHeader "5" "Estado de WSL2"

try {
    $wslOutput = & wsl --status 2>&1 | Out-String
    $wslText = $wslOutput

    if ($wslText -match "Default Version:\s*2" -or $wslText -match "version.*2" -or $wslText -match "WSL 2" -or $wslText -match "predeterminada:\s*2" -or $wslText -match "2") {
        Write-OK "WSL2 parece estar configurado."
        $summary["WSL2"] = @{ Status = "OK"; Detail = "Instalado" }
    } elseif ($wslText -match "not recognized" -or $wslText -match "is not installed") {
        Write-Err "WSL no esta instalado."
        $summary["WSL2"] = @{ Status = "ERR"; Detail = "No instalado" }
        $actions += "Instalar WSL2: Abrir PowerShell como Admin y ejecutar: wsl --install"
    } else {
        Write-Warn "WSL esta instalado pero puede no ser la version 2."
        Write-Info "Salida de WSL: $($wslOutput | Select-Object -First 3 | Out-String)"
        $summary["WSL2"] = @{ Status = "WARN"; Detail = "Instalado (version no clara)" }
        $actions += "Asegurar que la version predeterminada de WSL sea 2: wsl --set-default-version 2"
    }
} catch {
    Write-Err "No se pudo ejecutar 'wsl --status': $($_.Exception.Message)"
    $summary["WSL2"] = @{ Status = "ERR"; Detail = "No se pudo verificar" }
    $actions += "Instalar WSL2: Abrir PowerShell como Admin y ejecutar: wsl --install"
}

# =============================================================================
# 6. TIPO DE INICIO DEL HYPERVISOR
# =============================================================================
Write-SectionHeader "6" "Tipo de Inicio del Hypervisor"

if ($isAdmin) {
    try {
        $bcdeditOutput = & bcdedit /enum 2>&1 | Out-String
        if ($bcdeditOutput -match "hypervisorlaunchtype\s+Auto") {
            Write-OK "El tipo de inicio del hypervisor esta configurado en Auto."
            $summary["Inicio Hypervisor"] = @{ Status = "OK"; Detail = "Auto" }
        } elseif ($bcdeditOutput -match "hypervisorlaunchtype\s+(\w+)") {
            $launchType = $Matches[1]
            Write-Err "El tipo de inicio del hypervisor es '$launchType' (deberia ser 'Auto')."
            $summary["Inicio Hypervisor"] = @{ Status = "ERR"; Detail = $launchType }
            $actions += "Configurar tipo de inicio del hypervisor en Auto: Ejecutar como Admin: bcdedit /set hypervisorlaunchtype auto, luego reiniciar."
        } else {
            Write-Warn "No se pudo determinar el tipo de inicio del hypervisor desde la salida de bcdedit."
            $summary["Inicio Hypervisor"] = @{ Status = "WARN"; Detail = "No se pudo determinar" }
        }
    } catch {
        Write-Warn "No se pudo ejecutar bcdedit: $($_.Exception.Message)"
        $summary["Inicio Hypervisor"] = @{ Status = "WARN"; Detail = "No se pudo verificar" }
    }
} else {
    Write-Warn "Omitido: requiere privilegios de Administrador."
    Write-Info "Vuelve a ejecutar este script como Administrador para verificar el tipo de inicio del hypervisor."
    $summary["Inicio Hypervisor"] = @{ Status = "WARN"; Detail = "Necesita admin" }
}

# =============================================================================
# 7. INSTALACION DE CLAUDE DESKTOP
# =============================================================================
Write-SectionHeader "7" "Instalacion de Claude Desktop"

try {
    $claudePackage = Get-AppxPackage -Name "Claude" -ErrorAction SilentlyContinue

    if ($claudePackage) {
        Write-OK "Claude Desktop esta instalado."
        Write-Info "Version: $($claudePackage.Version)"
        Write-Info "Ubicacion de instalacion: $($claudePackage.InstallLocation)"
        Write-Info "Nombre completo del paquete: $($claudePackage.PackageFullName)"
        $summary["Claude Desktop"] = @{ Status = "OK"; Detail = "v$($claudePackage.Version)" }
    } else {
        Write-Err "Claude Desktop NO esta instalado (no encontrado via Get-AppxPackage)."
        $summary["Claude Desktop"] = @{ Status = "ERR"; Detail = "No instalado" }
        $actions += "Instalar Claude Desktop desde la Microsoft Store o https://claude.ai/download"
    }
} catch {
    Write-Warn "No se pudo verificar Claude Desktop: $($_.Exception.Message)"
    $summary["Claude Desktop"] = @{ Status = "WARN"; Detail = "No se pudo verificar" }
}

# =============================================================================
# 8. ESTADO DEL COWORKVMSERVICE
# =============================================================================
Write-SectionHeader "8" "Estado del CoworkVMService"

try {
    $coworkService = Get-Service -Name "CoworkVMService" -ErrorAction Stop

    if ($coworkService.Status -eq "Running") {
        Write-OK "CoworkVMService esta en ejecucion."
        $summary["CoworkVMService"] = @{ Status = "OK"; Detail = "En ejecucion" }
    } elseif ($coworkService.Status -eq "Stopped") {
        Write-Warn "CoworkVMService esta detenido."
        $summary["CoworkVMService"] = @{ Status = "WARN"; Detail = "Detenido" }
        $actions += "Iniciar CoworkVMService: Abrir Servicios (services.msc) e iniciarlo, o ejecutar: Start-Service CoworkVMService"
    } else {
        Write-Warn "Estado de CoworkVMService: $($coworkService.Status)"
        $summary["CoworkVMService"] = @{ Status = "WARN"; Detail = "$($coworkService.Status)" }
    }
} catch {
    Write-Info "CoworkVMService no encontrado. Esto es normal si Cowork aun no ha sido configurado."
    $summary["CoworkVMService"] = @{ Status = "WARN"; Detail = "No encontrado" }
}

# =============================================================================
# 9. LOG DEL SERVICIO COWORK
# =============================================================================
Write-SectionHeader "9" "Log del Servicio Cowork"

$coworkLogPath = "C:\ProgramData\Claude\Logs\cowork-service.log"

if (Test-Path $coworkLogPath) {
    Write-Info "Archivo de log encontrado: $coworkLogPath"

    try {
        $logLines = Get-Content -Path $coworkLogPath -Tail 5 -ErrorAction Stop
        Write-Info "Ultimas 5 lineas:"
        foreach ($line in $logLines) {
            Write-Host "        $line" -ForegroundColor DarkGray
        }

        $fullLog = Get-Content -Path $coworkLogPath -Raw -ErrorAction SilentlyContinue

        # Verificar patrones de error conocidos
        if ($fullLog -match "signature verification initialization failed") {
            Write-Err "Se encontro 'signature verification initialization failed' en los logs!"
            Write-Err "Esto es frecuentemente causado por: Windows desactualizado, Windows sin activar,"
            Write-Err "o almacenamiento de apps redirigido a una unidad diferente de C:."
            $summary["Log del Servicio"] = @{ Status = "ERR"; Detail = "Fallo de verificacion de firma" }
            if ($actions -notcontains "Actualizar Windows*") {
                $actions += "Verificar activacion de Windows, actualizaciones de Windows y ubicacion de almacenamiento de apps (ver puntos anteriores)."
            }
        } elseif ($fullLog -match "EXDEV") {
            Write-Err "Se encontro 'EXDEV: cross-device link not permitted' en los logs!"
            Write-Err "Esto es causado por el almacenamiento de apps estando en una unidad diferente a C:\"
            $summary["Log del Servicio"] = @{ Status = "ERR"; Detail = "Error EXDEV enlace entre dispositivos" }
        } elseif ($fullLog -match "VM started successfully") {
            Write-OK "El log muestra 'VM started successfully' - Cowork parece funcional!"
            $summary["Log del Servicio"] = @{ Status = "OK"; Detail = "VM inicio correctamente" }
        } else {
            Write-Info "No se detectaron patrones de error conocidos en el log."
            $summary["Log del Servicio"] = @{ Status = "OK"; Detail = "Sin errores conocidos" }
        }
    } catch {
        Write-Warn "No se pudo leer el archivo de log: $($_.Exception.Message)"
        $summary["Log del Servicio"] = @{ Status = "WARN"; Detail = "No se pudo leer" }
    }
} else {
    Write-Info "Archivo de log no encontrado en $coworkLogPath (Cowork puede no haberse ejecutado aun)."
    $summary["Log del Servicio"] = @{ Status = "WARN"; Detail = "Sin archivo de log" }
}

# =============================================================================
# 10. VERIFICACION DE ARCHIVOS RESIDUALES
# =============================================================================
Write-SectionHeader "10" "Verificacion de Archivos Residuales"

$residualPaths = @(
    @{ Path = "$env:APPDATA\Claude";                     Label = "AppData\Roaming\Claude" },
    @{ Path = "$env:LOCALAPPDATA\Claude";                Label = "AppData\Local\Claude" },
    @{ Path = "C:\ProgramData\Claude";                   Label = "ProgramData\Claude" }
)

$residualsFound = @()

foreach ($entry in $residualPaths) {
    if (Test-Path $entry.Path) {
        $itemCount = (Get-ChildItem -Path $entry.Path -Recurse -Force -ErrorAction SilentlyContinue | Measure-Object).Count
        Write-Info "Encontrado: $($entry.Label) ($itemCount elementos)"
        $residualsFound += $entry.Label
    } else {
        Write-Info "No encontrado: $($entry.Label)"
    }
}

# Verificar residuales de Claude en D:\WpSystem
$dDriveResidual = $false
if (Test-Path "D:\WpSystem") {
    try {
        $dItems = Get-ChildItem -Path "D:\WpSystem" -Recurse -Directory -Filter "Claude_pzs8sxrjxfjjc" -ErrorAction SilentlyContinue
        if ($dItems) {
            $dDriveResidual = $true
            foreach ($d in $dItems) {
                Write-Warn "Residual encontrado en unidad D: $($d.FullName)"
                $residualsFound += "D:\WpSystem\...\Claude_pzs8sxrjxfjjc"
            }
        }
    } catch {
        # Ignorar errores de acceso
    }
}

if ($residualsFound.Count -gt 0) {
    $summary["Archivos Residuales"] = @{ Status = "WARN"; Detail = "$($residualsFound.Count) ubicaciones" }
    if ($dDriveResidual) {
        $actions += "Eliminar archivos residuales de Claude de D:\WpSystem despues de cambiar el almacenamiento de apps de vuelta a C: y reinstalar."
    }
} else {
    Write-Info "No se encontraron archivos residuales de Claude."
    $summary["Archivos Residuales"] = @{ Status = "OK"; Detail = "Limpio" }
}

# =============================================================================
# RESUMEN
# =============================================================================
Write-Host ""
Write-Host ""
Write-Host "  +=============================================+" -ForegroundColor Cyan
Write-Host "  |         RESUMEN DEL DIAGNOSTICO             |" -ForegroundColor Cyan
Write-Host "  +=============================================+" -ForegroundColor Cyan

foreach ($key in $summary.Keys) {
    $entry = $summary[$key]
    $status = $entry.Status
    $detail = $entry.Detail

    $icon = switch ($status) {
        "OK"   { "[OK]" }
        "WARN" { "[!!]" }
        "ERR"  { "[XX]" }
        default { "[??]" }
    }
    $color = switch ($status) {
        "OK"   { "Green" }
        "WARN" { "Yellow" }
        "ERR"  { "Red" }
        default { "Gray" }
    }

    $label = $key.PadRight(22)
    $detailPad = $detail

    Write-Host "  | " -ForegroundColor Cyan -NoNewline
    Write-Host "$icon " -ForegroundColor $color -NoNewline
    Write-Host "$label " -NoNewline
    Write-Host "$detailPad" -ForegroundColor $color -NoNewline
    # Rellenar para completar el ancho del cuadro
    $totalLen = 4 + 5 + 23 + $detailPad.Length
    $padNeeded = [Math]::Max(0, 46 - $totalLen)
    Write-Host (" " * $padNeeded) -NoNewline
    Write-Host "|" -ForegroundColor Cyan
}

Write-Host "  +=============================================+" -ForegroundColor Cyan

# =============================================================================
# ACCIONES RECOMENDADAS
# =============================================================================
if ($actions.Count -gt 0) {
    Write-Host ""
    Write-Host "  ACCIONES RECOMENDADAS:" -ForegroundColor Yellow
    Write-Host "  ----------------------" -ForegroundColor Yellow
    for ($i = 0; $i -lt $actions.Count; $i++) {
        Write-Host "  $($i + 1). $($actions[$i])" -ForegroundColor White
    }
} else {
    Write-Host ""
    Write-Host "  No se detectaron problemas. Todo se ve bien." -ForegroundColor Green
}

Write-Host ""
Write-Host "  Para la guia completa de solucion, visita:" -ForegroundColor Cyan
Write-Host "  https://github.com/LozadAPP/claude-cowork-windows-fix" -ForegroundColor White
Write-Host ""
