# Musicae — Audioanalyse: Befunde & Roadmap (Stand nach Fable-5-Sparring)

> Synthese aus dem konzeptionellen Sparring mit Fable 5 (siehe
> [`Musicae_Audioanalyse_Konzept_und_offene_Fragen.md`](Musicae_Audioanalyse_Konzept_und_offene_Fragen.md))
> **plus** eigener Verifikation an der echten Testscheibe (842 Titel). Dieses
> Dokument hält die belegten Erkenntnisse fest und leitet daraus eine priorisierte
> Roadmap ab. Zahlen sind an den Daten gemessen, nicht geschätzt.

---

## 1. Der Kern-Reframe (von Fable 5)

Was heute wie *ein* Problem aussieht („Fremdkörper in der Liste"), sind **zwei**
Aufgaben, die die eine gewichtete Distanzsumme gleichzeitig lösen muss:

1. **Gating** — gehört der Kandidat überhaupt zur Stilfamilie des Ankers? (Ja/Nein/Unbekannt)
2. **Ranking** — wie nah ist er *innerhalb* der Familie? (feine Abstufung)

Weil beides in einer Summe steckt, kann ein Fremdkörper eine **große Stil-Strafe
durch viele kleine Übereinstimmungen** (Ära, Tempo, Lautheit, Länge) „abarbeiten" und
unter den Cutoff rutschen. Die eigentlich gesuchte latente Variable ist nicht
„Klangfarbe", sondern der **Produktionsprozess** (sequenziert vs. gespielt) — deshalb
war die Beat-Regelmäßigkeit (#23) der stärkste Fund.

---

## 2. Verifizierte Befunde (an 842 Titeln gemessen)

**A. #22 + #23 lösen den *getaggten* Fall vollständig.** Über **alle 173 Pop-Anker**
mit der kombinierten Engine (Genre-Familie + Beat-Regelmäßigkeit): **0 %
Dance-*getaggte* Fremdkörper**, keine Hubness. Die früher genannten „~20 %" waren ein
grober Bauchwert vom **alten Build ohne #22/#23** — nicht gemessen. **Konsequenz:**
Der erste, billigste Gewinn ist, #22/#23 überhaupt zu **aktivieren** (mergen +
App-Neustart, Re-Analyse).

**B. Die echte Restschwäche sind leer/falsch getaggte Titel.** Der Genre-Tag ist bei
**43,7 %** der Pop-Nachbarn leer („Unknown Genre"); davon sind **15,6 %** der
Nachbar-Slots akustisch dance-verdächtig (Beat-Regelmäßigkeit ≥ 0,75). Für sie zählt
die Genre-Achse **neutral** — sie rutschen durch. Und hier **existiert die Hubness
sehr wohl**:

```
25×  Real McCoy      – Love & Devotion   beat 0.85  [Unknown Genre]
23×  sweetbox        – Booyah             beat 0.76  [Unknown Genre]
22×  Dominica        – Gotta Let You Go   beat 0.83  [Unknown Genre]
19×  DJ BoBo         – Everybody          beat 0.76  [Unknown Genre]
18×  Mark 'Oh        – Fade to Grey       beat 0.81  [Unknown Genre]
17×  Culture Beat    – Take Me Away       beat 0.80  [Unknown Genre]
```

Das sind **kanonische Eurodance-Acts, alle „Unknown Genre"**. Real McCoy taucht in 25
verschiedenen Pop-Nachbarschaften auf — ein klarer Hub.

**C. Die BPM-Erkennung ist bei langsamem/HipHop-Material unzuverlässig.** Beispiel
**Bone Thugs-n-Harmony – „Crossroad"** (90er-US-HipHop, real ~90 BPM): gemessen **132
BPM bei nur 49 % Confidence**, „Unknown Genre". Der *falsche* BPM zieht den Titel zu
echten 132-BPM-Eurodance-Titeln (2 Unlimited, Captain Hollywood). Dämpft man die
Tempo-Achse mit der BPM-Confidence, steigen sofort die **echten** HipHop-Nachbarn
(Fettes Brot 83 BPM, Rödelheim Hartreim Projekt 97 BPM) nach oben. Die niedrige
Confidence ist also ein **ungenutztes Signal**.

---

## 3. Priorisierte Roadmap

Reihenfolge nach **Hebel ÷ Aufwand**, jeweils mit Beleg. Grün = billiger Quick-Win.

### Stufe A — Quick-Wins (Tage, an bestehender Engine)

**A1 · #22 + #23 aktivieren.** Mergen, App-Neustart, Re-Analyse. Der größte Sofort-Effekt,
weil er bereits gebaut ist. *Beleg: 0 % getaggte Fremdkörper (§2A).*

**A2 · Confidence-gewichtete Tempo-Achse.** Tempo-Beitrag mit `min(conf_anker, conf_kandidat)`
skalieren — ein unsicherer BPM erzeugt weder Nähe noch Ferne, sondern zählt neutral
(Ehrlichkeitsgesetz, sauber). *Beleg: der Crossroad-Fall (§2C) — echte HipHop-Nachbarn
steigen sofort.* Klein.

**A3 · Hubness-Korrektur.** Lokale Distanzskalierung (durch die Distanz zum k-nächsten
Nachbarn des Ankers teilen) **oder** nur wechselseitige Nachbarn zulassen (X zählt nur,
wenn der Anker auch in X' Nachbarschaft liegt). Featureunabhängig, kostet fast nichts.
*Beleg: Real McCoy als 25×-Hub (§2B).*

### Stufe B — Der große Hebel

**B1 · Genre-Reparatur auf Künstler-Ebene** (Fable 5 Rang 1). Stil ist in dieser Ära fast
vollständig eine **Künstler**-Eigenschaft. Genre je Künstler bestimmen, absteigend nach
Verlässlichkeit: (a) MusicBrainz-Künstler-/Release-Group-Genre einmalig nachziehen (MBIDs
vorhanden, Anreicherung erlaubt), (b) Mehrheitsvotum über alle Vorkommen desselben
Künstlers in der eigenen Bibliothek, (c) **lokales Foundation-Modell** als Lückenfüller
(„2 Unlimited → Eurodance"). Ergebnis: Familie **plus Konfidenz** je Künstler; speist die
bestehende weiche Genre-Achse. Widerspruch zwischen Quellen ⇒ neutral. *Beleg: 15,6 %
leer-getaggte Eurodance-Acts (§2B) + Crossroad „Unknown Genre" (§2C) — genau das wird
repariert.* Größter belegter Hebel.

### Stufe C — Akustik vertiefen (DSP, durch die bewährte Cohen-d-Exploration)

**C1 · Maschinen-Signatur-Bündel** (Fable 5 Rang 2): **Tempo-Drift** über die Titeldauer
(Sequenzer driften nicht, Schlagzeuger schon), **Mikro-Timing** (Onset-Jitter gegen das
Raster; menschliches Spiel 10–30 ms + Swing), **exakte Wiederholung** (Selbstähnlichkeit
über 4/8-Takt-Lags — verallgemeinert die Beat-Regelmäßigkeit auf Textur/Harmonik). Erst
durch die Python/ffmpeg/numpy-Pipeline ranken, Gewinner nativ bauen.

**C2 · BPM-Erkennung robuster machen** (der Crossroad-Oktavfehler). Das Kernproblem hinter
A2: der Schätzer greift bei langsamem, sample-basiertem HipHop den falschen Puls
(Doppeltempo). Kandidaten: bessere Oktav-Auflösung, HipHop-freundliches Suchband,
Onset-Band tiefer legen. Eigenständig, weil ein korrektes Tempo mehreren Achsen hilft.

### Stufe D — Strukturell & Forschung (später, größerer Umbau)

**D1 · Gate + Ranker statt einer Summe** (Fable 5's Reframe). Ein probabilistisches
Stil-Gate fusioniert die stilbestimmenden Signale (Künstler-Familie, Maschinen-Signatur,
Beat-Regelmäßigkeit, ggf. Instrumentierung) als **Likelihood-Verhältnisse** (unbekannt =
Verhältnis 1 = exakt neutral); dahinter rankt die bestehende Distanz mit den feinen
Achsen. Ein starkes Gegensignal kann dann nicht mehr durch viele Nebensächlichkeiten
überstimmt werden. Erst sinnvoll, wenn A–C die Evidenzen liefern.

**D2 · Gelerntes lokales Audio-Embedding** (Fable 5's „unbequemer Rahmen"). „Timbre trennt
nicht" gilt für *handberechnete* Statistik, nicht zwingend für ein gelerntes Embedding
(OpenL3-/CLAP-Klasse, nach Core ML konvertiert, on-device). Als **eine** Achse unter
vielen, kalibriert, mit Cutoff; Erklärung bleibt bei den Handachsen. Ehrlicher Test: für
die 842 Titel rechnen, durch dieselbe Cohen-d-Pipeline schicken, gegen die Handachsen
antreten lassen. Der Kandidat für 80 → 95 %.

**D3 · Instrumentierungs-Detektor via `SoundAnalysis`** (Fable 5 Rang 3). Apples lokaler
Klassifikator auf Zeitfenstern, aggregiert zu einer „Instrumentierungs-Neigung" (Gitarre/
Schlagzeug vs. Synth/Drum-Machine) mit Konfidenz — fasst, was globale Spektralstatistik
im dichten Mix verwischt. Billiges Experiment.

**D4 · Gelernte Distanzgewichte** (Fable 5 Rang 4). Erst wenn Nutzer-Feedback („passt /
passt nicht") im Player gesammelt wird; stark regularisiert mit den Handgewichten als
Prior. Wert wächst über Monate.

---

## 4. Neubewertung der bestehenden Phase-5b-Issues

- **#24 (MFCC-Vektor):** Fable 5 und unsere Daten stufen reine Klangfarben-Merkmale für
  *diese* Bibliothek ab (Timbre trennt die 90er-Ära nicht). MFCC bleibt nur als
  **Input für D2/D1** interessant, nicht als eigene Achse — **zurückstellen**, bis ein
  gelerntes Modell (D2) es tatsächlich braucht.
- **#25 (gelernte Genre-Neigung):** bleibt gültig, aber **B1 (Künstler-Reparatur) ist der
  einfachere, datenbelegte erste Schritt** in dieselbe Richtung und sollte #25 vorausgehen.

---

## 5. Bewusst NICHT tun

- **MusicBrainz-Graph in die Distanz mischen:** „gehört zusammen" (Label, Release-Group,
  Remix) ≠ „klingt ähnlich"; in einer Compilation-Bibliothek würde er Compilation-
  Nachbarschaft belohnen — das Rauschen, das wir bekämpfen. Als eigene Facette „Verwandt"
  zeigen.
- **Gelernte Gewichte / MLSoundClassifier *jetzt*:** zu wenig Feedback / Zirkularität
  (Training auf genau den Tags, denen wir misstrauen).

---

## 6. Offene Design-Frage (Ehrlichkeitsgesetz, nächste Stufe)

Bisher regelt das Ehrlichkeitsgesetz, wie *einzelne* Signale bei Unwissen zählen (neutral).
Offen ist: **Was ist die ehrliche Antwort, wenn das *Gate selbst* unsicher ist** — wenn
die Evidenzen zur Stilfamilie eines Kandidaten echt widersprüchlich sind (bei uns konkret:
leeres Tag **+** hohe Beat-Regelmäßigkeit)? Zeigen wir ihn mit **sichtbarem Vorbehalt**
weiter unten, oder gar nicht? Diese Frage entscheiden wir spätestens beim Gate-Umbau (D1).
