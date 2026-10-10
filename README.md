# Octelium WinGet packages

WinGet manifests and automation for the Octelium Windows packages. WinGet installs packages from the community repository [microsoft/winget-pkgs](https://github.com/microsoft/winget-pkgs); this repository prepares, tests and submits the manifests published there.

| Package | Installs | Moniker |
| --- | --- | --- |
| `Octelium.Octelium` | The `octelium` CLI with the WireGuard and Wintun libraries | `octelium` |
| `Octelium.Octeliumctl` | The `octeliumctl` CLI | `octeliumctl` |
| `Octelium.Octops` | The `octops` CLI | `octops` |
| `Octelium.OcteliumDesktop` | Octelium Desktop, its daemon service and libraries | `octelium-desktop` |

Each package installs the official x64 or ARM64 MSI from the [octelium](https://github.com/octelium/octelium/releases) or [octelium-desktop](https://github.com/octelium/octelium-desktop/releases) GitHub releases for all users. The installers require administrator rights; WinGet requests elevation when needed. Octelium Desktop includes its own daemon and does not require the CLI packages.

Once the packages are published:

```powershell
winget install --id Octelium.Octelium --exact
winget install --id Octelium.Octeliumctl --exact
winget install --id Octelium.Octops --exact
winget install --id Octelium.OcteliumDesktop --exact

winget upgrade --id Octelium.Octelium --exact
winget uninstall --id Octelium.Octelium --exact
```

Restart the terminal after installing a CLI package so that the updated `PATH` takes effect. Manage each package with one package manager: WinGet does not update Chocolatey's records for a package installed through Chocolatey.

## Manifests

`manifests/` mirrors the winget-pkgs layout and holds the latest version submitted for each package. Every package version uses the 1.12.0 multi-file format: a version, a default locale and an installer manifest. The installer manifests record the per-architecture MSI `ProductCode` and the stable `UpgradeCode`, so WinGet can match installed versions and MSI major upgrades replace the previous version.

**Test WinGet Manifests** runs on x64 and ARM64 Windows runners. It installs a pinned WinGet release when the runner does not provide one, then validates the manifests and installs them together. It checks the MSI registration, the files, the `PATH` entries, the CLI versions and the desktop daemon service, then uninstalls each package while checking that the others remain usable. When it receives newly generated manifests, it first installs the version recorded here and tests `winget upgrade` from it, including preservation of the desktop daemon state.

## Publishing

Submissions use [Komac](https://github.com/russellbanks/Komac) with a classic GitHub token that has only the `public_repo` scope. The token is stored as the `WINGET_TOKEN` secret of the `winget` environment, which only the `main` branch can use. Komac forks `microsoft/winget-pkgs` under the token's account and opens one pull request per package version from that fork.

To submit the recorded version of a package, run **Submit WinGet Manifests** with `dry_run` enabled to review the generated files, then run it again with `dry_run` disabled. The workflow repeats the Windows tests first and refuses to submit a version that is already published or has an open pull request. The first pull request from an account asks for Microsoft's Contributor License Agreement. After automated validation and moderator approval, the package becomes available once the WinGet catalog is republished.

## Signing

The current MSIs are unsigned. WinGet's community repository does not require code signing, and the manifests verify each installer by SHA256. SHA256 does not establish a publisher identity, so SmartScreen, Smart App Control, antivirus or enterprise policies can still warn about or block unsigned installers and executables, whichever package manager installs them.

Signed releases can be published under the same package identifiers, and existing installations upgrade normally:

- Sign the executables before building the MSIs, then sign the MSIs, and publish them as assets of a new release version.
- Do not replace the assets of an existing release. Its manifest pins the SHA256 of each installer, so changed bytes make that version fail to install.
- Keep the MSI `UpgradeCode`, the per-machine scope and the installer technology. The CLI `UpgradeCode`s are fixed in the octelium MSI build script. Tauri derives the desktop `UpgradeCode` from the product name, so pin it before renaming the product.

WinGet matches installed MSIs by product and upgrade codes and compares versions; whether an installed version was signed does not affect upgrades. If signing changes the MSI manufacturer or product name, the next generated manifest records the new values.
