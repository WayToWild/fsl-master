# Building

## Requirements (development machine only)

- Windows with **Windows PowerShell 5.1**
- Module **ps2exe 1.0.18** (pinned; tested):
  `Install-Module ps2exe -RequiredVersion 1.0.18 -Scope CurrentUser`
- **Pester** 3.4 or newer (the in-box 3.4 is enough; the tests use the `Should Be` syntax)
- Git (optional, for the commit hash in the About screen)

The built exe needs **no** modules or installations on the target host.

## Building

If the scripts come from a downloaded ZIP, unblock them first and relax the execution policy for the current session only:

```powershell
Get-ChildItem -Recurse . | Unblock-File
Set-ExecutionPolicy -Scope Process -ExecutionPolicy RemoteSigned
```

```powershell
.\build.ps1                 # full build including tests and smoke test
.\build.ps1 -SkipTests      # without Pester
.\build.ps1 -SkipSmoke      # without smoke test
```

Steps:

1. Check build dependencies (PowerShell version, ps2exe version, Pester) and clearly report what is missing.
2. Validate the source: PowerShell parser for all `.ps1`, XAML parse, BOM check and a search for forbidden constructs
   (`-ExecutionPolicy Bypass`, `Invoke-WebRequest`, `DownloadString`, remoting cmdlets, …).
3. Pester tests (`tests\FslMaster.Tests.ps1`).
4. Create the bundle (`build\work\fsl-master.bundle.ps1`).
5. Empty `dist` and compile `fsl-master.exe` (x64, STA, `-noConsole`, `-requireAdmin`, icon, version info).
6. Verify the executable: MZ/PE header, presence of `requestedExecutionLevel level="requireAdministrator"`, file version.
7. Smoke test: the bundle is run as a script (self-test + render all pages to PNG; fails on unexpected output or errors).
   Then a non-elevated twin of the exe is compiled and started. If the operating system blocks starting
   unsigned executables, the build reports that explicitly as a **WARNING (exe not runtime-tested)**.
8. SHA256 (`dist\fsl-master.exe.sha256`), `dist\build-info.json` and `dist\fsl-master.zip`.

## Output

```
dist\fsl-master.exe
dist\fsl-master.exe.sha256
dist\fsl-master.zip            (exe, hash, build info, LICENSE, README)
dist\build-info.json
```

## Icon

`assets\fsl-master.ico` is generated from code by `build\New-Icon.ps1` (System.Drawing) and only recreated when the file is missing.

## File encoding

All `.ps1`/`.xaml` files are **UTF-8 with BOM** (needed for non-ASCII text in Windows PowerShell 5.1).
`build\Set-Utf8Bom.ps1` restores this automatically during the build.

## Signing (recommended)

The exe is not signed. Sign it with your own certificate after the build, for example:

```powershell
Set-AuthenticodeSignature .\dist\fsl-master.exe -Certificate $cert -TimestampServer http://timestamp.digicert.com
```

Then recompute the SHA256; the ZIP must be recreated as well.

## Running the tests separately

```powershell
Invoke-Pester -Script .\tests\FslMaster.Tests.ps1
```
