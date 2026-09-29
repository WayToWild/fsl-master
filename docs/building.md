# Bouwen

## Vereisten (alleen ontwikkelmachine)

- Windows met **Windows PowerShell 5.1**
- Module **ps2exe 1.0.18** (gepind; getest):
  `Install-Module ps2exe -RequiredVersion 1.0.18 -Scope CurrentUser`
- **Pester** 3.4 of nieuwer (de in-box 3.4 volstaat; de tests gebruiken de syntaxis `Should Be`)
- Git (optioneel, voor het commit-hash in het About-scherm)

De gebouwde exe heeft op de doelhost **geen** modules of installaties nodig.

## Bouwen

```powershell
.\build.ps1                 # volledige build incl. tests en smoke-test
.\build.ps1 -SkipTests      # zonder Pester
.\build.ps1 -SkipSmoke      # zonder smoke-test
```

Stappen:

1. Builddependencies controleren (PowerShell-versie, ps2exe-versie, Pester) en duidelijk melden wat ontbreekt.
2. Broncode valideren: PowerShell-parser voor alle `.ps1`, XAML-parse, BOM-controle en een zoekactie naar verboden constructies
   (`-ExecutionPolicy Bypass`, `Invoke-WebRequest`, `DownloadString`, remoting-cmdlets, …).
3. Pester-tests (`tests\FslMaster.Tests.ps1`).
4. Bundel maken (`build\work\fsl-master.bundle.ps1`).
5. `dist` leegmaken en `fsl-master.exe` compileren (x64, STA, `-noConsole`, `-requireAdmin`, icoon, versie-informatie).
6. Executable controleren: MZ/PE-header, aanwezigheid van `requestedExecutionLevel level="requireAdministrator"`, bestandsversie.
7. Smoke-test: de bundel wordt als script uitgevoerd (zelftest + alle pagina's naar PNG renderen; faalt bij onverwachte uitvoer of fouten).
   Daarna wordt een niet-verhoogde tweeling van de exe gecompileerd en gestart. Blokkeert het besturingssysteem het starten van
   niet-ondertekende executables, dan meldt de build dat expliciet als **WAARSCHUWING (exe niet runtime-getest)**.
8. SHA256 (`dist\fsl-master.exe.sha256`), `dist\build-info.json` en `dist\fsl-master.zip`.

## Output

```
dist\fsl-master.exe
dist\fsl-master.exe.sha256
dist\fsl-master.zip            (exe, hash, build-info, LICENSE, README)
dist\build-info.json
```

## Icoon

`assets\fsl-master.ico` wordt door `build\New-Icon.ps1` uit code gegenereerd (System.Drawing) en alleen opnieuw gemaakt als het bestand
ontbreekt.

## Bestandscodering

Alle `.ps1`/`.xaml`-bestanden zijn **UTF-8 met BOM** (nodig voor niet-ASCII-tekst in Windows PowerShell 5.1).
`build\Set-Utf8Bom.ps1` herstelt dit automatisch tijdens de build.

## Ondertekenen (aanbevolen)

De exe is niet ondertekend. Onderteken met een eigen certificaat na de build, bijvoorbeeld:

```powershell
Set-AuthenticodeSignature .\dist\fsl-master.exe -Certificate $cert -TimestampServer http://timestamp.digicert.com
```

Bereken daarna de SHA256 opnieuw; de ZIP moet dan opnieuw worden aangemaakt.

## Tests los uitvoeren

```powershell
Invoke-Pester -Script .\tests\FslMaster.Tests.ps1
```
