# bpmdetect — native Audio-Analyse & Beziehungsgraph

Phase 2–4 des [Musicae-Umsetzungsplans](../../docs/Musicae_Umsetzungsplan.md). Ein eigenständiges Swift-Kommandozeilen-Werkzeug, das mit den Phasen wächst: erst rechnet es die Audio-Achsen eines Titels **nativ** (AVFoundation zum Laden, Accelerate/vDSP für FFT/Statistik), dann fragt es sie ab, und schließlich holt es die relationale Schicht über die MusicBrainz-Web-API. GRDB trägt durchgehend die Persistenz.

- **Phase 2 · Teil 1 ([#4](https://github.com/christiandenzau/musicae/issues/4)):** Tempo (BPM) per spektralem Fluss + Autokorrelation — das *riskante* Stück, zuerst.
- **Phase 2 · Teil 2 ([#5](https://github.com/christiandenzau/musicae/issues/5)):** die leichten Achsen (Lautheit, Dynamik, Helligkeit, Bass-Anteil) plus die aus dem Titel geparste Mix-Version, je Track als **Fingerprint-Zeile** persistiert.
- **Phase 3 ([#6](https://github.com/christiandenzau/musicae/issues/6)):** der überzeugende Moment — **präzise Abfrage** (kombinierbare Filter) und **Nachbarvorschlag** auf der Fingerprint-Tabelle. Reine Filter, keine KI, keine Cloud.
- **Phase 4 ([#7](https://github.com/christiandenzau/musicae/issues/7)):** die relationale Schicht — ein **ratenbegrenzter MusicBrainz-Client** holt für die MBIDs der Scheibe Fakten und Beziehungen (Jahr, Label, Remix-von, Cover-von, erscheint-auf) und legt sie als **Kantengraph** ab, der sich begehen lässt.

Es ist bewusst ein separates SwiftPM-Paket, kein App-Target: Die Audio-Analyse ist das *riskante* Stück, also wird sie zuerst und isoliert verifizierbar gebaut — mit `swift build`/`swift test`, unabhängig von Xcode und der App. Dieselbe reine `BPMKit`-Logik wandert später unverändert in die App.

## Warum das zuerst

Trifft der Schätzer nicht zuverlässig, wackelt eine tragende Achse der späteren Empfehlung. Genau das will man an Tag eins wissen, nicht nachdem die ganze Maschine steht. Siehe [Datenmodell & Empfehlungslogik](../../docs/Musicae_Datenmodell_und_Empfehlungslogik.md), §2: BPM gilt für Viervierteltakt-Dance als robust rechenbar — die klassische Falle ist allein der Oktavfehler (70 gegen 140).

## Der Algorithmus

Der klassische, robuste Weg in drei Schritten:

1. **Laden & Vereinheitlichen** — Datei via `AVAudioFile` lesen, über `AVAudioConverter` zu **Mono, 11025 Hz, Float32** wandeln. Niedrig genug, dass die FFT billig bleibt; hoch genug für den Bass- und Mittenbereich, der den Beat trägt.
2. **Onset-Hüllkurve über spektralen Fluss** — kurze Fenster (1024 Samples, Hann), Hop 128 (→ ~86 Hz Hüllkurven-Rate), reelle FFT per `vDSP_fft_zrip`. Pro Frame die Summe der *positiven* Magnitudenzuwächse gegenüber dem Vorframe: Schläge erzeugen Energiesprünge, die Hüllkurve macht sie sichtbar.
3. **Tempo per Autokorrelation** — die Schlagperiode ist der Lag, bei dem sich die Hüllkurve am ähnlichsten ist. Die Suche ist **von vornherein auf das Band 120–150 BPM** eingegrenzt (Eurodance), womit der Oktavfehler gar nicht erst entstehen kann. Eine parabolische Interpolation um den Autokorrelations-Peak liefert Sub-Frame-Genauigkeit.

Als Härtung (AK6) kann der spektrale Fluss auf **Bass/untere Mitten** fokussiert werden (`--bass`), wo bei elektronischer Musik die Kick sitzt.

Der Kern (`BPMKit`) ist rein und I/O-frei — er rechnet auf `[Float]` plus Samplerate und ist damit gegen synthetische Signale mit exakt bekanntem Tempo testbar.

## Nutzung

```sh
# Einzelne Datei
swift run --package-path Tools/BPMDetector bpmdetect /pfad/zum/titel.mp3

# Ganzer Ordner (Testmodus): je Datei der geschätzte BPM, plus Abgleich
# gegen den im Tag hinterlegten BPM, falls vorhanden
swift run --package-path Tools/BPMDetector bpmdetect /pfad/zum/ordner

# Eingebauter Selbsttest gegen synthetische Beats (ohne Audiodateien)
swift run --package-path Tools/BPMDetector bpmdetect --selftest

# Fingerprint-Lauf (#5): rekursiv über Albumordner, je Titel BPM + Achsen +
# Mix-Version berechnen und als Zeile in eine SQLite-DB schreiben (GRDB)
swift run -c release --package-path Tools/BPMDetector \
  bpmdetect fingerprint ~/Musik/Eurodance-Testscheibe --db fingerprints.db

# Abfrage (#6): kombinierbare Filter auf der Fingerprint-Tabelle
swift run --package-path Tools/BPMDetector bpmdetect query --db fingerprints.db \
  --year 1995-1996 --mix extended --min-energy 0.6 --duration 5-8

# Nachbarvorschlag (#6): verwandte Titel zu einem Anker
swift run --package-path Tools/BPMDetector bpmdetect neighbors "Another Night" \
  --db fingerprints.db --limit 8

# Beziehungsgraph (#7): für die Recording-MBIDs der Scheibe die MusicBrainz-
# Fakten und Beziehungen holen (ratenbegrenzt) und als Kanten speichern. MBIDs
# aus der Musicae-Bibliothek (schreibgeschützt; bei laufender App eine Kopie):
swift run -c release --package-path Tools/BPMDetector bpmdetect relations \
  --library ~/musicae-kopie.db --db relations.db

# … oder MBIDs direkt / aus einer Datei, ohne Label-Anreicherung:
swift run --package-path Tools/BPMDetector bpmdetect relations \
  --mbids 1e6d5aa6-1da2-4d25-a997-b5dff76537f0 --no-labels --db relations.db

# Den gespeicherten Faden ab einem Titel oder einer MBID begehen (#7):
swift run --package-path Tools/BPMDetector bpmdetect graph "Another Night" \
  --db relations.db --depth 2
```

Optionen: `--db <pfad>` (Ziel-DB; Default `./fingerprints.db` bzw. `./relations.db`), `--bass [hz]` (Onset-Fokus auf Bass/untere Mitten, Default 250 Hz), `--min <bpm>` / `--max <bpm>` (Bandgrenzen, Default 120/150), `--help`. Für `relations`: `--library`/`--mbids-file`/`--mbids` (MBID-Quelle), `--interval <sek>` (Ratenabstand, Default 1.0), `--no-labels`, `--take <n>`, `--contact <str>`. Für `graph`: `--depth <n>`.

### Lokale Toolchain

Ist nur das Command-Line-Tools-Paket aktiv (`xcode-select -p` zeigt `/Library/Developer/CommandLineTools`), kann SwiftPM scheitern. Dann ein vollständiges Xcode voranstellen:

```sh
DEVELOPER_DIR="/Applications/Xcode.app/Contents/Developer" \
  swift test --package-path Tools/BPMDetector
```

## Verifikation

### Synthetischer Selbsttest (reproduzierbar, läuft in CI)

`--selftest` und die Unit-Tests (`swift test`) erzeugen Kick-Pulszüge bei exakt bekanntem Tempo und schicken sie durch die **volle** Pipeline (inkl. echtem WAV-Laden + Resampling im `AudioLoaderTests`). Ergebnis auf dieser Maschine:

| Onset-Band | Tempi (BPM) | größte Abweichung |
|---|---|---|
| voll | 120, 124, 128, 132, 138, 140, 145, 150 | **0,09 BPM** |
| bass ≤ 250 Hz | 124, 128, 132, 140, 150 | **0,07 BPM** |

Konfidenz (normalisierte Autokorrelation am Peak) durchweg 0,95–0,99 für saubere Beats. Das beweist die Korrektheit der Kette FFT → spektraler Fluss → Autokorrelation → Interpolation, unabhängig von Audiomaterial, das in CI nicht liegt.

### Gegen echte Titel mit bekanntem BPM (AK5)

Synthetik beweist den Algorithmus, nicht das Verhalten auf echter Musik (Tempodrift, Synkopen, Halbtakt-Gefühl). Diesen Teil prüft man an der eigenen, sauber getaggten Scheibe — am besten der aus [#3](https://github.com/christiandenzau/musicae/issues/3):

```sh
swift run --package-path Tools/BPMDetector bpmdetect ~/Musik/Eurodance-Testscheibe
```

Der Testmodus stellt **geschätzt vs. getaggt** nebeneinander und fasst die mittlere und maximale Abweichung über alle Titel mit BPM-Tag zusammen. So wird die Tabelle unten gefüllt:

| Titel | getaggt | geschätzt (voll) | geschätzt (`--bass`) | Δ | Anmerkung |
|---|---|---|---|---|---|
| _z. B. Scooter – Hyper Hyper_ | | | | | |
| … (10–20 Titel) | | | | | |

> Noch nicht ausgefüllt: erfordert Zugriff auf die getaggte Bibliothek (läuft lokal, nicht in CI). Ist die Testscheibe aus #3 fertig, wird diese Tabelle in einem Aufwasch befüllt; weicht etwas systematisch ab, ist `--bass` die erste Stellschraube (AK6).

## Phase 2 Teil 2 — Achsen & Fingerprint (#5)

Die übrigen *leichten* Achsen, bewusst die billige, robuste erste Fassung. Sie teilen sich mit dem BPM dieselbe 11025-Hz-Ladung — eine Datei wird genau einmal dekodiert.

| Achse | Wie | Bedeutung |
|---|---|---|
| **RMS-Lautheit** (dBFS) | RMS über das ganze Signal | wie laut das Master insgesamt ist (echtes LUFS ist spätere Verfeinerung) |
| **Dynamikumfang** (dB) | Standardabweichung der kurzzeitigen RMS (50-ms-Fenster) | trennt den durchgehend lauten Track vom Track mit echtem Breakdown/Drop |
| **Spektrale Helligkeit** (Hz) | energiegewichteter Frequenzschwerpunkt (Centroid) über vDSP-FFT | hell/trebly vs. dunkel/bassig — relativer Index bis Nyquist (5512 Hz) |
| **Bass-Anteil** (0…1) | Energieanteil unterhalb 200 Hz | für elektronische Musik identitätsstiftend |

Die **Mix-Version** (Extended, Radio Edit, Club Mix …) wird per Textsuche aus dem Klammerzusatz des Titels geparst — bei Eurodance steckt sie dort, ein strukturiertes Tag-Feld gibt es nicht.

Jeder Track wird zu einer Zeile in der Tabelle `track_fingerprints` (GRDB, **eigene Datei, kein Eingriff in die Musicae-Tabellen**). Schlüssel ist der Dateipfad und deckt sich mit `tracks.path` in Musicae, daher später verlustfrei dorthin joinbar:

```
track_fingerprints(path PK, title, duration_seconds, bpm, bpm_confidence,
  rms_loudness_db, dynamic_range_db, spectral_brightness_hz, bass_ratio,
  mix_version, analyzed_at)
```

**Lauf über die Testscheibe aus [#3](https://github.com/christiandenzau/musicae/issues/3)** (842 Eurodance-Titel, ~82 s, 0 Fehler):

| | Bereich (Ø) |
|---|---|
| Lautheit | −23,6 … −9,3 dBFS (Ø −15,5) |
| Dynamik | 2,7 … 9,9 dB (Ø 5,4) — durchgehend laut, typisch Dance |
| Helligkeit | 795 … 1938 Hz (Ø 1369) |
| Bass-Anteil | 0,10 … 0,55 (Ø 0,24) |
| Mix-Version erkannt | 418 / 842 (radio edit 62, radio version 28, radio mix 23 …) |

## Phase 3 — Abfrage & Nachbarvorschlag (#6)

Der überzeugende Moment: auf der Fingerprint-Tabelle zwei technisch entgegengesetzte Aufgaben.

**Abfrage** — „ich sage genau, was ich will, gib es ohne Müll". Kombinierbare, harte Filter:

| Filter | Flag | Beispiel |
|---|---|---|
| Jahr (Ära) | `--year` | `1995-1996` |
| Länge (Minuten) | `--duration` | `5-8` |
| Mix-Art | `--mix` | `extended` / `radio` / `remix` / `original` |
| Tempo | `--bpm` | `130-150` |
| Energie | `--min-energy` / `--max-energy` | `0.6` |

**Nachbarn** — zu einem Anker die verwandten Titel, geordnet nach einer gewichteten Distanz: **Ära** am schwersten (die Empfehlung soll in der Zeit bleiben), dann **Energie**, dann **Mix-Art** und **Länge**.

Die **Energie** ist keine gespeicherte Achse, sondern relativ zum eigenen Datensatz normalisiert (laut + schnell + basslastig + wenig Dynamik = treibend). „Hohe Energie" heißt hoch *für diese Bibliothek* — ehrlich, ohne fremde Skala.

**Der Beweis** über die Testscheibe aus [#3](https://github.com/christiandenzau/musicae/issues/3):

- *Abfrage* „1995–96, Extended, Energie ≥ 0,6, 5–8 min" → ein präziser Treffer (Captain Hollywood, „Find Another Way (extended mix)"), kein Müll.
- *Nachbarn* zu „Another Night" (Real McCoy, 1995) → Nothing Like the Rain & Do What's Good for Me (2 Unlimited), Everytime You Touch Me (Moby), Run Away (Real McCoy) — alle 1995, gleiche Liga. Keine akustische Zufallsähnlichkeit, sondern die richtige Nachbarschaft.

## Phase 4 — MusicBrainz-Beziehungsgraph (#7)

Erst wenn der Filter aus Phase 3 trägt, kommt die relationale Schicht. Ein schmaler Client holt für die **Recording-MBIDs der Scheibe** über die MusicBrainz-Web-API die Fakten und Beziehungen und legt sie als gerichteten Kantengraph ab — der erste begehbare Faden, z. B. die Maxi zum Album des Jahres.

**Woher die MBIDs kommen.** Die verlässliche Quelle ist die **Musicae-Bibliotheks-DB**: Musicae' Metadaten-Leser haben die Recording-MBID längst aus jedem Tag-Format gezogen und im `extended_metadata`-JSON als `musicBrainzTrackId` abgelegt (Schema-Karte §6). `--library` liest dieses fertige Ergebnis **schreibgeschützt** aus, statt das fehleranfällige Tag-Parsen zu wiederholen. Alternativ `--mbids-file` / `--mbids`.

**Ratenbegrenzung.** MusicBrainz duldet im Schnitt ~1 Anfrage/Sekunde je Client und verlangt einen aussagekräftigen User-Agent. Beides ist eingebaut: ein `RateLimiter` (Actor) erzwingt den Abstand über alle Anfragen, der User-Agent trägt den `--contact`.

**Zwei Tabellen, eigene Datei** (`relations.db`, kein Eingriff in die Musicae- oder Fingerprint-Tabellen):

```
mb_entities(mbid PK, kind, title, artist, year, label, primary_type)
mb_relations(source_mbid, target_mbid, relation, target_kind, PK(source,target,relation))
```

Knoten werden beim Schreiben *gemergt*: der zweite Schritt reichert die entdeckten Releases mit **Label** und **Release-Gruppe** an, ohne früher gesetzte Fakten zu verlieren. Beziehungen tragen die ehrliche Richtung (MusicBrainz' `direction`): „backward" heißt, die Aufnahme ist das *abgeleitete* Werk — daher „remix of", „cover of".

**Der Faden** über eine echte Aufnahme (Real McCoy — „Another Night", 1995), ein Lauf mit Label-Anreicherung:

```
Anker: Another Night — Real McCoy (1995) [recording]

  → appears on   Wow that's a Hit (1995) [release · Startel Entertainment]
  → appears on   The Greatest No. 1 Hits of the 90's (1996) [release · Startel Entertainment]
  → performance  Another Night [work]
    → release of   Wow that's a Hit (1995) [release-group · Album]
    → release of   The Greatest No. 1 Hits of the 90's (1996) [release-group · Album]
```

Die Aufnahme → die Tonträger (mit Label und Jahr) → die Release-Gruppen (das „Album", Tiefe 2), plus die Werk-Beziehung. Ein kleiner, begehbarer Graph.

**Verifikation.** Der Kern ist netzfrei geprüft: das JSON→Graph-Mapping, die lesbaren Beziehungslabels, das Jahr-Parsing, der Kantenspeicher (inkl. Merge-Semantik) und die Traversierung laufen gegen JSON-Fixtures und einen HTTP-Stub, der Ratenabstand gegen die Uhr (`swift test`). Der echte API-Weg ist mit dem Lauf oben einmal live bestätigt.

## Aufbau

```
Tools/BPMDetector/
  Sources/BPMKit/            reine Logik (unit-testbar) + Persistenz
    RealFFT.swift              vDSP-FFT-Wrapper
    BPMEstimator.swift         spektraler Fluss + Autokorrelation (#4)
    AudioAxes.swift            Lautheit, Dynamik, Helligkeit, Bass (#5)
    MixVersion.swift           Mix-Version aus dem Titel parsen (#5)
    FingerprintStore.swift     GRDB-Tabelle track_fingerprints (#5/#6)
    FingerprintQuery.swift     Abfrage + Nachbarvorschlag (#6)
    AudioLoader.swift          AVAudioFile → Mono 11025 Hz
    ClickTrackGenerator.swift  synthetische Beats für den Selbsttest
    MusicBrainzModels.swift    WS/2-JSON-DTOs (Recording/Release/Beziehung) (#7)
    MusicBrainzClient.swift    ratenbegrenzter API-Client + RateLimiter (#7)
    RelationGraph.swift        JSON→Graph-Mapping + begehbare Traversierung (#7)
    RelationStore.swift        GRDB-Tabellen mb_entities/mb_relations (#7)
    RelationIngestor.swift     Orchestrierung: holen → falten → speichern (#7)
    LibraryMBIDReader.swift    Recording-MBIDs aus der Musicae-DB lesen (#7)
  Sources/bpmdetect/         CLI (Datei/Ordner/Selbsttest/Fingerprint/Query/
                             Neighbors/Relations/Graph)
  Tests/BPMKitTests/         XCTest: Beats, Achsen, Mix, Store, Query, Nachbarn,
                             Graph-Mapping, Kantenspeicher, Client/Rate-Limit/Ingest
```
