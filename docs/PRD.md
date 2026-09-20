# Product Requirements Document: OpenFreshr

**Status:** Entwurf  
**Zielplattform:** macOS 14+, Apple Silicon  
**Primärer Nutzer:** zunächst der Entwickler selbst  
**Produktidee:** Ein „App Store für den Rest des Mac“, der installierte GUI-Apps erkennt,
Updates transparent macht und neue Apps finden und installieren kann.

## Executive Summary

MacUpdater wurde zum 1. Januar 2026 eingestellt. Sein Kernnutzen – Updates für
außerhalb des Mac App Store installierte Apps sichtbar und ausführbar zu machen –
bleibt relevant. Ein reiner Nachbau würde jedoch zu kurz greifen: OpenFreshr soll
zusätzlich einen durchsuchbaren Katalog bieten und neue Apps installieren können.

OpenFreshr kombiniert lokale, von Homebrew unabhängige Erkennung mit mehreren
Updatequellen. Für die Ausführung verwendet es zunächst etablierte Paket-Backends:
Homebrew Cask, Mac App Store und Microsoft AutoUpdate. Sparkle- und andere
Selbst-Update-Mechanismen werden erkannt und transparent dargestellt, aber nicht
ungefragt parallel angestoßen.

Die Messung auf dem Zielsystem zeigt, dass eine eigene kuratierte App-Datenbank nicht
erforderlich ist: Von 109 relevanten Fremd-Apps erkennt der vorhandene Scan 100
automatisch. Durch kontrolliertes Fuzzy-Matching lassen sich voraussichtlich vier
weitere Kandidaten zuordnen; damit liegt die erwartete Abdeckung bei rund 95 Prozent.
Der wichtigste erste Nutzen ist die sichere Übernahme bereits installierter,
Homebrew-bekannter Apps mittels `brew install --cask --adopt`.

### Erfolgskriterien

- Mindestens 100 der 109 im Referenzscan relevanten Fremd-Apps werden einer oder
  mehreren Quellen zugeordnet.
- Kontrolliertes Fuzzy-Matching erhöht die überprüfbare Zuordnung auf mindestens
  104 von 109 Apps, ohne einen falschen Cask automatisch zu übernehmen.
- OpenFreshr funktioniert für Erkennung und Anzeige auch dann, wenn Homebrew nicht
  installiert oder vorübergehend nicht verfügbar ist.
- Der Nutzer kann in Phase 1 erkannte, noch nicht von Homebrew verwaltete Apps
  einzeln prüfen, auswählen und mit `--adopt` übernehmen.
- Keine Installation oder Adoption erfolgt allein aufgrund eines unsicheren
  Namensmatches.
- Vor jedem durch OpenFreshr ausgeführten App-Ersatz werden Signatur, Gatekeeper-
  Bewertung und Team-ID-Vertrauen geprüft.
- Jede Produktphase liefert einen eigenständig startbaren und demonstrierbaren
  End-to-End-Nutzen.

## Problem

macOS verteilt GUI-Apps über mehrere voneinander unabhängige Kanäle:

- Mac App Store
- direkt geladene Apps mit Sparkle oder proprietärem Selbst-Updater
- Homebrew Casks
- Microsoft AutoUpdate
- Apple Software Update
- manuelle Downloads ohne Updateinfrastruktur

Dadurch fehlt eine gemeinsame Sicht auf installierte Versionen, verfügbare Updates
und Bezugsquellen. Selbst-updatende Apps informieren zu unterschiedlichen
Zeitpunkten, manuell installierte Apps werden leicht vergessen, und das Entdecken
neuer Apps findet getrennt vom Updateprozess statt.

MacUpdater löste einen Teil davon durch eine große kuratierte Datenbank. Diese
Datenbank ist weder realistisch nachzubauen noch für den persönlichen Anwendungsfall
nötig. Die vorhandene Recherche belegt, dass offene Metadaten und lokale
Bundle-Eigenschaften den Großteil der installierten Apps abdecken.

## Zielgruppe

### Primär

Ein technisch erfahrener macOS-Nutzer mit vielen Apps aus unterschiedlichen Quellen,
der Kontrolle, Transparenz und Sicherheitsprüfungen höher gewichtet als vollständig
unbeaufsichtigte Automatisierung.

### Später

Fortgeschrittene macOS-Nutzer, die Apps außerhalb des Mac App Store zentral
entdecken, installieren und aktuell halten möchten, ohne die zugrunde liegenden
Paketmanager selbst bedienen zu müssen.

## Lösung

OpenFreshr ist eine native SwiftUI-App mit zwei primären Bereichen:

- **Installiert:** erkannte Apps, installierte und verfügbare Version, Quelle,
  Vertrauensstatus und mögliche Aktionen.
- **Katalog:** durchsuchbare und nach Popularität sortierbare GUI-App-Auswahl aus
  dem Homebrew-Cask-Katalog.

Die lokale Erkennung scannt App-Bundles und führt Informationen aus `Info.plist`,
MAS-Receipts, Sparkle-Metadaten, Bundle-Struktur und bekannten Quellen in einem
normalisierten App-Modell zusammen. Sie ist nicht von Homebrew abhängig.

Ausführbare Aktionen laufen über austauschbare Paket-Backends. Version 1 verwendet
Homebrew Cask, `mas` und Microsoft AutoUpdate. Eine spätere native
Download-/Installations-Engine kann ergänzt werden, ohne Scan, Matching, UI oder
Vertrauensmodell neu zu bauen.

## Entscheidungen & Annahmen

Alle folgenden Entscheidungen sind **vorläufig, bestätigt durch: —**. Sie sind
bewusst isoliert dokumentiert, damit einzelne Entscheidungen später geändert werden
können, ohne das gesamte Produktkonzept neu aufzubauen.

### 1. Homebrew für Ausführung, nicht für Erkennung

**Entscheidung:** Homebrew ist eine erlaubte harte Abhängigkeit für Cask-Installation,
Adoption, Update und Deinstallation. App-Scan, Quellenzuordnung und
Versionsdarstellung funktionieren ohne Homebrew. Ausführungswege werden hinter
einem `PackageBackend` mit zunächst `HomebrewBackend`, `MASBackend` und `MAUBackend`
gekapselt.

**Begründung:** Homebrew löst Download, Checksummenprüfung, DMG-/PKG-/ZIP-Verarbeitung,
Quarantäne und Deinstallation bereits. Eine eigene Engine wäre die größte
Angriffsfläche des Produkts. Die Backend-Grenze verhindert zugleich eine dauerhafte
architektonische Bindung.

**Verworfene Alternative:** Eine native Installations-Engine ab Phase 1. Sie wäre
deutlich aufwendiger, sicherheitskritischer und würde den ersten Nutzwert verzögern.

### 2. Direktvertrieb ohne privilegierten Helper in v1

**Entscheidung:** OpenFreshr wird mit Developer ID signiert, notarisiert und als DMG
direkt vertrieben. Selbst-Updates erfolgen über Sparkle. Ein `SMAppService`-Helper
gehört nicht zu v1. Falls ein Cask erhöhte Rechte benötigt, verantwortet Homebrew
den sichtbaren `sudo`-Prompt.

**Begründung:** Die App muss nach `/Applications` schreiben und kann deshalb nicht
sinnvoll in der Mac-App-Store-Sandbox betrieben werden. Für die meisten App-Bundles
ist kein dauerhaft privilegierter Prozess nötig. OpenFreshr nutzt mit Sparkle selbst
einen Mechanismus, den es bei anderen Apps erkennt.

**Verworfene Alternative:** Ein privilegierter Helper ab v1. Er erhöht
Angriffsfläche, Signierungsaufwand und Betriebsrisiko, bevor sein Bedarf gemessen ist.

### 3. Hauptfenster zuerst, Menüleiste später

**Entscheidung:** Das Hauptfenster verwendet SwiftUI und `NavigationSplitView`.
„Installiert“ und „Katalog“ sind die primären Bereiche. Ein `MenuBarExtra` folgt
später als kompakte Status- und Einstiegsebene.

**Begründung:** Ein Katalog mit rund 7.715 Casks benötigt Suche, Filter, Details und
Vergleichsfläche. Dieser Entdeckungsweg ist ein wesentliches Unterscheidungsmerkmal
gegenüber MacUpdater.

**Verworfene Alternative:** Eine reine Menüleisten-App. Sie ist für Updatehinweise
geeignet, aber nicht für ernsthaftes Katalog-Browsing.

### 4. Signaturprüfung und Team-ID-Vertrauen

**Entscheidung:** Vor jedem von OpenFreshr veranlassten Ersatz eines App-Bundles
werden `codesign --verify --strict`, Gatekeeper via `spctl --assess --type execute`
und die Team ID geprüft. Die beim ersten Scan gefundene Team ID wird pro Bundle-ID
als Trust-on-first-use gespeichert. Ein Team-ID-Wechsel stoppt die automatische
Aktion und erfordert eine deutliche Warnung sowie explizites Opt-in.

**Begründung:** Ein gültig signiertes Paket kann trotzdem von einem anderen
Entwickler stammen. Der Team-ID-Vergleich reduziert das Risiko einer
Supply-Chain-Übernahme oder falschen Cask-Zuordnung und macht Vertrauen sichtbar.

**Verworfene Alternative:** Allein auf Homebrew-Checksummen und Gatekeeper vertrauen.
Das erkennt keinen unerwarteten Wechsel des signierenden Herausgebers.

### 5. Selbst-Updater anzeigen, nicht parallel auslösen

**Entscheidung:** Sparkle- und Electron-/Squirrel-basierte Apps werden als
„aktualisiert sich selbst“ gekennzeichnet. OpenFreshr stößt deren eigenen Updater
nicht heimlich an. Der Nutzer kann pro App ausdrücklich eine Aktualisierung über
OpenFreshr wählen. Microsoft AutoUpdate darf über `msupdate` ausgelöst werden.

**Begründung:** Zwei konkurrierende Updatewege können laufende Apps oder Bundles
beschädigen. `msupdate` ist dagegen die vorgesehene zentrale MAU-Schnittstelle.

**Verworfene Alternative:** Jeden erkannten Selbst-Updater automatisch anstoßen.
Das wäre schwer vorhersehbar, schlecht beobachtbar und potenziell kollisionsanfällig.

### 6. v1 umfasst ausschließlich GUI-Apps

**Entscheidung:** v1 verwaltet App-Bundles und zugehörige GUI-Anwendungen. Homebrew
Formulae und allgemeine CLI-Tools sind nicht Teil von v1.

**Begründung:** CLI-Software hat ein anderes Erkennungs-, Versions- und
Nutzungsmodell. Homebrew deckt sie im Terminal bereits gut ab. Die Beschränkung hält
das Produktmodell verständlich und den ersten Lieferumfang fokussiert.

**Verworfene Alternative:** GUI-Apps und CLI-Tools von Beginn an gemeinsam
verwalten. Das würde Navigation, Modelle und Sicherheitsprüfungen verbreitern, ohne
den primären Bedarf besser zu lösen.

## User Stories

1. Als Nutzer möchte ich alle relevanten GUI-Apps in meinen üblichen
   Programme-Ordnern scannen, damit ich eine vollständige Bestandsaufnahme erhalte.
2. Als Nutzer möchte ich Shortcuts-Droplets und bekannte Artefakte ausblenden können,
   damit die Liste nicht durch irrelevante Bundles verfälscht wird.
3. Als Nutzer möchte ich pro App Name, Bundle-ID, installierte Version und Pfad
   sehen, damit ich einen Treffer nachvollziehen kann.
4. Als Nutzer möchte ich erkennen, ob eine App aus dem Mac App Store stammt, damit
   der richtige Updateweg verwendet wird.
5. Als Nutzer möchte ich Sparkle-Metadaten und vorhandene Sparkle-Frameworks erkennen,
   damit selbst-updatende Apps sichtbar werden.
6. Als Nutzer möchte ich Electron-/Squirrel-Apps erkennen, damit konkurrierende
   Updatewege vermieden werden.
7. Als Nutzer möchte ich Microsoft-Apps erkennen, die von MAU verwaltet werden,
   damit sie zentral über `msupdate` aktualisiert werden können.
8. Als Nutzer möchte ich Cask-Kandidaten anhand App-Name, Artefaktname, Bundle-ID
   und kontrolliertem Fuzzy-Matching erhalten, damit möglichst viele Apps zugeordnet
   werden.
9. Als Nutzer möchte ich die Begründung und Konfidenz eines Matches sehen, damit ich
   unsichere Zuordnungen beurteilen kann.
10. Als Nutzer möchte ich falsche Matches ablehnen und eine korrekte Zuordnung
    speichern können, damit zukünftige Scans stabiler werden.
11. Als Nutzer möchte ich unsichere Matches nie automatisch adoptieren oder
    aktualisieren lassen, damit ähnlich benannte, aber fremde Apps nicht ersetzt
    werden.
12. Als Nutzer möchte ich ohne installiertes Homebrew trotzdem Scan- und
    Updateinformationen sehen, damit die App nicht wertlos wird.
13. Als Nutzer möchte ich sehen, welche erkannten Apps bereits durch Homebrew
    verwaltet werden, damit ich ihren Zustand verstehe.
14. Als Nutzer möchte ich eine Vorschau aller adoptierbaren Apps sehen, damit keine
    Paketmanageränderung überraschend erfolgt.
15. Als Nutzer möchte ich adoptierbare Apps einzeln auswählen, damit ich die Kontrolle
    über den Homebrew-State behalte.
16. Als Nutzer möchte ich eine ausgewählte App mit `brew install --cask --adopt`
    übernehmen, damit sie zukünftig regulär aktualisiert werden kann.
17. Als Nutzer möchte ich pro Adoption den ausgeführten Befehl, Status und Fehler
    sehen, damit die Aktion überprüfbar bleibt.
18. Als Nutzer möchte ich fehlendes oder defektes Homebrew verständlich angezeigt
    bekommen, damit ich das Problem gezielt beheben kann.
19. Als Nutzer möchte ich verfügbare Versionen aus den jeweiligen Quellen sehen,
    damit ich veraltete Apps erkenne.
20. Als Nutzer möchte ich Quellkonflikte sehen, wenn mehrere Mechanismen dieselbe
    App abdecken, damit kein verdeckter Updateweg gewählt wird.
21. Als Nutzer möchte ich selbst-updatende Apps gekennzeichnet sehen, damit ich weiß,
    warum OpenFreshr nicht automatisch eingreift.
22. Als Nutzer möchte ich pro selbst-updatender App ausdrücklich Homebrew als
    bevorzugten Weg wählen können, damit ich Ausnahmen bewusst steuere.
23. Als Nutzer möchte ich Mac-App-Store-Updates über `mas` ausführen können, damit
    die installierte Ansicht mehrere Quellen bündelt.
24. Als Nutzer möchte ich Microsoft-Updates über `msupdate` ausführen können, damit
    Office und verwandte Apps konsistent aktualisiert werden.
25. Als Nutzer möchte ich Homebrew-Cask-Updates ausführen können, einschließlich
    `auto_updates`- und `latest`-Casks, damit bekannte Updates nicht ausgelassen
    werden.
26. Als Nutzer möchte ich vor einer Aktualisierung eine Zusammenfassung der
    betroffenen Apps und Quellen sehen, damit ich den Vorgang freigeben kann.
27. Als Nutzer möchte ich fehlgeschlagene Aktionen erneut ausführen können, ohne
    erfolgreiche Aktionen zu wiederholen, damit Batch-Updates beherrschbar bleiben.
28. Als Nutzer möchte ich die Signatur einer neuen App-Version prüfen lassen, damit
    beschädigte oder manipulierte Bundles abgewiesen werden.
29. Als Nutzer möchte ich eine Gatekeeper-Ablehnung als harten Fehler sehen, damit
    nicht vertrauenswürdige Software nicht gestartet wird.
30. Als Nutzer möchte ich bei einer geänderten Team ID einen Update-Stopp und eine
    verständliche Warnung erhalten, damit ich einen Herausgeberwechsel bewusst
    prüfen kann.
31. Als Nutzer möchte ich einen legitimen Team-ID-Wechsel explizit bestätigen
    können, damit ein geprüfter Eigentümerwechsel nicht dauerhaft blockiert.
32. Als Nutzer möchte ich sehen, wann und warum eine Vertrauensentscheidung getroffen
    wurde, damit Sicherheitsentscheidungen auditierbar sind.
33. Als Nutzer möchte ich den Cask-Katalog durchsuchen, damit ich neue Apps außerhalb
    des Mac App Store finde.
34. Als Nutzer möchte ich Katalogeinträge nach Popularität sortieren, damit häufig
    verwendete und wahrscheinlich gepflegte Apps leichter auffindbar sind.
35. Als Nutzer möchte ich Name, Beschreibung, Homepage, Version und Installationsart
    eines Katalogeintrags sehen, damit ich vor der Installation informiert bin.
36. Als Nutzer möchte ich installierte Apps im Katalog erkennen, damit ich keine
    Duplikate installiere.
37. Als Nutzer möchte ich eine neue GUI-App über das passende Backend installieren,
    damit Entdecken und Installieren in einem Ablauf stattfinden.
38. Als Nutzer möchte ich vor der Installation sehen, welches Backend und welcher
    Paketbezeichner verwendet werden, damit die Aktion transparent ist.
39. Als Nutzer möchte ich veraltete oder nicht erreichbare Katalogdaten erkennen,
    damit ich Suchergebnisse richtig einordne.
40. Als Nutzer möchte ich auch offline meinen zuletzt bekannten App-Bestand sehen,
    damit ein Netzwerkfehler nicht die gesamte App unbrauchbar macht.
41. Als Nutzer möchte ich den Scan manuell neu starten können, damit Änderungen
    sofort sichtbar werden.
42. Als Nutzer möchte ich später über die Menüleiste die Anzahl verfügbarer Updates
    sehen, damit ich ohne geöffnetes Hauptfenster informiert bin.
43. Als Nutzer möchte ich von der Menüleiste direkt zur gefilterten Updateansicht
    springen, damit Hinweise handlungsorientiert sind.
44. Als Nutzer möchte ich OpenFreshr über Sparkle aktualisieren, damit das Werkzeug
    selbst denselben sicheren Direktvertriebsweg nutzt.
45. Als Entwickler möchte ich Scan, Matching, Versionsvergleich, Vertrauen und
    Paket-Ausführung als getrennte Module testen können, damit Quellen oder Backends
    austauschbar bleiben.
46. Als Entwickler möchte ich externe Prozesse mit strukturierten Argumenten und
    ohne Shell-Interpolation starten, damit App-Namen oder Paketbezeichner keine
    Befehle einschleusen können.
47. Als Entwickler möchte ich Quellantworten und Appcasts gegen feste Test-Fixtures
    prüfen, damit Formatänderungen früh erkannt werden.
48. Als Entwickler möchte ich Releases reproduzierbar bauen, signieren, notarisierten
    und als DMG veröffentlichen, damit Nutzer Herkunft und Integrität prüfen können.

## Funktionale Anforderungen

### App-Erkennung

- Scan von `/Applications`, `~/Applications` und `/Applications/Utilities`.
- Lesen von `CFBundleIdentifier`, `CFBundleShortVersionString`,
  `CFBundleVersion`, `SUFeedURL` und relevanten Bundle-Strukturen.
- Erkennung von MAS-Receipt, Sparkle-Framework und Electron-Framework.
- Deduplizierung mehrfach gefundener Bundles anhand stabiler Identität und Pfad.
- Lokale Erkennung darf keine Homebrew-Installation voraussetzen.
- Der Scan darf unlesbare oder beschädigte Bundles nicht verschweigen; er zeigt
  einen diagnostizierbaren Zustand.

### Quellen und Matching

- Einlesen des Homebrew-Cask-Katalogs mit Token, Namen, Beschreibung, Homepage,
  Version und Artefakten.
- Berücksichtigung von App-Artefaktnamen sowie Bundle-IDs aus Uninstall- und
  Zap-Metadaten.
- Erkennung von Mac-App-Store-Apps über Receipt und Zuordnung zu `mas`.
- Erkennung von MAU-fähigen Apps und Abfrage über `msupdate`.
- Parsen expliziter Sparkle-Appcasts; ein eingebettetes Framework ohne Feed-URL
  wird als Laufzeit-Selbst-Updater, nicht als sicher abfragbare Quelle behandelt.
- Normalisierung von Namen und Versionen vor dem Vergleich.
- Fuzzy-Matching erzeugt ausschließlich Vorschläge. Automatische Aktionen erfordern
  einen starken Identitätsnachweis oder eine bestätigte Zuordnung.
- Mehrere mögliche Quellen bleiben sichtbar; eine Prioritätsregel darf Konflikte
  nicht verdecken.

### Installierte Ansicht

- Darstellung von App, installierter Version, verfügbarer Version, Quelle,
  Verwaltungsstatus, Match-Konfidenz und Vertrauensstatus.
- Filter mindestens für „Updates“, „adoptierbar“, „selbst-updatend“,
  „nicht zugeordnet“ und „Fehler“.
- Detailansicht mit Match-Begründung, alternativen Quellen und möglichen Aktionen.

### Adoption

- Vorschau der noch nicht von Homebrew verwalteten, aber sicher zugeordneten Apps.
- Einzelauswahl vor jeder Batch-Adoption.
- Ausschluss unsicherer oder widersprüchlicher Matches aus der Vorauswahl.
- Ausführung über strukturierte Prozessargumente, nicht über einen Shell-String.
- Fortschritt und Ergebnis pro App; ein Fehler stoppt nicht zwingend unabhängige
  Folgeaktionen, wird aber sichtbar und wiederholbar.
- Kein automatisches Löschen oder Ersetzen außerhalb des von Homebrew vorgesehenen
  Ablaufs.

### Updates

- Homebrew-Casks werden einschließlich `auto_updates` und `latest` berücksichtigt.
- Mac-App-Store-Apps werden über `mas` aktualisiert.
- Microsoft-Apps können über `msupdate` aktualisiert werden.
- Selbst-updatende Apps werden standardmäßig nur angezeigt.
- Nutzerfreigabe vor einer Updategruppe und sichtbarer Status pro App.
- Nach jeder Aktion erfolgt ein erneuter lokaler Scan statt einer optimistischen
  Erfolgsannahme.
- Major-Upgrades werden gesondert gekennzeichnet und nicht mit regulären Updates
  vermischt, da sie Lizenz, Dateiformate oder Systemvoraussetzungen ändern können.
  Sie erfordern eine eigene Bestätigung mit sichtbarer Begründung.
- Prüfergebnisse werden mit Zeitstempel zwischengespeichert, damit ein Neustart der
  App keine vollständige Netzwerkprüfung auslöst. Das Cache-Alter ist sichtbar und
  manuell invalidierbar.

### Ignorierlisten

- Apple-eigene und über MDM verwaltete Apps stehen auf einer System-Ignorierliste und
  erscheinen nicht als Handlungsvorschlag.
- Der Nutzer kann eine App dauerhaft ignorieren oder eine einzelne Version
  überspringen.
- Ignorierte Einträge bleiben einsehbar und rücknehmbar; sie werden nicht still
  verborgen.

### Katalog und Neuinstallation

- Lokaler Cache des Cask-Katalogs und der 365-Tage-Installationsstatistik.
- Suche über Token, Anzeigename und Beschreibung.
- Sortierung nach Popularität und Name; weitere Filter können später folgen.
- Detailansicht mit Quelle, Homepage, Version und relevanten Artefakten.
- Installation ausschließlich nach Vorschau und expliziter Bestätigung.

### Vertrauensspeicher

- Persistenz der beobachteten Team ID pro Bundle-ID mit Zeitstempel und Herkunft.
- Protokoll explizit bestätigter Team-ID-Wechsel.
- Lösch- oder Reset-Möglichkeit für gespeicherte Vertrauensentscheidungen.
- Keine automatische Freigabe bei fehlender Signatur, Gatekeeper-Ablehnung oder
  unerwartetem Team-ID-Wechsel.

## Nicht-funktionale Anforderungen

- Native macOS-App in Swift und SwiftUI; Ziel zunächst macOS 14+ auf Apple Silicon.
- Swift-6-kompatibler, nebenläufigkeitssicherer Kern.
- Lange Scans, Netzwerkanfragen und Paketprozesse blockieren nicht den Main Thread.
- Ein abgebrochener oder fehlgeschlagener Prozess hinterlässt einen nachvollziehbaren
  Zustand und keine Erfolgsmeldung.
- Netzwerkantworten werden mit Zeitlimits, Größenlimits und expliziten Fehlern
  verarbeitet.
- Externe Befehle werden ausschließlich mit festen Executable-Pfaden beziehungsweise
  validierter Tool-Auflösung und separaten Argumentlisten gestartet.
- Kernlogik bleibt von SwiftUI getrennt und headless testbar.
- Katalog- und Analyseantworten werden lokal gecacht; Herkunft und Abrufzeit sind
  sichtbar.
- Diagnoseprotokolle enthalten keine unnötigen personenbezogenen Daten und keine
  geheimen Werte.
- Barrierefreiheit, Tastaturnavigation und VoiceOver-Bezeichnungen werden für alle
  primären Aktionen berücksichtigt.

## Sicherheitsanforderungen

- Kein privilegierter, dauerhaft laufender Helper in v1.
- Keine Shell-Interpolation für Toolaufrufe.
- Keine automatische Aktion aufgrund eines reinen Fuzzy-Namensmatches.
- Signatur- und Gatekeeper-Prüfung vor einem von OpenFreshr ausgeführten Ersatz.
- Team-ID-Wechsel ist ein blockierender Vertrauenskonflikt mit explizitem Opt-in.
- Homebrew übernimmt seine eigenen Checksummen-, Quarantäne- und Installerprüfungen;
  OpenFreshr stellt deren Ergebnis nicht als eigenen Sicherheitsnachweis dar.
- Appcast- und Katalogdaten gelten als nicht vertrauenswürdige Eingaben und werden
  defensiv geparst.
- URLs dürfen nur über unterstützte sichere Protokolle abgerufen werden; Weiterleitungen
  und unerwartete Hosts müssen nachvollziehbar bleiben.
- Die App zeigt vor einer Aktion den tatsächlichen Backend-Bezeichner und die
  betroffene lokale App.
- Fehlende oder mehrdeutige Bundle-Identität führt zu manueller Klärung, nicht zu
  einem stillen Fallback.
- Release-Artefakte werden per Developer ID signiert, notarisiert und gestapelt.
- Der Release-Prozess soll dem bestehenden Muster der anderen Apps folgen:
  secretloser Build und Preflight, getrennte Signierung mit menschlicher Freigabe
  über den Notarisierungs-Broker.

## Datenmodell und Module

Die Architektur soll wenige tiefe, unabhängig testbare Module bilden:

- **Inventory:** scannt App-Bundles und liefert normalisierte installierte Apps,
  ohne Paketmanagerwissen.
- **Source Catalog:** lädt und normalisiert Cask-, MAS-, MAU- und Sparkle-Metadaten.
- **Resolver:** erzeugt nachvollziehbare Quellenkandidaten samt Match-Art,
  Konfidenz und Konflikten.
- **Versioning:** vergleicht herstellerabhängige Versionsdarstellungen konservativ.
- **Trust:** ermittelt Signatur, Team ID und Gatekeeper-Status und verwaltet
  Trust-on-first-use.
- **Package Operations:** bietet eine einheitliche Backend-Schnittstelle für
  Vorschau, Installation, Adoption und Update.
- **Application Model:** orchestriert Scan, Aktualisierung, Aktionen und
  Fehlerzustände für die UI.
- **Catalog Experience:** Suche, Popularität, Details und Installationsablauf.

Diese Grenzen sind wichtiger als konkrete Dateinamen. Insbesondere dürfen
`PackageBackend` und der lokale Scanner nicht miteinander verschmelzen.

## Akzeptanzkriterien

- [ ] OpenFreshr startet als native macOS-App und zeigt eine installierte Ansicht.
- [ ] Ein Scan findet App-Bundles in allen definierten Verzeichnissen und bleibt
      bei einem unlesbaren Bundle funktionsfähig.
- [ ] Die Referenzdaten ergeben mindestens 100 automatisch zugeordnete Fremd-Apps.
- [ ] Fuzzy-Vorschläge können die Referenzabdeckung auf mindestens 104 Apps erhöhen.
- [ ] Ein absichtlich ähnlich benannter, aber falscher Cask wird nicht automatisch
      übernommen.
- [ ] Ohne Homebrew zeigt die App Bestand, Quellen und Versionsinformationen; nur
      Homebrew-Aktionen sind deaktiviert und begründet.
- [ ] Sicher zugeordnete, nicht verwaltete Casks erscheinen in einer
      Adoption-Vorschau.
- [ ] Der Nutzer kann Apps einzeln auswählen und Adoptionen einzeln nachvollziehen.
- [ ] Jede Adoption wird nach Abschluss durch einen erneuten Scan verifiziert.
- [ ] MAS-, MAU-, Sparkle- und Homebrew-Quellen können gleichzeitig an einer App
      sichtbar sein.
- [ ] Selbst-updatende Apps werden standardmäßig nicht durch OpenFreshr aktualisiert.
- [ ] Ein ungültig signiertes oder von Gatekeeper abgelehntes Bundle wird blockiert.
- [ ] Ein Team-ID-Wechsel wird blockiert, erklärt und nur nach expliziter
      Bestätigung akzeptiert.
- [ ] Der Katalog ist durchsuchbar und kann nach 365-Tage-Popularität sortiert werden.
- [ ] Eine Kataloginstallation zeigt Backend und Token vor der Bestätigung.
- [ ] OpenFreshr kann sich über einen signierten Sparkle-Feed selbst aktualisieren.

## Testentscheidungen

Tests prüfen beobachtbares Verhalten an stabilen Modulgrenzen, nicht private
Implementierungsdetails.

- **Inventory:** temporäre Bundle-Fixtures mit vollständigen, fehlenden und
  beschädigten Plists; MAS-, Sparkle- und Electron-Marker.
- **Resolver:** feste Cask- und App-Fixtures für exakte Namen, Bundle-ID-Treffer,
  Fuzzy-Vorschläge, Mehrdeutigkeit und bekannte Fehlzuordnungen.
- **Versioning:** reale Versionsformen aus dem Referenzscan, einschließlich
  mehrteiliger und nicht rein numerischer Versionen.
- **Trust:** signierte Test-Fixtures beziehungsweise abstrahierte
  Prüfergebnisse für gleiche, geänderte und fehlende Team IDs.
- **Package Operations:** Fake-Backends für Vorschau, Erfolg, Teilfehler, Abbruch
  und Wiederholung; keine Tests sollen reale System-Apps verändern.
- **Source Catalog:** gespeicherte API- und Appcast-Fixtures, damit Tests ohne Netz
  reproduzierbar sind.
- **End-to-End-Smoke-Test:** Scan einer kontrollierten Fixture-Struktur bis zur
  UI-Darstellung und simulierten Adoption.

Das vorhandene Muster der Vergleichsprojekte wird übernommen: Kernlogik wird in
einem separat testbaren Swift-Package beziehungsweise Core-Modul gehalten; Tests
laufen headless. Das Xcode-Projekt wird aus einer deklarativen `project.yml`
generiert und für den reproduzierbaren Release-Build eingecheckt.

## Stand der Technik

Zwei aktive Open-Source-Projekte verfolgen einen ähnlichen Zweck. Beide wurden am
29.08.2026 geprüft, um Doppelarbeit zu vermeiden.

### chenasraf/OpenUpdater

Swift, MIT, aktiv. Deckt GitHub Releases, Sparkle-Appcasts und direkte Downloads über
**handgepflegte, crowdgesourcte YAML-Rezepte** ab.

Gemessen gegen dieselben 109 Fremd-Apps des Referenzsystems:

| Ansatz | Abgedeckte Apps |
|---|---|
| OpenUpdater: 53 Rezepte | 9 |
| OpenUpdater: Rezepte + automatische Sparkle-Erkennung | 24 (22 %) |
| OpenFreshr: vier bestehende Quellen | 100 (91 %) |

Die Abdeckung von OpenUpdater ist auf dem Referenzsystem eine **echte Teilmenge**: Es
gibt keine App, die OpenUpdater abdeckt und OpenFreshr nicht.

Die Ursache ist strukturell, nicht qualitativ. Ein rezeptbasierter Ansatz reproduziert
das Skalierungsproblem, an dem MacUpdater gescheitert ist: Jede unterstützte App
erfordert dauerhafte manuelle Pflege. OpenFreshr verlagert diese Pflege an Instanzen,
die sie ohnehin leisten — Homebrew, Apple, Microsoft und die Hersteller selbst.

**Übernommene Erkenntnisse:**

- Das deklarative Rezept-Schema (`check` mit JSON-Pfad oder HTML-Pattern, `download`,
  `arch`, `channels`) ist eine gute Lösung für Apps ohne jede automatische Quelle und
  dient als Vorlage für die Fallback-Rezepte in OpenFreshr.
- Die Quellenabstraktion (`AppStoreSource`, `GitHubReleaseSource`, `SparkleSource`,
  `HTTPVersionSource` hinter einem gemeinsamen Manager) bestätigt das hier gewählte
  Backend-Protokoll unabhängig.
- `XPCAuditToken` zeigt die korrekte Validierung des aufrufenden Clients in einem
  privilegierten Helper — Referenz für die spätere Härtungsphase.
- Drei Konzepte werden übernommen: gesonderte Behandlung von Major-Upgrades, ein
  Cache für Prüfergebnisse und eine System-Ignorierliste.

### jakejarvis/versioneer

TypeScript, MIT, frühe Alpha. Ebenfalls ein nativer macOS-App-Updater, jedoch ohne
Installation neuer Apps und ohne Signaturprüfung als Sicherheitsmerkmal.

### Abgrenzung

Zwei Funktionen bietet keines der beiden Projekte und sie bleiben die Kernunterscheidung
von OpenFreshr: **Installation neuer Apps aus einem durchsuchbaren Katalog** und die
**Team-ID-Prüfung vor dem Ersetzen einer App**.

## Nicht-Ziele für v1

- Homebrew Formulae und allgemeine CLI-Tools verwalten.
- Eine eigene native Download-, Entpack-, DMG-, PKG- und Deinstallations-Engine.
- Eine kuratierte Datenbank nach dem Vorbild von MacUpdater.
- Vollständig unbeaufsichtigte Updates ohne Nutzereinblick.
- Ein dauerhaft privilegierter Helper.
- Mac-App-Store-Vertrieb.
- iOS-, iPadOS-, Windows- oder Linux-Unterstützung.
- Unternehmensweite Geräteverwaltung, Richtlinien oder zentrale Telemetrie.
- Automatisches Aktualisieren eingestellter oder nicht zuverlässig zuordenbarer Apps.

Formulae/CLI-Tools und eine native Installations-Engine bleiben mögliche spätere
Erweiterungen, sofern ihr Nutzen die zusätzliche Komplexität rechtfertigt.

## Risiken und offene Punkte

- **Falsche Zuordnung:** Der Rohscan enthält bereits einen plausiblen Fehlkandidaten
  (`Copilot.app` zu `copilot-money`). Fuzzy-Matching muss deshalb erklärbar,
  konservativ und für Aktionen standardmäßig nicht ausreichend sein.
- **Cask-Drift:** Tokens, Artefakte und Maintainerentscheidungen können sich ändern.
  Gespeicherte Zuordnungen brauchen erneute Plausibilitätsprüfung.
- **Versionssemantik:** Hersteller verwenden uneinheitliche Versionsformate.
  „Unbekannt“ ist besser als ein falsches Updateurteil.
- **Homebrew-Verhalten:** `--adopt`, `--greedy` oder JSON-Strukturen können sich
  ändern. Toolversion und Fähigkeiten müssen erkannt werden.
- **MAS-Abhängigkeit:** `mas` ist ein separates Tool und kann Authentifizierung oder
  App-Store-Zustand nicht vollständig kontrollieren.
- **MAU-Abdeckung:** Nicht jede App mit Microsoft-Bundle-ID wird zwangsläufig durch
  MAU verwaltet. Erkennung muss gegen `msupdate` bestätigt werden.
- **Sparkle-Feeds:** Feeds können dynamisch erzeugt, architekturabhängig oder nicht
  öffentlich sein. Ein eingebettetes Framework allein garantiert keinen lesbaren
  Appcast.
- **Laufende Apps:** Austausch aktiver Bundles kann fehlschlagen oder
  inkonsistent werden. v1 benötigt klare Vorbedingungen und Hinweise zum Beenden.
- **TOFU-Grenze:** Eine bereits kompromittierte Erstinstallation wird als
  Ausgangsvertrauen gespeichert. Die UI muss diese Semantik klar benennen.
- **Team-ID-Wechsel:** Legitime Übernahmen oder neue Signierzertifikate können
  Warnungen erzeugen. Der Ausnahmeablauf darf nicht banalisiert werden.
- **Apple-Apps:** `softwareupdate` bleibt zunächst Erkennungsquelle; konkrete
  Ausführung und UX müssen separat validiert werden.
- **Lizenz:** MIT, siehe [LICENSE](../LICENSE). Entschieden am 29.08.2026.
- **Produktname:** Geprüft am 29.08.2026. Der ursprüngliche Arbeitstitel `OpenUpdatr`
  kollidierte mit [chenasraf/OpenUpdater](https://github.com/chenasraf/OpenUpdater)
  (Swift, MIT, aktiv, gleicher Zweck) und wurde deshalb zu `OpenFreshr` geändert.
  GitHub und npm sind für den neuen Namen frei. Eine markenrechtliche Prüfung steht
  vor einer kommerziellen Nutzung weiterhin aus.

## Rollout

Die Umsetzung folgt vertikalen Tracer Bullets. Die erste Phase liefert bereits den
zentralen Aha-Moment: vorhandene Apps werden erkannt und können kontrolliert in die
Homebrew-Verwaltung übernommen werden. Spätere Phasen ergänzen echte Updates,
Sicherheitsdurchsetzung, Kataloginstallation, zusätzliche Komfortfunktionen und
schließlich den gehärteten Direktvertrieb.

Details stehen in [PLAN.md](PLAN.md).
