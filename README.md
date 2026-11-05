# Take-Liste

macOS-App (ab macOS 14) zum Prüfen, Aufteilen und Zusammenführen von Synchron-Takelisten (.xlsx).

- Takes nach Wortzahl oder Dauer an Satzgrenzen aufteilen, Timecodes proportional verteilen
- Integritätsprüfung: fehlende Rollen/Timecodes, Überschneidungen, Schreibvarianten, Sonderzeichen
- **Listen zusammenführen** (⇧⌘M): mehrere offene Tabellen mit eigenem Basis- und Start-Timecode zu einer Gesamtliste vereinen – die Abstände der Takes bleiben exakt gleich
- Export als Excel, Nuendo-/Cubase-Marker-CSV oder Resolve-Marker-EDL
- Einstellungen bleiben gespeichert, auch über Updates hinweg

## Installation

Die aktuelle Version liegt unter [Releases](https://github.com/skyks030/take-list/releases/latest) (`.dmg` oder `.zip`).
Die App prüft bei jedem Start, ob es eine neue Version gibt, und bietet die Installation an
(Menü *Take-Liste → Nach Updates suchen …* prüft sofort).

Da die App nicht notarisiert ist: beim ersten Start Rechtsklick → *Öffnen*.

## Entwicklung

```sh
swift test          # Tests
./build.sh          # baut build/Take-Liste.app
scripts/release.sh 1.1.0 "Was ist neu"   # Version setzen, bauen, taggen, GitHub-Release mit .zip/.dmg
```
