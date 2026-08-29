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

## Abgrenzung

- **Erkennung** funktioniert ohne Homebrew. Wer brew nicht hat, sieht trotzdem, was veraltet ist.
- **Ausführung** delegiert an das jeweils zuständige Werkzeug, statt eine eigene
  Download- und Installationsroutine zu bauen.
- **Team-ID-Prüfung** blockiert Updates, wenn eine App plötzlich von einem anderen
  Entwickler signiert ist — Schutz gegen die Übernahme eines Update-Kanals.

## Verwandte Projekte

- [chenasraf/OpenUpdater](https://github.com/chenasraf/OpenUpdater) — verfolgt denselben
  Zweck über handgepflegte Rezepte. Sein deklaratives YAML-Schema ist die Vorlage für
  die Fallback-Rezepte in OpenFreshr.
- [jakejarvis/versioneer](https://github.com/jakejarvis/versioneer) — nativer
  macOS-App-Updater, frühe Alpha.

## Status

Konzeptphase — noch kein Produktivcode.

- [Product Requirements Document](docs/PRD.md)
- [Implementierungsplan](docs/PLAN.md)

## Lizenz

[MIT](LICENSE)
