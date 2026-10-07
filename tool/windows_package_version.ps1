# Flutter uses SemVer plus a numeric build number. Windows resource versions
# contain four unsigned 16-bit numbers; the prerelease remains in the app label.
function Get-PlanaWindowsPackageVersion([string]$Version) {
    $identifier = '(?:0|[1-9][0-9]*|[0-9]*[A-Za-z-][0-9A-Za-z-]*)'
    $pattern = '\A(?<major>0|[1-9][0-9]*)\.(?<minor>0|[1-9][0-9]*)\.(?<patch>0|[1-9][0-9]*)(?:-' + $identifier + '(?:\.' + $identifier + ')*)?\+(?<build>[0-9]+)\z'
    $match = [regex]::Match($Version, $pattern)
    if (!$match.Success) { throw "Invalid Windows package version: $Version" }
    $numbers = foreach ($name in @('major', 'minor', 'patch', 'build')) {
        $number = [uint32]0
        if (![uint32]::TryParse($match.Groups[$name].Value, [ref]$number) -or $number -gt 65535) {
            throw "Invalid Windows package version: $Version (components must fit in 16 bits)."
        }
        $number
    }
    [pscustomobject]@{
        Version = $Version
        FileVersion = $numbers -join '.'
        PackageName = 'Plana-Windows-' + $Version.Split('+')[0] + '-x64'
    }
}
