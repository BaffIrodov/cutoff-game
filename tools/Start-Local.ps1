param([int]$Port = 9080, [switch]$ClientOnly, [string]$Name = 'Игрок')
$ErrorActionPreference = 'Stop'
$projectRoot = Split-Path -Parent $PSScriptRoot
$enginePath = & (Join-Path $PSScriptRoot 'Ensure-Godot.ps1')
$artifactDirectory = Join-Path $projectRoot 'artifacts'
New-Item -ItemType Directory -Path $artifactDirectory -Force | Out-Null
$pidFile = Join-Path $artifactDirectory 'local-server.json'
$ownedServer = $null
if (Test-Path -LiteralPath $pidFile) {
    $record = Get-Content -LiteralPath $pidFile -Raw | ConvertFrom-Json
    $running = Get-Process -Id $record.pid -ErrorAction SilentlyContinue
    if ($running -and $running.Path -eq $enginePath -and $record.port -eq $Port) { $ownedServer = $running }
}
if (-not $ClientOnly -and -not $ownedServer) {
    $serverLog = (Join-Path $artifactDirectory 'local-server.log').Replace('\', '/')
    $arguments = @('--headless', '--path', ('"' + $projectRoot + '"'), '--log-file', ('"' + $serverLog + '"'), '--', '--server', "--port=$Port", '--allow-practice', '--allow-map-upload', '--idle-exit=60')
    $ownedServer = Start-Process -FilePath $enginePath -ArgumentList $arguments -WorkingDirectory $projectRoot -WindowStyle Hidden -PassThru
    @{pid = $ownedServer.Id; port = $Port; engine = $enginePath; project = $projectRoot} | ConvertTo-Json | Set-Content -LiteralPath $pidFile -Encoding UTF8
    Start-Sleep -Milliseconds 900
    if ($ownedServer.HasExited) { throw "Local server did not start. See $serverLog" }
}
$clientLog = (Join-Path $artifactDirectory ('client-' + [Guid]::NewGuid().ToString('N') + '.log')).Replace('\', '/')
$arguments = @('--path', ('"' + $projectRoot + '"'), '--log-file', ('"' + $clientLog + '"'), '--', '--connect=127.0.0.1', "--port=$Port", '--autoconnect', ('"--name=' + $Name + '"'))
$clientProcess = Start-Process -FilePath $enginePath -ArgumentList $arguments -WorkingDirectory $projectRoot -PassThru
$clientProcess.WaitForExit()
if ($clientProcess.ExitCode -ne 0) { Write-Host "Game exited with code $($clientProcess.ExitCode). Log: $clientLog" }
