$ErrorActionPreference = 'Stop'
$projectRoot = Split-Path -Parent $PSScriptRoot
$enginePath = & (Join-Path $PSScriptRoot 'Ensure-Godot.ps1')
& $enginePath --editor --path $projectRoot --log-file (Join-Path $projectRoot 'artifacts\editor.log')
