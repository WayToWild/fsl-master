# Troubleshooting

## De applicatie start niet of wordt geblokkeerd
- Het uitvoerbare bestand is niet ondertekend. Antivirus, EDR of WDAC/AppLocker kan het blokkeren ("Access is denied" bij starten).
  Vraag een uitzondering aan of onderteken de exe met een eigen certificaat. Als tijdelijk alternatief kan de bron worden gestart met
  `start-dev.ps1` vanuit een verhoogde Windows PowerShell 5.1.
- Controleer de hash tegen `fsl-master.exe.sha256`.
- Bij het openen van een gedownload ZIP: *Eigenschappen → Blokkering opheffen* (Mark of the Web).

## "Administratorrechten vereist"
De applicatie moet verhoogd draaien. Kies *Ja* om opnieuw verhoogd te starten, of start met *Als administrator uitvoeren*.

## Onderdeel toont "Niet geïnstalleerd" of "Niet beschikbaar"
- FSLogix is niet gevonden (geen `HKLM\SOFTWARE\FSLogix\Apps\InstallPath`, geen `Program Files\FSLogix\Apps`, geen service `frxsvc`). Dit is
  geen fout; FSLogix-specifieke controles worden *N.v.t.* en de score krijgt de status *Onbekend*.
- Een eventlog ontbreekt (bijv. `Microsoft-FSLogix-Apps/Admin`): dit staat onder de eventlijst vermeld.

## Geen containers of sessies zichtbaar
- Zonder actieve gebruikers zijn er geen gekoppelde containers.
- Open *Containers en redirects → frx-uitvoer (raw)*: staat daar uitvoer, maar herkent de parser geen records, dan wijkt het
  uitvoerformaat van uw FSLogix-versie af. Meld een issue met de (gesanitiseerde) uitvoer.
- Controleer of de applicatie verhoogd draait; `Get-Disk`/`Get-SmbConnection` vereisen dat.

## "Time-out" bij fileservers
DNS, poort 445 of het UNC-pad reageerde niet binnen `NetworkTimeoutMs` (standaard 3000 ms). Controleer DNS, firewall/NSG, de
fileserver en de rechten van het computeraccount. Verhoog eventueel `NetworkTimeoutMs` in het configuratiebestand.

## Databronfouten
De knop *Databronfouten (n)* in de statusbalk toont per bron de melding en het technische detail (kopieerbaar). De overige bronnen
zijn niet beïnvloed. Zie ook het logboek.

## Logboek
`%ProgramData%\FSL-Master\Logs\fsl-master-<datum>.log`; het exacte pad staat onder *Over FSL Master*.

## De refresh duurt lang
Een volledige refresh duurt normaal 10–30 s (Windows Update-geschiedenis, volume- en SMB-informatie). Trage DNS of onbereikbare
fileservers kunnen dit met de time-outs verlengen. De GUI blijft ondertussen bruikbaar.

## Ontwikkeling: testen zonder FSLogix
- `start-dev.ps1 -AllowNonElevated -CaptureScreenshots <map>` rendert alle pagina's naar PNG.
- De Pester-tests gebruiken mocks voor registry, services en eventlogs.
