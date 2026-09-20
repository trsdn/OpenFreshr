# OpenFreshr

Ein Ersatz für [MacUpdater](https://www.corecode.io/macupdater/) (eingestellt zum 01.01.2026) —
mit dem Unterschied, dass OpenFreshr Apps nicht nur **aktualisiert**, sondern auch
**findet und installiert**.

## Idee

MacUpdater lebte von einer kuratierten Datenbank mit ~100.000 Apps. Die ist nicht
nachbaubar — und auch nicht nötig. Vier bereits gepflegte Quellen decken einen realen
Mac praktisch vollständig ab:

| Quelle | Wer pflegt sie |
|---|---|
| Homebrew Cask | Homebrew-Community |
| Mac App Store | Apple |
| Microsoft AutoUpdate | Microsoft |
| Sparkle-Appcast | die App-Hersteller selbst |

Gemessen auf einem realen Entwickler-Mac: **91 % von 109 Fremd-Apps** ohne jede
Kuratierung, ~95 % mit konservativem Namensabgleich. Die Messung liegt reproduzierbar
in [`docs/research/`](docs/research/).

## Was es tut

| | |
|---|---|
| **Erkennen** | Scan der Programmordner mit Quellen-Markern. Funktioniert vollständig ohne Homebrew. |
| **Aktualisieren** | Ein Knopf pro App. Kennt Homebrew sie nicht, übernimmt derselbe Knopf sie zuerst. |
| **Entdecken** | Durchsuchbarer Katalog über 7716 Casks mit Popularitäts-Ranking und Installation. |
| **Absichern** | Signatur, Gatekeeper und Team-ID-Prüfung vor jedem App-Ersatz. |
| **Beobachten** | Menüleiste mit Update-Zähler, Hintergrundprüfung nach Zeitplan. |

## Abgrenzung

- **Erkennung** funktioniert ohne Homebrew. Wer brew nicht hat, sieht trotzdem, was veraltet ist.
- **Ausführung** delegiert an das jeweils zuständige Werkzeug, statt eine eigene
  Download- und Installationsroutine zu bauen.
- **Team-ID-Prüfung** blockiert Updates, wenn eine App plötzlich von einem anderen
  Entwickler signiert ist — Schutz gegen die Übernahme eines Update-Kanals.
- **Nichts läuft unbeaufsichtigt.** Jede Aktion zeigt vorher den exakten Befehl, und ein
  Erfolg gilt erst, wenn ein erneuter Scan die Version auf der Platte bestätigt.

## Bauen

```bash
make build    # UI-freier Core
make test     # Testsuite, ohne Xcode, ohne Netz, ohne brew
make app      # App-Hülle, ohne Signatur — läuft auf jeder Maschine
make run      # signiert bauen und starten
```

`make app` erzeugt eine ad-hoc signierte App ohne stabile Code-Identität; macOS fragt
dann bei jedem Start erneut nach Berechtigungen. Zum Benutzen `make run` verwenden.

## Verwandte Projekte

- [chenasraf/OpenUpdater](https://github.com/chenasraf/OpenUpdater) — verfolgt denselben
  Zweck über handgepflegte Rezepte. Sein deklaratives YAML-Schema ist die Vorlage für
  mögliche Fallback-Rezepte in OpenFreshr.
- [jakejarvis/versioneer](https://github.com/jakejarvis/versioneer) — nativer
  macOS-App-Updater, frühe Alpha.

## Status

Funktional vollständig, noch nicht veröffentlicht. Für ein Release fehlen die
Notarisierung über den Broker und der öffentliche Repository-Status.

- [Product Requirements Document](docs/PRD.md)
- [Implementierungsplan](docs/PLAN.md)
- [Release-Vorbereitung](docs/release/)
- [Changelog](CHANGELOG.md)

## Lizenz

[MIT](LICENSE)
