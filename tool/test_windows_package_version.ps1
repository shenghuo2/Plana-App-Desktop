$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'windows_package_version.ps1')
$accepted = @{
    '1.1.2-desktop+65' = '1.1.2.65'
    '1.1.1-desktop.45+64' = '1.1.1.64'
    '1.1.1-windows.45+64' = '1.1.1.64'
    '1.2.3+4' = '1.2.3.4'
    '1.2.3-beta.1-x+999' = '1.2.3.999'
    '1.2.3+0004' = '1.2.3.4'
    '65535.65535.65535+65535' = '65535.65535.65535.65535'
}
foreach ($version in $accepted.Keys) {
    $parsed = Get-PlanaWindowsPackageVersion $version
    if ($parsed.Version -ne $version -or $parsed.FileVersion -ne $accepted[$version] -or
        $parsed.PackageName -ne ('Plana-Windows-' + $version.Split('+')[0] + '-x64')) {
        throw "Incorrect Windows version mapping: $version"
    }
}
$rejected = @('', '1.2', '1.2.3-desktop', 'v1.2.3+4', '1.2.3-+4', '01.2.3+4',
    '1.2.3-01+4', '1.2.3-beta..1+4', '1.2.3-beta!+4', '1.2.3+abc',
    "1.2.3+4`n", '1.2.3+٤', '65536.2.3+4', '1.2.3+65536', '1.2.3+99999999999999999999')
foreach ($version in $rejected) {
    $failed = $false
    try { Get-PlanaWindowsPackageVersion $version | Out-Null }
    catch {
        if ($_.Exception.Message -notlike 'Invalid Windows package version:*') { throw }
        $failed = $true
    }
    if (!$failed) { throw "Invalid Windows version was accepted: $version" }
}
$pubspecPath = Join-Path $PSScriptRoot '../pubspec.yaml'
$current = [regex]::Match((Get-Content -LiteralPath $pubspecPath -Raw), '(?m)^version:\s*(\S+)').Groups[1].Value
$actual = Get-PlanaWindowsPackageVersion $current
[pscustomobject]@{Status='passed';Accepted=$accepted.Count;Rejected=$rejected.Count;CurrentVersion=$actual.Version;FileVersion=$actual.FileVersion}
