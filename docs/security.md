# Security

## Uitgangspunten

- **Standaard read-only.** Er worden geen registerwaarden gewijzigd, geen containers ontkoppeld, geen VHD's hersteld en geen profielen
  verwijderd. De health check voert geen `DISM /RestoreHealth`, `sfc /scannow` of `chkdsk /f` uit.
- **Beheeracties** zijn beperkt tot start/stop/herstart van de services `frxsvc` en `frxccds`. Ze zijn duidelijk gemarkeerd, vragen
  een expliciete bevestiging (standaardknop *Nee*, extra waarschuwing bij stop/herstart), worden lokaal uitgevoerd en gelogd
  (`[ACTION]` in het logboek). De functie accepteert via `ValidateSet` geen andere servicenamen.
- **Alleen lokaal.** Geen PowerShell Remoting, WinRM, `Invoke-Command` naar andere hosts, centrale databases, Azure-API's of
  verplichte internetverbinding. `build.ps1` faalt als dergelijke constructies in de broncode verschijnen.
- **Geen telemetrie, geen automatische uploads, geen dynamisch gedownloade code.**
- **Geen ExecutionPolicy-bypass** in de applicatie. Achtergrond-runspaces gebruiken de effectieve ExecutionPolicy van het proces.
- **Geen geheimen.** Er worden geen wachtwoorden, tokens of inloggegevens gelezen, opgeslagen of gelogd. De repository bevat er geen;
  `.gitignore` sluit gangbare geheimbestanden (`.env`, `*.pfx`, `*token*`, …) en runtime-artefacten (logs, exports, lokale config) uit.

## Administratorrechten

`fsl-master.exe` heeft het manifest `requestedExecutionLevel level="requireAdministrator"`. Bij een niet-verhoogde start (bijvoorbeeld
vanuit broncode) toont de applicatie een melding en biedt aan opnieuw verhoogd te starten; de niet-verhoogde instantie sluit af.
De schakelaar `-AllowNonElevated` is uitsluitend bedoeld voor ontwikkeling/tests.

## Invoer en uitvoer

- **HTML:** alle waarden worden met `[System.Net.WebUtility]::HtmlEncode` geëscaped (`ConvertTo-FslHtmlEncoded`); getest met
  markup in gegevens.
- **Exportpaden** (`Test-FslExportPath`): volledig pad vereist, ongeldige tekens en wildcards geweigerd, verwachte extensie afgedwongen,
  doelmap moet bestaan, exporteren naar de Windows-map is niet toegestaan.
- **Configuratiebestand:** ongeldige JSON of waarden vallen terug op veilige standaarden (getest); getallen worden gevalideerd en begrensd.
- **Sanitized report:** maskeert gebruikersnamen, SID's, servernamen, hostnaam, domeinnamen en UNC-paden consistent
  (`User01`, `SID-01`, `SERVER01`, `\\SERVER01\SHARE01`). Controleer het resultaat altijd voordat u het buiten uw organisatie deelt;
  vrije tekst in eventberichten kan andere gevoelige gegevens bevatten die niet als zodanig herkend worden.

## Logging

Logbestand: `%ProgramData%\FSL-Master\Logs\fsl-master-<yyyyMMdd>.log` (terugval `%TEMP%\FSL-Master\Logs`). Bevat applicatiestart en
-versie, administratorstatus, refreshes, databronfouten, time-outs, exports, serviceacties en onverwachte exceptions. Bevat geen
inloggegevens. Logbestanden worden niet automatisch verwijderd of verzonden.

## Bekende risico's

- De exe is niet ondertekend; onderteken hem in beheerde omgevingen (zie [building.md](building.md)).
- PS2EXE-executables worden door sommige antivirusproducten als vals-positief gemeld of door beleid geblokkeerd.
- Het logboek en exports kunnen gebruikersnamen en paden bevatten; bescherm de mappen met passende NTFS-rechten.
