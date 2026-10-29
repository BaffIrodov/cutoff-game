$ErrorActionPreference = 'Stop'
$projectRoot = Split-Path -Parent $PSScriptRoot
$enginePath = & (Join-Path $PSScriptRoot 'Ensure-Godot.ps1')
Start-Process -FilePath $enginePath -ArgumentList @('--path', ('"' + $projectRoot + '"'), '--', '--editor-map') -WorkingDirectory $projectRoot
