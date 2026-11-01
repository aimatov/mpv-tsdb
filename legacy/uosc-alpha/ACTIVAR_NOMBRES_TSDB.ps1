# mpv-TSDB v0.1.0-alpha.1
# Modificacion minima de uosc/lib/menus.lua: conservar nombres de pistas [TSDB].
# Ejecutar desde la carpeta de mpv o pasar -MpvRoot "ruta".
# -Restore revierte solo si menus.lua no se ha vuelto a modificar.
param(
    [string]$MpvRoot = '',
    [switch]$Restore
)

$ErrorActionPreference = 'Stop'

if ([string]::IsNullOrWhiteSpace($MpvRoot)) {
    $MpvRoot = (Get-Location).Path
}
$target = Join-Path $MpvRoot 'portable_config\scripts\uosc\lib\menus.lua'
$backupDir = Join-Path $MpvRoot 'portable_config\tsdb-backups'
$backup = Join-Path $backupDir 'menus.lua.before-tsdb.bak'
$hashFile = Join-Path $backupDir 'menus.lua.after-tsdb.sha256'

if (-not (Test-Path -LiteralPath $target -PathType Leaf)) {
    throw "No se encuentra uosc/lib/menus.lua en: $target. No se ha modificado nada."
}

if ($Restore) {
    if (-not (Test-Path -LiteralPath $backup -PathType Leaf) -or
        -not (Test-Path -LiteralPath $hashFile -PathType Leaf)) {
        throw 'No existe un respaldo creado por este parche. No se ha modificado nada.'
    }

    $expected = [System.IO.File]::ReadAllText($hashFile).Trim()
    $current = (Get-FileHash -LiteralPath $target -Algorithm SHA256).Hash
    if ($current -ne $expected) {
        throw 'menus.lua ha cambiado desde el parche. Restauracion cancelada para no borrar otros cambios.'
    }

    Copy-Item -LiteralPath $backup -Destination $target -Force -ErrorAction Stop
    Remove-Item -LiteralPath $hashFile -ErrorAction Stop
    Write-Host 'menus.lua original restaurado. Reinicia mpv.' -ForegroundColor Green
    exit 0
}

$bytes = [System.IO.File]::ReadAllBytes($target)
$hasBom = $bytes.Length -ge 3 -and $bytes[0] -eq 239 -and $bytes[1] -eq 187 -and $bytes[2] -eq 191
$encoding = New-Object System.Text.UTF8Encoding($hasBom)
$content = [System.IO.File]::ReadAllText($target, [System.Text.Encoding]::UTF8)

if ($content.Contains("track.title:find('[TSDB]', 1, true)")) {
    Write-Host 'El menu ya contiene una excepcion para [TSDB]. No se ha modificado nada.' -ForegroundColor Yellow
    exit 0
}

$originalExtension = "local extension = track.title:match('%.([^%.]+)$')"
$originalCondition = 'if track.title and escaped_filename and extension then'
$updatedExtension = "local extension = track.title and track.title:match('%.([^%.]+)$')"
$updatedCondition = "if track.title and escaped_filename and extension and not track.title:find('[TSDB]', 1, true) then"

if (-not $content.Contains($originalExtension) -or
    -not $content.Contains($originalCondition) -or
    $content.IndexOf($originalExtension) -ne $content.LastIndexOf($originalExtension) -or
    $content.IndexOf($originalCondition) -ne $content.LastIndexOf($originalCondition)) {
    throw 'La rutina de pistas no coincide con uosc 5.13.0. No se ha modificado nada.'
}
$after = $content.Substring($content.IndexOf($originalExtension) + $originalExtension.Length)
$nextLine = $after.TrimStart([char[]]@([char]13, [char]10, [char]9, [char]32))
if (-not $nextLine.StartsWith($originalCondition, [StringComparison]::Ordinal)) {
    throw 'La estructura de menus.lua es distinta. No se ha modificado nada.'
}
if (Test-Path -LiteralPath $backup) {
    throw "Ya existe un respaldo anterior: $backup. No se sobrescribira."
}

$patched = $content.Replace($originalExtension, $updatedExtension).Replace($originalCondition, $updatedCondition)

New-Item -ItemType Directory -Path $backupDir -Force | Out-Null
Copy-Item -LiteralPath $target -Destination $backup -ErrorAction Stop
try {
    [System.IO.File]::WriteAllText($target, $patched, $encoding)
    $newContent = [System.IO.File]::ReadAllText($target, [System.Text.Encoding]::UTF8)
    if ($newContent -ne $patched) { throw 'No se pudo verificar el archivo modificado.' }
    $hash = (Get-FileHash -LiteralPath $target -Algorithm SHA256).Hash
    [System.IO.File]::WriteAllText($hashFile, $hash, [System.Text.Encoding]::ASCII)
} catch {
    Copy-Item -LiteralPath $backup -Destination $target -Force -ErrorAction Stop
    throw "Fallo el parche y se restauro menus.lua: $($_.Exception.Message)"
}

Write-Host 'Excepcion [TSDB] aplicada sin sustituir menus.lua completo.' -ForegroundColor Green
Write-Host "Respaldo: $backup"
Write-Host 'Reinicia mpv y comprueba los nombres completos de las pistas.'
