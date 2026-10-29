$ErrorActionPreference = 'Stop'
$projectRoot = Split-Path -Parent $PSScriptRoot
$pidFile = Join-Path $projectRoot 'artifacts\local-server.json'
if (-not (Test-Path -LiteralPath $pidFile)) { return }
$record = Get-Content -LiteralPath $pidFile -Raw | ConvertFrom-Json
$process = Get-Process -Id $record.pid -ErrorAction SilentlyContinue
if (-not $process) { return }
$details = Get-CimInstance Win32_Process -Filter "ProcessId=$($record.pid)"
if ($process.Path -eq $record.engine -and $record.project -eq $projectRoot -and $details.CommandLine.Contains($projectRoot) -and $details.CommandLine.Contains('--server')) {
    Stop-Process -Id $record.pid
}
