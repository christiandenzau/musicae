# Musicae — Lokale Audio-/Ähnlichkeitsanalyse: Stand, Strategie, offene Fragen

> Arbeitsdokument für ein konzeptionelles Sparring. Es beschreibt **vollständig und
> selbsterklärend** (ohne Code-Zugriff), was Musicae heute misst, was funktioniert,
> was nicht, was schon versucht wurde und welche Bausteine noch ungenutzt sind.
> Ziel des Sparrings: **konzeptionell weiterdenken**, welche lokalen Wege wir noch
> gehen können.

---

## 1. Das Ziel

**Musicae** ist ein lokaler Musikplayer (macOS, Swift/SwiftUI, Fork von Petrichor) mit
einer persönlichen, **Eurodance-lastigen** Bibliothek (~840 Titel in der Testscheibe,
viele 90er-Compilations). Kernfeature: **„Ähnliche Titel"** zu einem Ankertitel — und
eine ehrliche, filterbare Empfehlung.

Zwei feste Leitprinzipien:

1. **Komplett lokal / offline.** Keine Cloud-Analyse, keine externen KI-Dienste zur
   Laufzeit. Alles läuft on-device (Accelerate/vDSP, perspektivisch Core ML /
   SoundAnalysis / Apple-Foundation-Modell). Einmalige Online-Anreicherung (MusicBrainz)
   ist erlaubt, aber die Empfehlung selbst muss offline funktionieren.
2. **Ehrlichkeitsgesetz: Neigung statt Fakten.** Lieber wenige passende Vorschläge als
   viele mit Füllsel. Was wir nicht sicher wissen, zählt **neutral**, nie als behauptete
   Wahrheit. „Neigt wahrscheinlich zu Dance" — nicht „ist Dance".

**Das konkrete Kernproblem:** Wähle ich einen Pop-/Rock-Titel als Anker, sollen keine
Eurodance-/Techno-Fremdkörper in der Ähnlichkeitsliste stehen — und umgekehrt. Die
Bibliothek ist überwiegend Dance; Nicht-Dance-Titel sind die Minderheit, die leicht in
einer Dance-Nachbarschaft „ertrinkt".

---

## 2. Was heute läuft (implementierte Architektur)

Je Titel wird **einmal lokal ein Fingerprint berechnet** (BPMKit, ein Swift-Package auf
Accelerate/vDSP) und in einer Tabelle `track_fingerprints` (1:1 an den Track gekoppelt)
persistiert. Ein resumabler Hintergrundlauf analysiert die ganze Bibliothek; eine
Analyzer-Versionsnummer stößt bei Bedarf eine Re-Analyse an.

**Die heute berechneten Achsen (rein aus Wellenform + FFT, kein Modell):**

| Achse | Bedeutung | Quelle |
|---|---|---|
| `calculated_bpm` | Tempo (nativer Schätzer, Band 70–180, perzeptuelle Gewichtung gegen Oktavfehler) | Onset-Autokorrelation |
| `bpm_confidence` | wie **klar** ein Beat erkennbar ist (0–1) | rohe Autokorrelationsstärke |
| `beat_regularity` | wie **loopregelmäßig** der Rhythmus ist (0–1) — *neu, s. §5* | Autokorr-Peak der Onset-Hüllkurve im Takt-Fenster, bei 22 kHz |
| `rms_loudness_db` | Gesamtlautheit (dBFS) | RMS |
| `dynamic_range_db` | Streuung der kurzzeitigen Lautheit (laut/leise-Wechsel) | Kurzzeit-RMS-Stddev |
| `spectral_brightness_hz` | Klangfarbe (energiegewichteter Frequenzschwerpunkt) | FFT-Centroid |
| `bass_ratio` | Anteil der Energie im Tiefton (0–1) | FFT |
| `mix_class` | Extended / Radio-Edit / Remix / Original | aus dem **Titel** geparst |

**Die Ähnlichkeit** ist eine gewichtete, datensatz-relativ normierte Distanz (kleiner =
ähnlicher), mit einem Cutoff (jenseits dessen nichts gezeigt wird — Ehrlichkeitsgesetz):

```
distance = 3.0·Ära(Jahr) + 2.0·Tempo + 1.5·Dynamik + 1.5·Bass + 1.5·Klangfarbe
         + 1.0·Lautheit + 3.0·Beat-Regelmäßigkeit + 1.0·Beat-Klarheit
         + 1.0·Mix-Art + 1.0·Länge + 2.0·Genre-Familie(weich)
```

Jede Achse zählt **einzeln** (nicht als gemittelte „Energie"), damit sich
stiltrennende Unterschiede addieren. Achsen, für die ein Wert fehlt (z. B. noch nicht
analysiert, unbekanntes Jahr), zählen **neutral**.

**Zusätzliche Faktenschicht (getrennt):** ein **MusicBrainz-Beziehungsgraph** (einmal
online geholt, lokal in eigener DB) — Remixe, Cover-Herkunft, „erscheint auf"-Kanten,
Labels, Release-Gruppen. Wird als Faden am Titel angezeigt, fließt aber (noch) nicht in
die Ähnlichkeitsdistanz ein.

---

## 3. Verfügbare Datenquellen (was wir haben)

**A. Getaggte Fakten (aus den Dateien, teils via Picard/MusicBrainz angereichert):**
- `tracks`: Titel, Künstler, Album, Album-Künstler, **Genre (Einzelstring)**, Jahr,
  Dauer, Compilation-Flag, Format, Pfad.
- Mehrfach-Genres über eine Junction-Tabelle (`track_genres` → `genres`).
- Künstler-Entitäten: `genres` (JSON, oft leer), Land, Gründungsjahr, **MBID**,
  Discogs-/Spotify-/Apple-Music-IDs, Bio.
- Album-Entitäten: `genres` (JSON), Label, Release-Jahr, MBID.
- `extended_metadata` (JSON) je Track: u. a. **Recording-MBID** und (teils) ein
  **AcoustID/Chromaprint-Fingerprint**.

**B. Lokal berechnete Achsen:** die Fingerprint-Tabelle aus §2.

**C. Beziehungswissen:** der MusicBrainz-Graph.

**Qualität der Tags (wichtig!):** Die Genre-Tags in Compilations sind **unzuverlässig** —
oft pauschal („Dance" für alles), leer („Unknown Genre", „Género desconocido") oder
schlicht falsch (Jamiroquai-Funk als „Dance", ein Disney-Swing-Titel als „Dance"). Die
harten Fakten (Titel, Künstler, Jahr, Dauer) sind dagegen solide.

---

## 4. Das Kernproblem, präzise

Wir wollen **Stil/Genre-Nähe** modellieren, damit ein Pop-Anker keine Techno-Nachbarn
bekommt. Zwei Wege, beide für sich unzureichend:

- **Über die Tags:** funktioniert, wo Tags stimmen — aber sie stimmen oft nicht (s. o.).
- **Rein akustisch (DSP):** die naheliegenden Klangfarben-Achsen versagen bei **dieser**
  Bibliothek, weil 90er-Eurodance und 90er-Gitarrenpop **klanglich zu ähnlich** sind:
  beide sind kompakt/dicht gemastert, ähnlich hell, ähnlich laut. Die Ära ist akustisch
  homogen.

Kurz: **Der offensichtliche Trenner (Klangfarbe) trägt hier kaum. Wir brauchen Merkmale,
die den *Stil* fassen, obwohl die *Klangfarbe* gleich aussieht.**

---

## 5. Was wir probiert haben (und was daraus wurde)

Wir gehen empirisch vor. Neue Merkmale werden zuerst **datengetrieben exploriert**
(Python + ffmpeg + numpy: dutzende Kandidaten-Merkmale berechnen, dann nach
**Trennschärfe zwischen Gitarrenrock und Techno** ranken — Cohen's d), und erst das
Gewinner-Merkmal wird nativ in Swift implementiert. Das hat sich sehr bewährt (spart
teure Implementier-Zyklen).

Ergebnisse der Merkmalssuche (Rock vs. Dance, Cohen's d — je größer, desto besser):

| Merkmal | Trennschärfe d | Fazit |
|---|---|---|
| **Beat-/Loop-Regelmäßigkeit** (Autokorr der Onset-Hüllkurve) | **≈ 2.5** | **starker Trenner — eingebaut** |
| spektrale Bandbreite | ≈ 1.3 | mittel (teils redundant mit Helligkeit) |
| Hochfrequenz-Anteil (Becken/Hi-Hats > 6 kHz) | ≈ 1.2 | mittel |
| Crest-Faktor (Dynamik, Peak/RMS) | ≈ 1.1 | mittel (teils redundant mit Dynamik) |
| spektraler Kontrast (Peaks vs. Täler) | ≈ 1.1 | mittel |
| Zero-Crossing-Rate | ≈ 0.7 | schwach |
| Beat-Klarheit `bpm_confidence` (schon vorhanden) | ≈ 0.9 | schwach–mittel |
| **spektrale Flachheit** | ≈ 0.35 | zu schwach |
| **HPSS-Verhältnis** (harmonisch/perkussiv, Median) | **≈ 0.03** | **nutzlos hier** |

**Zwei zentrale Erkenntnisse:**

1. **Klangfarben-/Timbre-Merkmale trennen diese Ära nicht** (HPSS, Flachheit, auch
   MFCC-artig dürften daran scheitern). Auch eine höhere Analyserate (22 kHz statt 11 kHz,
   damit Becken/Hi-Hats sichtbar werden) rettete Timbre nicht.
2. **Der echte Trenner ist die rhythmische Struktur:** Techno/Dance ist
   **maschinell-loopregelmäßig**, echtes Schlagzeug **menschlich-variabel**. Die
   Beat-Regelmäßigkeit (Autokorrelation der Onset-Energie über mehrere Takte) misst genau
   das und trennt massiv.

**Zwei umgesetzte Achsen aus dieser Linie:**
- **Genre-Familie (weich, tag-basiert):** grobe Normalisierung von `tracks.genre` auf
  Familien (dance/rock/pop/hiphop/schlager/klassik …); gleiche Familie = kein Beitrag,
  andere = Strafe, unbekannt = neutral. Löst den getaggten Fall (an der Testscheibe:
  13→0 Dance-Fremdkörper bei einem Pop-Anker), hilft aber nicht bei falschen/leeren Tags.
- **Beat-Regelmäßigkeit (akustisch, tag-unabhängig):** ergänzt die Genre-Familie für
  die falsch/nicht getaggten Fälle (echte Techno-Fremdkörper 11→4; die verbleibenden
  „Dance"-Titel sind falsch getaggter Funk/Swing, den die Achse *korrekt* als
  rhythmisch verwandt einstuft — hier ist sie ehrlicher als der Tag).

**Bewusst verworfen:** neuronale Quellentrennung (Demucs o. Ä.) — zu schwer, und wir
brauchen die *Neigung*, nicht die diskrete Stem-Trennung.

---

## 6. Aktueller Stand / Ergebnis

Spürbar besser: Bei einem Pop-Anker sind statt einer stark Dance-durchsetzten Liste jetzt
**~80 % passende Treffer** (Nutzer-Rückmeldung), Rest ~20 %. Vorher war es deutlich
schlechter. Der Fortschritt kommt aus dem Zusammenspiel: Ära + Tempo + einzelne
Klang-Achsen + **Beat-Regelmäßigkeit** + weiche **Genre-Familie**.

**Es ist also kein einzelnes Wundermerkmal, sondern eine Fusion mehrerer schwacher/mittel-
starker Signale.** Genau hier vermuten wir das größte Restpotenzial.

---

## 7. Was wir noch NICHT genutzt haben (Ideenraum)

**A. Weitere billige DSP-Achsen** (die Exploration zeigte mittlere Trennschärfe):
Hochfrequenz-/Becken-Anteil, spektraler Kontrast, Crest-Faktor, spektrale Bandbreite,
Onset-Dichte, **Chroma/Tonart-Merkmale** (Harmonik — noch gar nicht gemessen),
Tempo-Stabilität über die Zeit.

**B. Gelernte, lokale Modelle (Core ML / Create ML):**
- **`MLSoundClassifier` (Create ML)** — ein eigenes, on-device trainiertes
  Genre-Modell, gebootstrappt aus den **gut/eindeutig getaggten** Titeln der eigenen
  Bibliothek (Tag = Label; die Achsen prüfen danach das Tag und markieren Ausreißer).
- **Apple `SoundAnalysis` (`SNClassifySoundRequest`)** — Apples eingebauter, lokaler
  Audio-Klassifikator; ggf. als Feature-Extraktor/Embedding nutzbar.
- **Gelernte Genre-Zentroide** im Merkmalsvektor (Durchschnitt je Familie), Titel wird
  der nächsten Neigung + Konfidenz zugeordnet.

**C. Das lokale Foundation-Modell (Apple Intelligence, on-device LLM):**
- Aus **(Künstler, Titel, Album, Jahr)** das Genre/den Stil ableiten — das LLM trägt
  Weltwissen („2 Unlimited → Eurodance", „Soul Asylum → Alternative Rock"), ganz ohne
  Netz. Als **weiches, konfidenzbehaftetes** Zusatzsignal, das v. a. falsche/leere Tags
  reparieren könnte.
- Denkbar auch: das LLM als Fusions-/Schlichtungsinstanz über die vielen schwachen
  Signale.

**D. Vorhandene, ungenutzte Fakten:**
- **MusicBrainz-Graph** fließt noch nicht in die Distanz ein (gemeinsames Label,
  gemeinsame Release-Gruppe, Remix-Verwandtschaft = starke „gehört zusammen"-Kanten).
- **Künstler-Ebene:** dieselbe Künstlerin ⇒ meist derselbe Stil (billiges, starkes
  Prior); Künstler-`genres`/Land/Ära.
- **AcoustID/Chromaprint** ist vorhanden (bisher nur Identität, nicht Ähnlichkeit).

**E. Fusion / Kalibrierung:** Die Gewichte der Distanz sind heute von Hand gesetzt. Eine
**gelernte Gewichtung** (aus wenigen Nutzer-Rückmeldungen „passt / passt nicht" —
lokales, leichtes Ranking-Lernen) könnte die vielen schwachen Signale optimal
kombinieren, statt sie zu raten.

---

## 8. Die offene Frage

Wir haben einen soliden, ehrlichen Kern (mehrere DSP-Achsen + Beat-Regelmäßigkeit +
weiche Genre-Familie) und ~80 % Trefferqualität. **Wie kommen wir konzeptionell auf die
nächste Stufe — komplett lokal?** Insbesondere:

- Welche der ungenutzten Bausteine (weitere DSP-Achsen? Chroma/Harmonik? `MLSoundClassifier`?
  `SoundAnalysis`-Embeddings? das lokale Foundation-Modell für Tag-Reparatur? der
  MusicBrainz-Graph? gelernte Gewichte?) versprechen am meisten Hebel — und **warum**?
- Gibt es einen **grundsätzlich anderen Rahmen**, den wir übersehen (z. B. ein gelerntes
  lokales Audio-Embedding statt handgewählter Achsen; oder eine Signal-Fusion mit
  Konfidenzen statt einer festen Gewichtssumme)?
- Wie halten wir dabei das **Ehrlichkeitsgesetz** (Neigung + Konfidenz, neutral bei
  Unwissen) sauber ein?
