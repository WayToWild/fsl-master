# Architectuur

## Overzicht

```
                +--------------------------------------------------------------+
                |  App.ps1  (param's, elevatiecontrole, XAML laden, wiring)     |
                +-------------------------------+------------------------------+
                                                |
                     UI-thread (STA, WPF)       |         achtergrond-runspaces (MTA)
   +--------------------------------------+     |     +------------------------------------------+
   | UI\Ui.ps1  Update-FslUi*, grids,     |<----+---->| Collect.ps1  Invoke-FslCollectAll         |
   | dashboardkaarten, dialogen, export   | jobs|      |  -> Collectors\*.ps1 (SystemInfo, FSLogix, |
   | DispatcherTimer polt jobs (150 ms)   |     |      |     Sessions, Containers, Events, Health)  |
   +--------------------------------------+     |     |  -> Core\Core.ps1 (log, config, time-outs) |
                      ^                          |     +------------------------------------------+
                      |                          |
   Export\Report.ps1 (sanitize, JSON/CSV/HTML/TXT)   alle functies zonder "FslUi" in de naam worden
                                                     in elke achtergrond-runspace geïnjecteerd
```

## Lagen

| Laag | Map | Verantwoordelijkheid |
|---|---|---|
| Kern | `src\Core` | resultaatmodel (`New-FslResult`), logging, configuratie, time-outhulpen, exportpad-validatie, HTML-encoding |
| Dataverzameling | `src\Collectors` | uitsluitend lezen van de lokale host; geen UI-afhankelijkheden, geen `$script:`-variabelen |
| Export | `src\Export` | rapportmodel, sanitizing, JSON/CSV/HTML/TXT |
| GUI | `src\UI` | WPF-XAML + helpers; werkt alleen op de UI-thread |
| Start | `src\App.ps1` | parameters, elevatie, venster, event-wiring, ontwikkel-/testmodi |

## Threading

- De GUI draait op een STA-thread. Elke langlopende taak (volledige refresh, logbestand lezen/filteren, serviceactie, logbestanden lijsten)
  start een **eigen runspace** (`Start-FslUiJob`) met een `InitialSessionState` waarin alle `*-Fsl*`-functies (behalve `FslUi`) zijn
  opgenomen. Er wordt nooit op de UI-thread op resultaten gewacht.
- Een `DispatcherTimer` (150 ms) controleert `IAsyncResult.IsCompleted`, verwerkt het resultaat op de UI-thread (`OnDone`) en ruimt op.
  Daardoor zijn er geen dispatcher-aanroepen vanuit andere threads nodig en blijft de GUI responsief.
- Voortgang: een gesynchroniseerde hashtable (`Step`, `Progress`) wordt door de collector bijgewerkt en door dezelfde timer weergegeven.
- Overlap: `Start-FslUiRefresh` keert direct terug als er al een refresh loopt (ook bij auto-refresh-ticks).
- Netwerkprobes (DNS, TCP 445, `Test-Path` op UNC) hebben harde time-outs (`Invoke-FslWithTimeout`, `Test-FslTcpPort`,
  `Resolve-FslDnsName`); resultaat is dan *Time-out* in plaats van een hangende refresh.

## Foutisolatie

`Invoke-FslCollectAll` voert elke databron uit in `Invoke-FslStep`: een uitzondering wordt gelogd en als *databronfout* aan de snapshot
toegevoegd (zichtbaar via de knop in de statusbalk); de overige bronnen draaien door. Ontbrekende FSLogix-onderdelen zijn geen fout:
services worden *N.v.t.*, eventlogs worden als *niet aanwezig* gemeld.

## Gegevensbronnen

| Onderdeel | Bron |
|---|---|
| Windows/uptime/UBR | `Win32_OperatingSystem`, registry `CurrentVersion` |
| Laatste update | Windows Update-geschiedenis (COM, met time-out), terugval `Get-HotFix` |
| AVD Agent/Boot Loader | Uninstall-registry (64/32-bit), services `RDAgentBootLoader`/`RdAgent` |
| FSLogix-installatie | registry `HKLM\SOFTWARE\FSLogix\Apps`, `Program Files\FSLogix\Apps`, bestandsversie `frxsvc.exe` |
| Configuratie | `HKLM\SOFTWARE\FSLogix\{Profiles,ODFC}` en `HKLM\SOFTWARE\Policies\FSLogix\…` (policy > lokaal) |
| Services | `Win32_Service`, `Win32_SystemDriver`, `Get-Process` |
| Sessies | WTS API (`wtsapi32.dll`, eigen `Add-Type`), terugval `quser.exe`; profielen via `Win32_UserProfile` + ProfileList |
| Containers | `frx.exe list-redirects`, `Profiles\Sessions\<SID>`, `Get-Disk` (BusType *File Backed Virtual*) + `Get-Volume`, `Get-SmbConnection` |
| Events | `Get-WinEvent -FilterHashtable` (bestaan wordt eerst gecontroleerd met `Get-WinEvent -ListLog`) |
| Logs | `%ProgramData%\FSLogix\Logs\*` via `FileStream` (gedeelde leestoegang, alleen het einde) |

## Verpakking

`build.ps1` voegt `App.ps1`, alle modules en de XAML (als here-string `$script:FslMainXaml`) samen tot `build\work\fsl-master.bundle.ps1`
en compileert die met PS2EXE. Bij het uitvoeren van de bundel is `$script:FslBundled = $true`, waardoor `App.ps1` niets van schijf laadt.
Vanuit broncode laadt `App.ps1` dezelfde bestanden via dot-sourcing (`start-dev.ps1`).

## Ontwikkel-/testmodi van `App.ps1`

| Parameter | Doel |
|---|---|
| `-AllowNonElevated` | draait zonder administrator (beperkte gegevens) |
| `-SelfTest <bestand>` | headless dataverzameling, JSON-samenvatting, exit 0/1 |
| `-CaptureScreenshots <map>` | rendert elke pagina naar PNG en sluit af (wordt door `build.ps1` als GUI-smoke-test gebruikt) |
