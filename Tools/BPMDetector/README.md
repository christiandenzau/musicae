# bpmdetect — nativer BPM-Schätzer

Phase 2 (Teil 1) des [Musicae-Umsetzungsplans](../../docs/Musicae_Umsetzungsplan.md), Issue [#4](https://github.com/christiandenzau/musicae/issues/4). Ein eigenständiges Swift-Kommandozeilen-Werkzeug, das das Tempo (BPM) eines Titels **nativ** schätzt — ohne Fremdbibliotheken, nur AVFoundation (Laden) und Accelerate/vDSP (Rechnen).

Es ist bewusst ein separates SwiftPM-Paket, kein App-Target: Das Tempo-Tracking ist das einzige *riskante* Stück der Audio-Analyse, also wird es zuerst und isoliert verifizierbar gebaut — mit `swift build`/`swift test`, unabhängig von Xcode und der App.

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
```

Optionen: `--bass [hz]` (Onset-Fokus auf Bass/untere Mitten, Default 250 Hz), `--min <bpm>` / `--max <bpm>` (Bandgrenzen, Default 120/150), `--help`.

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

## Aufbau

```
Tools/BPMDetector/
  Sources/BPMKit/            reine Logik (unit-testbar)
    RealFFT.swift              vDSP-FFT-Wrapper
    BPMEstimator.swift         spektraler Fluss + Autokorrelation
    AudioLoader.swift          AVAudioFile → Mono 11025 Hz
    ClickTrackGenerator.swift  synthetische Beats für den Selbsttest
  Sources/bpmdetect/         CLI-Frontend (Datei-/Ordner-/Selbsttest-Modus)
  Tests/BPMKitTests/         XCTest gegen synthetische Beats + echtes WAV
```
