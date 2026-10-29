$ErrorActionPreference = 'Stop'
$projectRoot = Split-Path -Parent $PSScriptRoot
$engineDirectory = Join-Path $PSScriptRoot 'godot'
$enginePath = Join-Path $engineDirectory 'Godot_v4.7.2-stable_win64.exe'
if (-not (Test-Path -LiteralPath $enginePath)) {
    $archivePath = Join-Path $PSScriptRoot 'godot.zip'
    Write-Host 'Downloading official portable Godot 4.7.2...'
    Invoke-WebRequest -Uri 'https://github.com/godotengine/godot-builds/releases/download/4.7.2-stable/Godot_v4.7.2-stable_win64.exe.zip' -OutFile $archivePath
    $archiveHash = (Get-FileHash -LiteralPath $archivePath -Algorithm SHA256).Hash
    if ($archiveHash -ne '731980F9608D61333E5BAF54A2EF17210ACC7A538446C0CB9969F002ACA1E953') {
        throw 'Godot archive checksum mismatch. Download was not extracted.'
    }
    Expand-Archive -LiteralPath $archivePath -DestinationPath $engineDirectory -Force
}
if (-not (Test-Path -LiteralPath (Join-Path $engineDirectory '_sc_'))) {
    New-Item -ItemType File -Path (Join-Path $engineDirectory '_sc_') | Out-Null
}
$classCache = Join-Path $projectRoot '.godot\global_script_class_cache.cfg'
if (-not (Test-Path -LiteralPath $classCache)) {
    $artifactDirectory = Join-Path $projectRoot 'artifacts'
    New-Item -ItemType Directory -Path $artifactDirectory -Force | Out-Null
    $importLog = Join-Path $artifactDirectory 'first-import.log'
    $consolePath = $enginePath.Replace('.exe', '_console.exe')
    & $consolePath --headless --editor --path $projectRoot --log-file (Join-Path $artifactDirectory 'first-import-godot.log') --import *> $importLog
    if ($LASTEXITCODE -ne 0 -or -not (Test-Path -LiteralPath $classCache)) {
        throw "Godot could not initialize the project. See $importLog"
    }
}
return $enginePath
