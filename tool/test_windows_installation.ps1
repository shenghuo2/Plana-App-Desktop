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

function Test-InstalledDiagnostics {
    $directory = Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) 'Plana App Desktop/diagnostics'
    $process = Start-Process -FilePath (Join-Path $installRoot 'plana_app_for_windows.exe') -PassThru
    try {
        $deadline = [DateTime]::UtcNow.AddSeconds(45)
        do {
            if ($process.HasExited) { throw "Installed app exited during diagnostics smoke test: $($process.ExitCode)" }
            $native = @(Get-ChildItem -Path (Join-Path $directory "native-*-$($process.Id).log") -ErrorAction SilentlyContinue)
            $dart = @(Get-ChildItem -Path (Join-Path $directory "dart-*-$($process.Id)-*.log") -ErrorAction SilentlyContinue)
            if ($native.Count -eq 1 -and $dart.Count -eq 1 -and
                (Get-Content $native[0].FullName -Raw) -match 'first-frame' -and
                (Get-Content $dart[0].FullName -Raw) -match 'app-started') { break }
            Start-Sleep -Milliseconds 250
        } while ([DateTime]::UtcNow -lt $deadline)
        if (!$native.Count -or !$dart.Count -or
            (Get-Content $native[0].FullName -Raw) -notmatch 'first-frame' -or
            (Get-Content $dart[0].FullName -Raw) -notmatch 'app-started') {
            throw 'Installed app did not persist native and Dart startup diagnostics'
        }
        # Simulate abrupt termination: diagnostics must already be on disk.
        Stop-Process -Id $process.Id -Force
        $process.WaitForExit()
        foreach ($file in @($native[0].FullName, $dart[0].FullName)) {
            if (!(Test-Path -LiteralPath $file) -or (Get-Item $file).Length -eq 0) {
                throw 'Diagnostic log did not survive process termination'
            }
        }
        Write-Host 'PASS: installed app persisted native and Dart startup logs through abrupt termination.'
        return @($native[0].FullName, $dart[0].FullName)
    } finally {
        if (!$process.HasExited) { Stop-Process -Id $process.Id -Force }
        $process.Dispose()
    }
}

try {
    # Validation mode disables shortcuts, auto-launch and shared uninstall keys.
    # All installed files stay inside this newly created temporary directory.
    $arguments = @('/VERYSILENT', '/SUPPRESSMSGBOXES', '/NORESTART', '/VALIDATION=1',
        ('/DIR="' + $installRoot + '"'))
    Invoke-Setup $installer ($arguments + ('/LOG="' + (Join-Path $testRoot 'install.log') + '"'))
    Assert-InstalledFiles
    $diagnosticFiles = @(Test-InstalledDiagnostics)
    if ($diagnosticFiles.Count -ne 2) { throw 'Expected native and Dart diagnostic files' }

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
    foreach ($file in $diagnosticFiles) {
        if (!(Test-Path -LiteralPath $file)) { throw 'Uninstall removed diagnostic evidence' }
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
