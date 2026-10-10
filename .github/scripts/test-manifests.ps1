param(
    [Parameter(Mandatory = $true)]
    [string]$ManifestRoot,
    [string]$BaselineRoot,
    [string]$LogDir = (Join-Path ([IO.Path]::GetTempPath()) 'winget-logs')
)

$ErrorActionPreference = 'Stop'
$registryPaths = @(
    'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*',
    'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*'
)
$expectations = @{
    'Octelium.Octelium'        = @{ Command = 'octelium'; Files = @('octelium.exe', 'wireguard.dll', 'wintun.dll') }
    'Octelium.Octeliumctl'     = @{ Command = 'octeliumctl'; Files = @('octeliumctl.exe') }
    'Octelium.Octops'          = @{ Command = 'octops'; Files = @('octops.exe') }
    'Octelium.OcteliumDesktop' = @{ Service = 'OcteliumDaemon'; Files = @('octelium-desktop.exe', 'octelium-desktop-daemon.exe', 'wireguard.dll', 'wintun.dll', 'install-daemon.ps1') }
}
$rebootRequired = @('8A150109', '8A15010A')
$validationWarning = @('8A150028')

$arch = switch ((Get-ItemProperty -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Environment' -Name PROCESSOR_ARCHITECTURE).PROCESSOR_ARCHITECTURE) {
    'AMD64' { 'x64' }
    'ARM64' { 'arm64' }
    default { throw 'WinGet tests require an x64 or ARM64 version of Windows.' }
}
New-Item -ItemType Directory -Path $LogDir -Force | Out-Null

function Invoke-WinGet {
    param(
        [string[]]$ArgumentList,
        [string[]]$WarningCodes = $rebootRequired
    )
    Write-Output "> winget $($ArgumentList -join ' ')"
    & winget.exe @ArgumentList
    $code = '{0:X8}' -f $LASTEXITCODE
    if ($code -in $WarningCodes) {
        Write-Output "::warning::winget $($ArgumentList[0]) for $($ArgumentList[2]) completed with 0x$code."
    } elseif ($LASTEXITCODE -ne 0) {
        throw "winget $($ArgumentList[0]) for $($ArgumentList[2]) failed with exit code 0x$code."
    }
}

function Get-ManifestDirectories {
    param([string]$Root)
    return @(Get-ChildItem -LiteralPath (Join-Path $Root 'manifests') -Recurse -Filter '*.installer.yaml' | ForEach-Object { $_.DirectoryName } | Sort-Object -Unique)
}

function Read-Manifest {
    param([string]$Directory)
    $installerFiles = @(Get-ChildItem -LiteralPath $Directory -Filter '*.installer.yaml')
    if ($installerFiles.Count -ne 1) { throw "Expected one installer manifest in $Directory." }
    $identifier = $installerFiles[0].Name -replace '\.installer\.yaml$', ''
    $root = @{}
    $installers = @()
    $current = $null
    foreach ($line in Get-Content -LiteralPath $installerFiles[0].FullName) {
        if ($line -match '^- Architecture: (\S+)$') {
            $current = @{ Architecture = $Matches[1] }
            $installers += $current
        } elseif ($line -match '^\s*-?\s*(PackageVersion|DefaultInstallLocation|ProductCode|UpgradeCode|DisplayName|Publisher): ''?(.+?)''?$') {
            $target = if ($null -eq $current) { $root } else { $current }
            if (-not $target.ContainsKey($Matches[1])) { $target[$Matches[1]] = $Matches[2] }
        }
    }

    $selected = @($installers | Where-Object { $_.Architecture -eq $arch })
    if ($selected.Count -ne 1) { throw "Expected one $arch installer for $identifier." }
    $installer = $root.Clone()
    foreach ($key in $selected[0].Keys) { $installer[$key] = $selected[0][$key] }

    $displayName = $installer['DisplayName']
    if (-not $displayName) {
        $locale = Get-Content -LiteralPath (Join-Path $Directory "$identifier.locale.en-US.yaml") | Where-Object { $_ -match '^PackageName: (.+)$' } | Select-Object -First 1
        $displayName = ($locale -replace '^PackageName: ', '').Trim()
    }
    if (-not $expectations.ContainsKey($identifier)) { throw "No test expectations for $identifier." }
    if ($installer['PackageVersion'] -ne (Split-Path -Leaf $Directory)) { throw "Version directory mismatch in $Directory." }

    return [pscustomobject]@{
        Identifier  = $identifier
        Version     = $installer['PackageVersion']
        Directory   = $Directory
        ProductCode = $installer['ProductCode']
        Publisher   = $installer['Publisher']
        DisplayName = $displayName
        InstallDir  = [IO.Path]::GetFullPath([Environment]::ExpandEnvironmentVariables($installer['DefaultInstallLocation']).Replace('/', '\')).TrimEnd('\')
        Expectation = $expectations[$identifier]
    }
}

function Find-Baseline {
    param($Manifest)
    if (-not $BaselineRoot) { return $null }
    $candidates = @(Get-ManifestDirectories -Root $BaselineRoot | ForEach-Object { Read-Manifest -Directory $_ } | Where-Object { $_.Identifier -eq $Manifest.Identifier -and [version]$_.Version -lt [version]$Manifest.Version })
    return $candidates | Sort-Object { [version]$_.Version } | Select-Object -Last 1
}

function Get-Registration {
    param($Manifest)
    return @(Get-ItemProperty -Path $registryPaths -ErrorAction SilentlyContinue | Where-Object { $_.DisplayName -eq $Manifest.DisplayName })
}

function Update-SessionPath {
    $env:Path = [Environment]::GetEnvironmentVariable('Path', 'Machine') + ';' + [Environment]::GetEnvironmentVariable('Path', 'User')
}

function Test-Installed {
    param($Manifest)
    $apps = @(Get-Registration -Manifest $Manifest)
    if ($apps.Count -ne 1) { throw "Expected one '$($Manifest.DisplayName)' registration, found $($apps.Count)." }
    $app = $apps[0]
    if ($app.PSChildName -ne $Manifest.ProductCode) { throw "$($Manifest.Identifier) registered ProductCode $($app.PSChildName), expected $($Manifest.ProductCode)." }
    if ($app.Publisher -ne $Manifest.Publisher) { throw "$($Manifest.Identifier) registered publisher '$($app.Publisher)', expected '$($Manifest.Publisher)'." }
    if ($app.WindowsInstaller -ne 1) { throw "$($Manifest.Identifier) is not registered as an MSI product." }
    if (([version]$app.DisplayVersion).ToString(3) -ne $Manifest.Version) { throw "$($Manifest.Identifier) registered version $($app.DisplayVersion), expected $($Manifest.Version)." }

    foreach ($filename in $Manifest.Expectation.Files) {
        if (-not (Test-Path -LiteralPath (Join-Path $Manifest.InstallDir $filename) -PathType Leaf)) {
            throw "Missing installed $($Manifest.Identifier) file: $filename"
        }
    }

    if ($Manifest.Expectation.Command) {
        Update-SessionPath
        $command = Get-Command "$($Manifest.Expectation.Command).exe" -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($null -eq $command -or (Split-Path -Parent $command.Source) -ne $Manifest.InstallDir) {
            throw "$($Manifest.Expectation.Command) does not resolve to $($Manifest.InstallDir) on PATH."
        }
        $releaseVersion = (& $command.Source version -o json | ConvertFrom-Json).releaseVersion
        if ($LASTEXITCODE -ne 0 -or $releaseVersion -ne "v$($Manifest.Version)") {
            throw "$($Manifest.Expectation.Command) reports version '$releaseVersion', expected v$($Manifest.Version)."
        }
    }

    if ($Manifest.Expectation.Service) {
        $service = $null
        for ($attempt = 0; $attempt -lt 30; $attempt++) {
            $service = Get-CimInstance Win32_Service -Filter "Name='$($Manifest.Expectation.Service)'" -ErrorAction SilentlyContinue
            if ($null -ne $service -and $service.State -eq 'Running' -and $service.StartMode -eq 'Auto') { break }
            Start-Sleep -Seconds 1
        }
        if ($null -eq $service -or $service.State -ne 'Running' -or $service.StartMode -ne 'Auto') {
            throw "The $($Manifest.Expectation.Service) service must run automatically."
        }
        if ($service.PathName -notlike "`"$($Manifest.InstallDir)\*") {
            throw "The $($Manifest.Expectation.Service) service runs $($service.PathName), outside $($Manifest.InstallDir)."
        }
    }
    Write-Output "Verified $($Manifest.Identifier) $($Manifest.Version) ($arch)."
}

function Test-Removed {
    param($Manifest)
    if (@(Get-Registration -Manifest $Manifest).Count -ne 0) { throw "$($Manifest.Identifier) is still registered after uninstall." }
    foreach ($filename in $Manifest.Expectation.Files) {
        if (Test-Path -LiteralPath (Join-Path $Manifest.InstallDir $filename)) {
            throw "$($Manifest.Identifier) file remains after uninstall: $filename"
        }
    }
    if ($Manifest.Expectation.Command) {
        $machinePath = [Environment]::GetEnvironmentVariable('Path', 'Machine') -split ';' | ForEach-Object { $_.TrimEnd('\') }
        if ($machinePath -contains $Manifest.InstallDir) { throw "$($Manifest.InstallDir) remains on the machine PATH after uninstall." }
    }
    if ($Manifest.Expectation.Service) {
        for ($attempt = 0; $attempt -lt 30; $attempt++) {
            if ($null -eq (Get-Service -Name $Manifest.Expectation.Service -ErrorAction SilentlyContinue)) { break }
            Start-Sleep -Seconds 1
        }
        if ($null -ne (Get-Service -Name $Manifest.Expectation.Service -ErrorAction SilentlyContinue)) {
            throw "The $($Manifest.Expectation.Service) service remains after uninstall."
        }
    }
    Write-Output "Verified removal of $($Manifest.Identifier) ($arch)."
}

$commonArgs = @('--silent', '--disable-interactivity', '--accept-source-agreements', '--verbose-logs')
$installArgs = $commonArgs + @('--accept-package-agreements')
$sentinelPath = Join-Path ([Environment]::GetFolderPath('CommonApplicationData')) 'Octelium Desktop/daemon-state/winget-upgrade-test.txt'
$manifests = @(Get-ManifestDirectories -Root $ManifestRoot | ForEach-Object { Read-Manifest -Directory $_ })
if ($manifests.Count -eq 0) { throw "No manifests found in $ManifestRoot." }

try {
    foreach ($manifest in $manifests) {
        Invoke-WinGet -ArgumentList @('validate', '--manifest', $manifest.Directory) -WarningCodes $validationWarning
    }

    foreach ($manifest in $manifests) {
        $baseline = Find-Baseline -Manifest $manifest
        if ($null -ne $baseline) {
            Invoke-WinGet -ArgumentList (@('install', '--manifest', $baseline.Directory, '--log', (Join-Path $LogDir "$($manifest.Identifier)-baseline.log")) + $installArgs)
            Test-Installed -Manifest $baseline
            if ($manifest.Expectation.Service) {
                Set-Content -LiteralPath $sentinelPath -Value 'preserve desktop daemon state'
            }
            Invoke-WinGet -ArgumentList (@('upgrade', '--manifest', $manifest.Directory, '--log', (Join-Path $LogDir "$($manifest.Identifier)-upgrade.log")) + $installArgs)
            if ($manifest.Expectation.Service -and (Get-Content -LiteralPath $sentinelPath -Raw).Trim() -ne 'preserve desktop daemon state') {
                throw 'The desktop upgrade removed daemon state.'
            }
        } else {
            Invoke-WinGet -ArgumentList (@('install', '--manifest', $manifest.Directory, '--log', (Join-Path $LogDir "$($manifest.Identifier)-install.log")) + $installArgs)
        }
        Test-Installed -Manifest $manifest
    }

    for ($index = 0; $index -lt $manifests.Count; $index++) {
        $manifest = $manifests[$index]
        Invoke-WinGet -ArgumentList (@('uninstall', '--manifest', $manifest.Directory, '--log', (Join-Path $LogDir "$($manifest.Identifier)-uninstall.log")) + $commonArgs)
        Test-Removed -Manifest $manifest
        for ($remaining = $index + 1; $remaining -lt $manifests.Count; $remaining++) {
            Test-Installed -Manifest $manifests[$remaining]
        }
    }
} finally {
    Remove-Item -LiteralPath $sentinelPath -Force -ErrorAction SilentlyContinue
    $diagnostics = Join-Path $env:LOCALAPPDATA 'Packages\Microsoft.DesktopAppInstaller_8wekyb3d8bbwe\LocalState\DiagOutputDir'
    if (Test-Path -LiteralPath $diagnostics) {
        Copy-Item -Path (Join-Path $diagnostics '*') -Destination $LogDir -Recurse -Force -ErrorAction SilentlyContinue
    }
}

Write-Output 'WinGet manifest tests passed.'
