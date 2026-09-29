# Changelog

Alle noemenswaardige wijzigingen in FSL Master. Formaat: [Keep a Changelog](https://keepachangelog.com/), versies: [SemVer](https://semver.org/).

## [0.1.0] - 2026-09-29

### Toegevoegd
- Eerste versie: WPF-interface (PowerShell 5.1) met dashboard, FSLogix-configuratie (policy vs. lokaal), services en componenten,
  gebruikers en sessies (WTS-API), containers en redirects, events, FSLogix-logbestanden, health check met score, rapportage
  (HTML/JSON/CSV/TXT, optioneel sanitized) en About-scherm.
- Achtergrondverwerking in runspaces, foutisolatie per databron, auto-refresh zonder overlappende acties.
- Donker en licht thema; status altijd met tekst en pictogram.
- Portable `fsl-master.exe` (PS2EXE 1.0.18, `requireAdministrator`), SHA256-bestand en ZIP via `build.ps1`.
- Pester-testsuite voor de dataverzamelings- en exportlaag.
- Documentatie: README, architecture, building, security, troubleshooting.
