param([string]$MpvPath = 'mpv.exe')

$ErrorActionPreference = 'Stop'
$repo = Split-Path -Parent $PSScriptRoot
$mpvCommand = Get-Command $MpvPath -ErrorAction Stop
$mpv = $mpvCommand.Source
$runRoot = Join-Path ([IO.Path]::GetTempPath()) ('mpv-tsdb-tests-' + [guid]::NewGuid().ToString('N'))
[IO.Directory]::CreateDirectory($runRoot) | Out-Null
$oldSource = $env:TSDB_TEST_SOURCE
$oldRoot = $env:TSDB_TEST_ROOT
$oldDefaults = $env:TSDB_TEST_DEFAULTS
$tests = @('test_tsdb','test_native_api','test_features6','test_five_pages','test_buttons_real','test_formats_real')
Push-Location $repo
try {
    $env:TSDB_TEST_SOURCE = Join-Path $repo 'tsdb.lua'
    $env:TSDB_TEST_DEFAULTS = '1'
    foreach ($test in $tests) {
        $env:TSDB_TEST_ROOT = Join-Path $runRoot $test
        [IO.Directory]::CreateDirectory($env:TSDB_TEST_ROOT) | Out-Null
        $log = Join-Path $runRoot ($test + '.log')
        # mpv puede escribir avisos inocuos del decodificador en stderr.
        $ErrorActionPreference = 'Continue'
        & $mpv --no-config --load-scripts=no --idle=yes --force-window=no --vo=null --ao=null "--script=tests/$test.lua" "--msg-level=all=error,$test=info" 2>&1 | Out-File -LiteralPath $log -Encoding utf8
        $code = $LASTEXITCODE
        $ErrorActionPreference = 'Stop'
        $text = [IO.File]::ReadAllText($log)
        if ($code -ne 0 -or $text -match 'Lua error|stack traceback:' -or $text -notmatch '\bPASS\b') {
            throw "Fallo en $test. Consulta $log"
        }
        Write-Host "PASS $test"
    }
    Write-Host "Pruebas completadas. Registros y archivos aislados: $runRoot"
} finally {
    $env:TSDB_TEST_SOURCE = $oldSource
    $env:TSDB_TEST_ROOT = $oldRoot
    $env:TSDB_TEST_DEFAULTS = $oldDefaults
    Pop-Location
}
