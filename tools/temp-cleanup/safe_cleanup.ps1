$tempRoot = [System.IO.Path]::GetFullPath($env:TEMP).TrimEnd([char]'\')
$expectedTemp = [System.IO.Path]::GetFullPath((Join-Path $env:LOCALAPPDATA 'Temp')).TrimEnd([char]'\')
$explorerRoot = [System.IO.Path]::GetFullPath((Join-Path $env:LOCALAPPDATA 'Microsoft\Windows\Explorer')).TrimEnd([char]'\')

if ($tempRoot -ne $expectedTemp) {
    throw "Unexpected temp path: $tempRoot"
}
if (-not $explorerRoot.StartsWith([System.IO.Path]::GetFullPath($env:LOCALAPPDATA), [System.StringComparison]::OrdinalIgnoreCase)) {
    throw "Unexpected Explorer cache path: $explorerRoot"
}

$cutoff = (Get-Date).AddDays(-7)
$removedBytes = 0L
$removedFiles = 0

Get-ChildItem -LiteralPath $tempRoot -Force -Recurse -File -ErrorAction SilentlyContinue |
    Where-Object { $_.LastWriteTime -lt $cutoff } |
    ForEach-Object {
        $length = $_.Length
        Remove-Item -LiteralPath $_.FullName -Force -ErrorAction SilentlyContinue
        if (-not (Test-Path -LiteralPath $_.FullName)) {
            $removedBytes += $length
            $removedFiles++
        }
    }

Get-ChildItem -LiteralPath $tempRoot -Force -Recurse -Directory -ErrorAction SilentlyContinue |
    Sort-Object FullName -Descending |
    Where-Object { $_.LastWriteTime -lt $cutoff } |
    Remove-Item -Force -ErrorAction SilentlyContinue

$thumbRemoved = 0L
Get-ChildItem -LiteralPath $explorerRoot -Force -File -ErrorAction SilentlyContinue |
    Where-Object { $_.Name -like 'thumbcache*.db' -or $_.Name -like 'iconcache*.db' } |
    ForEach-Object {
        $length = $_.Length
        Remove-Item -LiteralPath $_.FullName -Force -ErrorAction SilentlyContinue
        if (-not (Test-Path -LiteralPath $_.FullName)) {
            $thumbRemoved += $length
        }
    }

[pscustomobject]@{
    TempFilesRemoved = $removedFiles
    TempFreedMB = [math]::Round($removedBytes / 1MB, 1)
    ThumbnailFreedMB = [math]::Round($thumbRemoved / 1MB, 1)
    TotalFreedMB = [math]::Round(($removedBytes + $thumbRemoved) / 1MB, 1)
} | Format-List
