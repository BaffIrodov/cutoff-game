$ErrorActionPreference = 'Stop'
$projectRoot = Split-Path -Parent $PSScriptRoot
$enginePath = & (Join-Path $PSScriptRoot 'Ensure-Godot.ps1')
$consolePath = $enginePath.Replace('.exe', '_console.exe')
Push-Location $projectRoot
try {
    & $consolePath --headless --path $projectRoot --log-file (Join-Path $projectRoot 'artifacts\world-test.log') --script tests/world_test.gd
    if ($LASTEXITCODE -ne 0) { throw 'World tests failed.' }
    & $consolePath --headless --path $projectRoot --log-file (Join-Path $projectRoot 'artifacts\editor-test.log') --script tests/editor_test.gd
    if ($LASTEXITCODE -ne 0) { throw 'Editor tests failed.' }
    & $consolePath --headless --path $projectRoot --log-file (Join-Path $projectRoot 'artifacts\revision-test.log') --script tests/revision_test.gd
    if ($LASTEXITCODE -ne 0) { throw 'Revision tests failed.' }
    python tests/editor_http_test.py
    if ($LASTEXITCODE -ne 0) { throw 'Editor HTTP tests failed.' }
    python tests/network_test.py --custom-map
    if ($LASTEXITCODE -ne 0) { throw 'Network tests failed.' }
} finally { Pop-Location }
