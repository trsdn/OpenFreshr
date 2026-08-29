# Implementierungsplan: OpenUpdatr

> Quelle: [PRD.md](PRD.md)  
> Prinzip: Jede Phase ist ein schmaler, eigenständig startbarer Tracer Bullet mit
> sichtbarem End-to-End-Nutzen. Noch kein Produktivcode ist Teil dieses Dokuments.

## Dauerhafte Architekturentscheidungen

- **Plattform:** native macOS-App, SwiftUI, macOS 14+, zunächst Apple Silicon.
- **Projektaufbau:** separat testbarer Swift-6-Core plus dünne App-Hülle. Deklaratives
  XcodeGen-Projekt; die generierte Xcode-Projektdatei wird für reproduzierbare
  Broker-Builds eingecheckt.
- **Primäre UI:** Hauptfenster mit `NavigationSplitView`; „Installiert“ und
  „Katalog“ sind stabile Hauptbereiche.
- **Erkennung:** lokaler Inventory-Scan ist vollständig unabhängig von Homebrew.
- **Quellenmodell:** eine App kann gleichzeitig mehrere Quellen besitzen; Konflikte
  werden erhalten statt durch eine globale Priorität verborgen.
- **Ausführung:** austauschbares `PackageBackend`; erste Backends sind Homebrew,
  Mac App Store und Microsoft AutoUpdate.
- **Matching:** exakte App-Artefakte und Bundle-IDs sind starke Signale.
  Fuzzy-Namensmatches sind nur Vorschläge, bis der Nutzer sie bestätigt.
- **Sicherheit:** strukturierte Prozessaufrufe ohne Shell-Interpolation;
  Signaturprüfung, Gatekeeper und Team-ID-Vertrauen vor App-Ersatz.
- **Privilegien:** kein privilegierter Helper in v1. Erhöhte Rechte bleiben beim
  ausführenden Backend und dessen sichtbarem System-Prompt.
- **Selbst-Updater:** Sparkle/Electron standardmäßig anzeigen, nicht anstoßen;
  `msupdate` darf aktiv ausgeführt werden.
- **Persistenz:** lokaler Cache für Katalog und Scan; lokaler Vertrauensspeicher für
  Team IDs und bestätigte Match-Ausnahmen.
- **Release:** Developer ID, Notarisierung, Stapling, DMG und Sparkle. Signing-Secrets
  bleiben im bestehenden Notarisierungs-Broker, nicht in diesem Repository.

## Qualitätsstrategie für alle Phasen

- Externes Verhalten an Modulgrenzen testen, keine privaten Details.
- Dateisystem, Netz und Prozesse abstrahieren; Tests verändern keine echten Apps.
- Reale, eingecheckte Fixtures aus anonymisierten Varianten des Coverage-Scans,
  Cask-API-Antworten und Appcasts verwenden.
- Jede Phase hat mindestens einen automatisierten End-to-End-Smoke-Test ihres
  Nutzpfads sowie gezielte Fehlerfälle.
- Nach echten Paketaktionen gilt ausschließlich ein erneuter Scan als
  Erfolgsnachweis.

---

## Phase 1: Bestand erkennen und Apps adoptieren

**Abgedeckte User Stories:** 1–18, 41, 45–47

### Nutzwert

Der Nutzer startet OpenUpdatr, sieht seine installierten GUI-Apps mit Version und
Quelle und erhält die zentrale Vorschau: Welche manuell installierten Apps können
sofort sicher in die Homebrew-Verwaltung übernommen werden? Er wählt einzelne Apps
aus und stößt `brew install --cask --adopt` kontrolliert an.

### End-to-End-Umfang

- Native App-Hülle mit dem Bereich „Installiert“.
- Scan von `/Applications`, `~/Applications` und `/Applications/Utilities`.
- Normalisiertes App-Modell aus Bundle-Metadaten, MAS-Receipt, Sparkle- und
  Electron-Markern.
- Lokaler Cask-Katalog-Cache und Matching über App-Artefakt, Bundle-ID und
  konservative Namensähnlichkeit.
- Match-Erklärung und Konfidenz in der UI.
- Anzeige von App, installierter Version, verfügbarer Version und Quelle.
- Erkennung des Homebrew-Verwaltungsstatus, ohne den Scan davon abhängig zu machen.
- Adoption-Vorschau mit Einzelauswahl; unsichere Matches sind nicht vorausgewählt
  und nicht direkt ausführbar.
- Ausführung über das Homebrew-Backend mit getrennten Prozessargumenten.
- Fortschritt, Fehler und erneuter Scan pro Adoption.

### Wichtige Produktregel

Der Coverage-Scan enthält einen bekannten falschen Kandidaten:
`Copilot.app` darf nicht allein aufgrund seines Namens dem Cask `copilot-money`
zugeordnet oder von diesem adoptiert werden. Dieser Fall wird zu einem festen
Regressionstest für den Resolver.

### Akzeptanzkriterien

- [ ] Die App startet und zeigt einen realen Scan des Referenzsystems.
- [ ] Mindestens 100 von 109 relevanten Fremd-Apps erhalten eine nachvollziehbare
      Quellenzuordnung.
- [ ] Kontrollierte Vorschläge ermöglichen mindestens 104 Zuordnungen, ohne einen
      Fuzzy-Treffer automatisch freizugeben.
- [ ] Ohne Homebrew bleibt die Bestands- und Quellenansicht nutzbar.
- [ ] Sicher zugeordnete, nicht verwaltete Casks erscheinen in der
      Adoption-Vorschau.
- [ ] Der Nutzer kann jede Adoption einzeln ein- oder ausschließen.
- [ ] Die Vorschau zeigt App-Pfad, Cask-Token, Match-Grund und auszuführende Aktion.
- [ ] Der bekannte `Copilot`/`copilot-money`-Fehlmatch wird blockiert.
- [ ] Ein Prozessfehler bleibt der betroffenen App zugeordnet und ist wiederholbar.
- [ ] Eine erfolgreiche Adoption wird erst nach einem erneuten Scan als erfolgreich
      angezeigt.

---

## Phase 2: Verfügbare Updates zuverlässig anzeigen

**Abgedeckte User Stories:** 19–22, 39–41, 45, 47

### Nutzwert

Die installierte Ansicht wird zum zentralen Update-Dashboard. Sie zeigt veraltete
Apps, Quellkonflikte und selbst-updatende Apps, führt aber noch keine allgemeinen
Updates aus.

### End-to-End-Umfang

- Aktualisierung und Cache-Alter für Cask-Katalog und Analytics sichtbar machen.
- Verfügbare Cask-Versionen gegen installierte Versionen vergleichen.
- Explizite Sparkle-Appcasts defensiv laden und passende Releases auswählen.
- MAS- und MAU-Verfügbarkeit über ihre jeweiligen Tools ermitteln.
- Quelle, Aktualität, Updatezustand und Unsicherheit pro App darstellen.
- Filter „Updates“, „selbst-updatend“, „nicht zugeordnet“ und „Fehler“.
- Manuelles Aktualisieren aller Metadaten und erneuter Scan.
- Offline-Fallback auf den zuletzt erfolgreichen Bestand und Katalog mit klarer
  Altersangabe.

### Akzeptanzkriterien

- [ ] Jede App kann mehrere sichtbare Quellen und deren Status besitzen.
- [ ] Ein nicht erreichbarer Dienst löscht keine zuletzt bekannten Daten.
- [ ] Nicht vergleichbare Versionen werden als „unbekannt“ statt als Update
      dargestellt.
- [ ] Sparkle-/Electron-Apps sind als selbst-updatend gekennzeichnet.
- [ ] Ein eingebettetes Sparkle-Framework ohne auslesbaren Feed erzeugt keine
      erfundene verfügbare Version.
- [ ] Veraltete Cache-Daten sind in der UI eindeutig erkennbar.
- [ ] Alle Parser und Versionsfälle laufen reproduzierbar gegen lokale Fixtures.

---

## Phase 3: Updates über drei Backends ausführen

**Abgedeckte User Stories:** 20–27, 38, 41, 45–47

### Nutzwert

Der Nutzer wählt Updates aus und führt Homebrew-, Mac-App-Store- und
Microsoft-AutoUpdate-Aktionen in einem konsistenten Ablauf aus.

### End-to-End-Umfang

- Einheitliche Vorschau für Updateaktionen unabhängig vom Backend.
- Homebrew-Cask-Updates einschließlich `auto_updates` und `latest`.
- Mac-App-Store-Updates über `mas`.
- Microsoft-Updates über `msupdate`.
- Selbst-updatende Sparkle-/Electron-Apps bleiben standardmäßig reine Hinweise.
- Pro-App-Ausnahme „trotzdem über OpenUpdatr aktualisieren“, sofern ein geeignetes
  ausführbares Backend existiert.
- Batch-Fortschritt mit unabhängigem Ergebnis je App.
- Wiederholung fehlgeschlagener Aktionen ohne erneute Ausführung erfolgreicher Apps.
- Erneuter Scan nach jeder abgeschlossenen Aktion.

### Akzeptanzkriterien

- [ ] Die Vorschau nennt App, Zielversion, Backend und Paketbezeichner.
- [ ] Keine Aktion startet ohne explizite Nutzerfreigabe.
- [ ] Homebrew-, MAS- und MAU-Aktionen liefern dasselbe verständliche Statusmodell.
- [ ] Sparkle-/Electron-Apps werden nicht automatisch parallel aktualisiert.
- [ ] Ein Fehler in einem Backend erzeugt keine falsche Erfolgsmeldung für andere
      oder nachfolgende Apps.
- [ ] Abbruch und Wiederholung sind deterministisch und getestet.
- [ ] Nach dem Prozess entscheidet der lokale Scan über den tatsächlichen Zustand.

---

## Phase 4: Vertrauenskette vor App-Ersatz durchsetzen

**Abgedeckte User Stories:** 28–32, 45–47

### Nutzwert

OpenUpdatr schützt aktiv vor unerwarteten Herausgeberwechseln und macht
Sicherheitsentscheidungen verständlich. Das ist ein sichtbares
Alleinstellungsmerkmal gegenüber einem reinen Paketmanager-Frontend.

### End-to-End-Umfang

- Team ID installierter Apps beim ersten Scan als Trust-on-first-use erfassen.
- Signaturprüfung und Gatekeeper-Bewertung in den Aktionsablauf integrieren.
- Team ID der neuen Version gegen den gespeicherten Vertrauenswert vergleichen.
- Blockierende Konfliktansicht bei ungültiger Signatur, Gatekeeper-Ablehnung oder
  Team-ID-Wechsel.
- Expliziter, protokollierter Ausnahmeablauf für einen legitimen Team-ID-Wechsel.
- Ansicht zum Prüfen und Zurücksetzen gespeicherter Vertrauensentscheidungen.
- Klare Trennung zwischen OpenUpdatr-Prüfung und Sicherheitsgarantien des Backends.

### Akzeptanzkriterien

- [ ] Eine ungültige Signatur blockiert den App-Ersatz.
- [ ] Eine Gatekeeper-Ablehnung blockiert den App-Ersatz.
- [ ] Eine unveränderte Team ID erlaubt den normalen Ablauf.
- [ ] Eine geänderte Team ID stoppt die Aktion vor dem Ersatz.
- [ ] Die Warnung zeigt alte und neue Team ID sowie betroffene Bundle-ID.
- [ ] Eine Ausnahme erfordert eine separate explizite Bestätigung und wird
      nachvollziehbar gespeichert.
- [ ] Ein Reset des Vertrauens führt beim nächsten Scan zu einer neuen
      Erstbeobachtung, nicht zu implizitem Vertrauen.

---

## Phase 5: Neue Apps im Katalog entdecken und installieren

**Abgedeckte User Stories:** 33–41, 45–47

### Nutzwert

OpenUpdatr wird vom Updater zum „App Store für den Rest des Mac“: Der Nutzer kann
den Cask-Katalog durchsuchen, populäre Apps entdecken und eine ausgewählte GUI-App
installieren.

### End-to-End-Umfang

- Zweiter Hauptbereich „Katalog“ im `NavigationSplitView`.
- Lokaler Cache des Cask-Katalogs und der 365-Tage-Installationsstatistik.
- Suche über Token, Name und Beschreibung.
- Sortierung nach Popularität und Name.
- Detailansicht mit Beschreibung, Homepage, Version, Artefakten und
  Installationsstatus.
- Kennzeichnung bereits installierter Apps und möglicher Zuordnungsunsicherheit.
- Installationsvorschau mit Homebrew-Token und Zielwirkung.
- Ausführung über `PackageBackend`, anschließend lokaler Scan und
  Vertrauensinitialisierung.

### Akzeptanzkriterien

- [ ] Der vollständige Katalog bleibt bei ungefähr 7.715 Einträgen flüssig
      durchsuchbar.
- [ ] Popularitätsdaten beeinflussen die Sortierung nachvollziehbar.
- [ ] Fehlende Analytics verhindern weder Suche noch alphabetische Sortierung.
- [ ] Bereits installierte Apps werden nicht als unkritische Neuinstallation
      angeboten.
- [ ] Vor der Installation sind Backend, Cask-Token und Homepage sichtbar.
- [ ] Nach erfolgreicher Installation erscheint die App in „Installiert“.
- [ ] Eine Installation wird erst nach lokalem Scan als erfolgreich markiert.

---

## Phase 6: Hintergrundstatus und Menüleiste

**Abgedeckte User Stories:** 40–43

### Nutzwert

Der Nutzer sieht verfügbare Updates ohne geöffnetes Hauptfenster und gelangt mit
einem Klick zur relevanten Liste.

### End-to-End-Umfang

- Geplanter, ressourcenschonender Hintergrundscan ohne automatische Installation.
- `MenuBarExtra` mit Anzahl verfügbarer Updates, letztem Scan und Fehlerstatus.
- Direkter Sprung in die gefilterte Updateansicht des Hauptfensters.
- Nutzersteuerung für Scanintervall und Startverhalten.
- Klare Behandlung von Offline-Zustand und veralteten Daten.

### Akzeptanzkriterien

- [ ] Die Menüleiste zeigt dieselbe Updatezahl wie das Hauptfenster.
- [ ] Ein Klick öffnet die passende gefilterte Ansicht.
- [ ] Hintergrundscans starten keine Installation und keinen Selbst-Updater.
- [ ] Wiederholte Scans verursachen keine parallelen Paketmanagerprozesse.
- [ ] Scanintervall und Hintergrundverhalten können deaktiviert werden.
- [ ] Energie- und Laufzeitkosten werden auf einem realen System gemessen und
      dokumentiert.

---

## Phase 7: Gehärteter Direktvertrieb und Selbst-Update

**Abgedeckte User Stories:** 44, 48

### Nutzwert

OpenUpdatr kann außerhalb der Entwicklungsmaschine sicher installiert und über
Sparkle aktualisiert werden. Damit dogfoodet das Produkt seinen eigenen
Erkennungsfall.

### End-to-End-Umfang

- Releasefähige App-Konfiguration mit Hardened Runtime und minimalen Entitlements.
- Sparkle-Feed und signierte Selbst-Updates.
- DMG-Erstellung mit Developer-ID-Signatur, Notarisierung und Stapling.
- Integration in den vorhandenen macOS-Notarisierungs-Broker.
- Secretloser Build und Preflight vor dem getrennten Signierschritt.
- Dokumentierter Installations-, Verifikations- und Releaseablauf.
- Smoke-Test eines Upgrades von der vorherigen veröffentlichten Version.

### Akzeptanzkriterien

- [ ] Das DMG besteht Gatekeeper- und Signaturprüfung auf einem sauberen Mac.
- [ ] Die App läuft aus `/Applications` ohne dauerhaft privilegierten Helper.
- [ ] Der Sparkle-Feed bietet nur korrekt signierte Releases an.
- [ ] Ein Update von Version N auf N+1 erhält Einstellungen, Match-Ausnahmen und
      Vertrauensspeicher.
- [ ] Build und Preflight benötigen keine Signing-Secrets.
- [ ] Signierung und Notarisierung erfolgen ausschließlich im Broker mit
      menschlicher Freigabe.
- [ ] Release-Artefakte enthalten Integritäts- und Provenienzangaben entsprechend
      dem bestehenden App-Muster.

## Nach v1 mögliche Erweiterungen

- Native Download-/Installations-Engine als weiteres `PackageBackend`.
- Homebrew Formulae und CLI-Tools in einem getrennten Produktbereich.
- Apple-`softwareupdate`-Aktionen, sofern UX und Abgrenzung zu Systemupdates
  belastbar sind.
- Weitere Katalogquellen und verifizierte Community-Zuordnungen.
- Optionaler privilegierter Helper, aber nur bei gemessenem, wiederkehrendem Bedarf.
- Richtlinien für unbeaufsichtigte Updates auf ausdrücklich freigegebenen Apps.

