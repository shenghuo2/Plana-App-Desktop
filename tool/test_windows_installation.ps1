param(
    [Parameter(Mandatory = $true)][string]$BundleDirectory,
    [Parameter(Mandatory = $true)][string]$InstallerPath
)

$ErrorActionPreference = 'Stop'
$bundle = (Resolve-Path -LiteralPath $BundleDirectory).Path
$installer = (Resolve-Path -LiteralPath $InstallerPath).Path
$manifest = Get-Content (Join-Path $bundle 'package-manifest.json') -Raw -Encoding UTF8 | ConvertFrom-Json
$testRoot = Join-Path ([IO.Path]::GetTempPath()) ('plana-install-test-' + [guid]::NewGuid().ToString('N'))
$installRoot = Join-Path $testRoot 'Plana App Desktop'
New-Item -ItemType Directory -Path $testRoot | Out-Null

function Invoke-Setup([string]$Executable, [string[]]$Arguments) {
    $process = Start-Process -FilePath $Executable -ArgumentList $Arguments -Wait -PassThru
    try {
        if ($process.ExitCode -ne 0) { throw "Installer process failed with exit code $($process.ExitCode)" }
    } finally { $process.Dispose() }
}

function Assert-InstalledFiles {
    foreach ($entry in $manifest.Files) {
        $path = Join-Path $installRoot $entry.Path
        if (!(Test-Path -LiteralPath $path -PathType Leaf) -or
            (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash -ne $entry.SHA256) {
            throw "Installed file differs from verified bundle: $($entry.Path)"
        }
    }
    $exe = Get-Item -LiteralPath (Join-Path $installRoot 'plana_app_for_windows.exe')
    if ($exe.VersionInfo.FileVersion -ne $manifest.Version) { throw 'Installed application version does not match' }
}

try {
    # Validation mode disables shortcuts, auto-launch and shared uninstall keys.
    # All installed files stay inside this newly created temporary directory.
    $arguments = @('/VERYSILENT', '/SUPPRESSMSGBOXES', '/NORESTART', '/VALIDATION=1',
        ('/DIR="' + $installRoot + '"'))
    Invoke-Setup $installer ($arguments + ('/LOG="' + (Join-Path $testRoot 'install.log') + '"'))
    Assert-InstalledFiles

    $artwork = Join-Path $installRoot 'output/preserved.txt'
    New-Item -ItemType Directory -Path (Split-Path $artwork -Parent) | Out-Null
    [IO.File]::WriteAllText($artwork, 'Existing artwork must survive upgrades and uninstall.')
    $artworkHash = (Get-FileHash -LiteralPath $artwork -Algorithm SHA256).Hash
    Invoke-Setup $installer ($arguments + ('/LOG="' + (Join-Path $testRoot 'upgrade.log') + '"'))
    Assert-InstalledFiles
    if ((Get-FileHash -LiteralPath $artwork -Algorithm SHA256).Hash -ne $artworkHash) {
        throw 'Upgrade modified existing artwork'
    }

    Invoke-Setup (Join-Path $installRoot 'unins000.exe') @('/VERYSILENT', '/SUPPRESSMSGBOXES', '/NORESTART',
        ('/LOG="' + (Join-Path $testRoot 'uninstall.log') + '"'))
    if (Test-Path -LiteralPath (Join-Path $installRoot 'plana_app_for_windows.exe')) {
        throw 'Uninstall left the application executable behind'
    }
    if ((Get-FileHash -LiteralPath $artwork -Algorithm SHA256).Hash -ne $artworkHash) {
        throw 'Uninstall modified existing artwork'
    }
    Write-Output "PASS: installed $($manifest.Files.Count) verified files; reinstall and uninstall preserved artwork."
} catch {
    Get-ChildItem -LiteralPath $testRoot -Filter '*.log' -File | ForEach-Object {
        Write-Output $_.Name
        Get-Content -LiteralPath $_.FullName -Tail 60
    }
    throw
} finally {
    $resolved = (Resolve-Path -LiteralPath $testRoot).Path
    if ((Split-Path $resolved -Leaf) -notlike 'plana-install-test-*' -or
        ((Get-Item -LiteralPath $resolved).Attributes -band [IO.FileAttributes]::ReparsePoint) -or
        @(Get-ChildItem -LiteralPath $resolved -Recurse -Force -Attributes ReparsePoint).Count) {
        throw 'Refusing to remove an unexpected installation test directory'
    }
    Remove-Item -LiteralPath $resolved -Recurse -Force
}
