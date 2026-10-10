param(
    [version]$MinimumVersion = '1.29.380'
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

$release = 'https://github.com/microsoft/winget-cli/releases/download/v1.29.380'
$downloads = @(
    @{ Name = 'Microsoft.DesktopAppInstaller_8wekyb3d8bbwe.msixbundle'; Sha256 = '65dea9c01ce08ee7b763366b27c0e651f97db857c11ca9b9c301826c10092f2e' },
    @{ Name = 'DesktopAppInstaller_Dependencies.zip'; Sha256 = 'ba875afe9d190f61218985ac0292a99d1db710bf93e13c68944ca9d89f0d82d1' },
    @{ Name = 'e53e159d00e04f729cc2180cffd1c02e_License1.xml'; Sha256 = 'bcb15118ec47df24e3e6013a7006147c3a15b3a8104ed660fe87c8b4ed01f485' }
)

function Get-WinGetVersion {
    if ($null -eq (Get-Command winget.exe -ErrorAction SilentlyContinue)) {
        return $null
    }
    $output = & winget.exe --version
    if ($LASTEXITCODE -ne 0 -or $output -notmatch '^v?(\d+\.\d+\.\d+)') {
        return $null
    }
    return [version]$Matches[1]
}

$windowsApps = Join-Path $env:LOCALAPPDATA 'Microsoft\WindowsApps'
if (($env:Path -split ';') -notcontains $windowsApps) {
    $env:Path = "$env:Path;$windowsApps"
}

$installed = Get-WinGetVersion
if ($null -ne $installed -and $installed -ge $MinimumVersion) {
    Write-Output "WinGet $installed is already installed."
} else {
    Write-Output "Installing WinGet $MinimumVersion (found: $installed)..."
    $arch = switch ((Get-ItemProperty -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Environment' -Name PROCESSOR_ARCHITECTURE).PROCESSOR_ARCHITECTURE) {
        'AMD64' { 'x64' }
        'ARM64' { 'arm64' }
        default { throw 'WinGet tests require an x64 or ARM64 version of Windows.' }
    }

    $workDir = Join-Path ([IO.Path]::GetTempPath()) 'winget-bootstrap'
    New-Item -ItemType Directory -Path $workDir -Force | Out-Null
    foreach ($download in $downloads) {
        $path = Join-Path $workDir $download.Name
        & curl.exe --fail --show-error --silent --location --retry 3 --output $path "$release/$($download.Name)"
        if ($LASTEXITCODE -ne 0) { throw "Could not download $($download.Name)." }
        $hash = (Get-FileHash -Algorithm SHA256 -LiteralPath $path).Hash.ToLowerInvariant()
        if ($hash -ne $download.Sha256) {
            throw "$($download.Name) SHA-256 mismatch: $hash"
        }
    }

    $dependencyDir = Join-Path $workDir 'dependencies'
    Expand-Archive -LiteralPath (Join-Path $workDir 'DesktopAppInstaller_Dependencies.zip') -DestinationPath $dependencyDir -Force
    $dependencies = @(Get-ChildItem -LiteralPath (Join-Path $dependencyDir $arch) -Filter '*.appx' | ForEach-Object { $_.FullName })
    if ($dependencies.Count -eq 0) {
        throw "No WinGet dependencies found for $arch."
    }

    $bundle = Join-Path $workDir 'Microsoft.DesktopAppInstaller_8wekyb3d8bbwe.msixbundle'
    Add-AppxProvisionedPackage -Online -PackagePath $bundle -DependencyPackagePath $dependencies -LicensePath (Join-Path $workDir 'e53e159d00e04f729cc2180cffd1c02e_License1.xml') | Out-Null
    Add-AppxPackage -Path $bundle -DependencyPath $dependencies -ForceApplicationShutdown

    $installed = $null
    for ($attempt = 0; $attempt -lt 60; $attempt++) {
        $installed = Get-WinGetVersion
        if ($null -ne $installed -and $installed -ge $MinimumVersion) { break }
        Start-Sleep -Seconds 1
    }
    if ($null -eq $installed -or $installed -lt $MinimumVersion) {
        throw "WinGet $MinimumVersion is not available after installation (found: $installed)."
    }
    Write-Output "Installed WinGet $installed."
}

& winget.exe settings --enable LocalManifestFiles
if ($LASTEXITCODE -ne 0) { throw 'Could not enable local manifest installation.' }

if ($env:GITHUB_PATH) {
    Add-Content -LiteralPath $env:GITHUB_PATH -Value $windowsApps
}
