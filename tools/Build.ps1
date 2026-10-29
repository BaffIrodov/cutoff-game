param([switch]$WithLinuxRuntime)
$ErrorActionPreference = 'Stop'
$projectRoot = Split-Path -Parent $PSScriptRoot
$enginePath = & (Join-Path $PSScriptRoot 'Ensure-Godot.ps1')
$consolePath = $enginePath.Replace('.exe', '_console.exe')
$windowsDirectory = Join-Path $projectRoot 'build\windows'
$linuxDirectory = Join-Path $projectRoot 'build\linux-server'
New-Item -ItemType Directory -Path $windowsDirectory, $linuxDirectory -Force | Out-Null
& $consolePath --headless --editor --path $projectRoot --log-file (Join-Path $projectRoot 'artifacts\import.log') --import
if ($LASTEXITCODE -ne 0) { throw 'Project import failed.' }
& $consolePath --headless --path $projectRoot --log-file (Join-Path $projectRoot 'artifacts\export-windows.log') --export-pack Windows (Join-Path $windowsDirectory 'cutoff.pck')
if ($LASTEXITCODE -ne 0) { throw 'Windows PCK export failed.' }
& $consolePath --headless --path $projectRoot --log-file (Join-Path $projectRoot 'artifacts\export-linux.log') --export-pack 'Linux Server' (Join-Path $linuxDirectory 'cutoff.pck')
if ($LASTEXITCODE -ne 0) { throw 'Linux PCK export failed.' }
# Portable official engine + project pack: no editor installation or export templates required.
Copy-Item -LiteralPath $enginePath -Destination (Join-Path $windowsDirectory 'Cutoff.exe') -Force
Copy-Item -LiteralPath (Join-Path $projectRoot 'deploy\start-server.sh') -Destination (Join-Path $linuxDirectory 'start-server.sh') -Force
Copy-Item -LiteralPath (Join-Path $projectRoot 'deploy\cutoff-godot.service') -Destination (Join-Path $linuxDirectory 'cutoff-godot.service') -Force
if ($WithLinuxRuntime) {
    $linuxArchive = Join-Path $PSScriptRoot 'godot-linux.zip'
    if (-not (Test-Path -LiteralPath $linuxArchive)) {
        Invoke-WebRequest -Uri 'https://github.com/godotengine/godot-builds/releases/download/4.7.2-stable/Godot_v4.7.2-stable_linux.x86_64.zip' -OutFile $linuxArchive
    }
    if ((Get-FileHash -LiteralPath $linuxArchive -Algorithm SHA256).Hash -ne 'CADD3204E728A35D3F13ADB7FD0D7902636B79F6B95C40C265EB73B6C35329E4') {
        throw 'Linux runtime checksum mismatch.'
    }
    $unpackedDirectory = Join-Path $PSScriptRoot 'godot-linux'
    Expand-Archive -LiteralPath $linuxArchive -DestinationPath $unpackedDirectory -Force
    Copy-Item -LiteralPath (Join-Path $unpackedDirectory 'Godot_v4.7.2-stable_linux.x86_64') -Destination (Join-Path $linuxDirectory 'godot') -Force
}
foreach ($packageDirectory in @($windowsDirectory, $linuxDirectory)) {
    Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'GODOT-LICENSE.txt') -Destination (Join-Path $packageDirectory 'GODOT-LICENSE.txt') -Force
}
Write-Host "Built packages in $windowsDirectory and $linuxDirectory"
