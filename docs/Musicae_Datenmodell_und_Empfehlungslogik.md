# Musicae — Datenmodell, Fingerprint und Empfehlungslogik

*Zwischenspeicher. Begleitend zum Konzeptdokument, das das Warum hält. Dieses hält das Wie der Daten: wie ein Titel vergleichbar und abfragbar wird, und zwar ehrlich. Leitfrage dieser Ausarbeitung: woher kommt jedes Signal, und wie weit darf man ihm trauen.*

---

## 1. Das Grundbild: drei Quellen, drei Vertrauensstufen

**Der Fingerprint ist nicht ein Wert und nicht ein Vektor, er ist ein geschichteter Datensatz.** Die Schichten unterscheiden sich in zweierlei: woher sie kommen und wie sicher sie sind. Es gibt drei Quellen, und sie teilen sich die Arbeit sauber:

1. **Die Datei und ihre Tags** (Titel, Jahr, Genre, Dauer, oft die Mix-Version im Titel).
2. **Die lokale Audioanalyse** (alles Akustische, selbst gerechnet aus der Wellenform).
3. **MusicBrainz / Discogs** (die relationalen und redaktionellen Fakten).

**Die entscheidende Lektion vorweg:** MusicBrainz liefert keine Audioanalyse mehr, das war AcousticBrainz, und das ist eingestellt. Also bekommst du die *Fakten und Beziehungen* von MusicBrainz und rechnest die *akustischen Merkmale selbst*. Diese Teilung ist kein Notbehelf, sie ist die saubere Architektur. Alles wird einmal gerechnet und gespeichert, denn Rechnen ist teuer, Speichern billig.

## 2. Was lokal aus der Audiodatei berechenbar ist

**Robust und billig — das Rückgrat, dem du fast blind trauen darfst:**

- **Dauer.** Exakt.
- **BPM.** Für Eurodance, Hardtrance, Viervierteltakt sehr zuverlässig, weil der Beat stur und explizit ist. Einzige klassische Falle: der Oktavfehler (70 gegen 140), abzufangen mit einem sinnvollen BPM-Fenster.
- **Lautheit (LUFS).** Standardisiert, exakt, wie laut das Master insgesamt ist.
- **Dynamikumfang.** Genau die Waveform-Intuition: durchgehend laut gegen leises Breakdown und Drop. Robust rechenbar über die Schwankung der kurzzeitigen Lautheit. Eine der wertvollsten und am wenigsten genutzten Achsen überhaupt, kein üblicher Player zeigt sie. Sie trennt den pumpenden Track vom Track mit echter Dramaturgie.
- **Spektrale Helligkeit** (spectral centroid). Hell und trebly gegen dunkel und bassig. Billig, perzeptuell echt.
- **Bass-Anteil.** Wie viel Energie im Tiefen sitzt, für elektronische Musik identitätsstiftend.
- **MFCCs.** Der klassische kompakte Klangfarben-Fingerprint, ~13 Zahlen, die das Timbre fassen. Standardwerkzeug der Disziplin.

**Weicher — real nutzbar, aber als Hinweis zu behandeln, nie als Fakt:**

- **Tonart und Harmonie.** Geht über ein Chromagramm (Energie in den zwölf Tonklassen, abgeglichen gegen Tonart-Profile). Aber fehleranfällig: verwechselt Dur und Moll-Parallele, stolpert über Modulation und Verzerrung. Für sauberen tonalen Dance brauchbar, nicht für alles. Reizvoll, weil daraus die **harmonische Mischbarkeit** folgt (Camelot-Rad der DJs, welcher Track tonal als Nächstes passt). Das nutzt kein Hörprogramm, nur DJ-Software.
- **Struktur.** Billige, robuste Version: die Energiekurve über die Zeit (Breakdown und Drop sofort sichtbar). Schwere Version (benannte Abschnitte Intro/Build/Drop) ist Forschungsgebiet und wackelig. Nimm die billige.
- **Danceability / Mood (Modelle).** Trainierte Modelle, mäßig zuverlässig, in der Nische eher schwach diskriminierend.

**Das Embedding — die moderne Antwort auf das Wort Fingerprint:**

- Ein neuronales Modell, lokal über Core ML oder MLX auf Apple Silicon, verwandelt den Klang in einen dichten Vektor (~200–1000 Zahlen) in einem gelernten Raum, in dem Nähe ungefähr Ähnlichkeit bedeutet. Das ist der eigentliche akustische Fingerprint für Nächste-Nachbarn-Suche, „klingt wie".
- **Die entscheidende Ehrlichkeit:** Dieses Embedding fängt *akustische Ähnlichkeit, nicht kuratorische Zugehörigkeit*. Es ist genau das, was jeder andere Player benutzt und was enttäuscht. Eine mächtige Zutat, nicht die ganze Antwort.

## 3. Was MusicBrainz (und Discogs) liefern

Die relationale und redaktionelle Schicht, die kein Audio geben kann:

- Die IDs, das **zuverlässige Jahr**, Land, **Label**, Katalognummer, Format, Trackliste.
- Vor allem die **Beziehungen**: Remix-von, Cover-von, Produzent, Mitwirkende, Bandmitgliedschaft, und die **Serie** als eigenes Konzept.
- Dazu Genre- und Folksonomy-Tags, aber das ist der unsaubere Teil, sparsam und widersprüchlich.

**Discogs** ergänzt mit feineren **Styles** (Hardtrance, Hard House als eigene Kategorie) und der Mix-Version in den Titeln, oft besser für die Szene als MusicBrainz, aber mit heikler Lizenz (privat unproblematisch, kommerziell heikel).

## 4. Die zentrale Erkenntnis: Empfehlung ist ein Graphenproblem

Nicht ein Ähnlichkeitsproblem. **Drei Arten von Zugehörigkeit, drei Schichten, drei Kantenarten:**

- **„Klingt wie"** → der Fingerprint, ein Vektorraum.
- **„Gleiche Liga, gleiche Ära, gleiches Format"** → die Attribute (Jahr, Länge, Mix, Dynamik), Filter.
- **„Gehört zur selben Welt"** → die Beziehungen, ein Graph.

Das Wunder, ein *passendes* Album statt eines bloß *ähnlichen*, entsteht erst, wenn die harten und relationalen Schichten erstklassig bleiben und die akustische sie nur ergänzt. Der Fehler jedes bestehenden Players ist, die Fakten und Beziehungen unter der akustischen Ähnlichkeit zu begraben.

## 5. Knoten haben Typen und Gewichte

Eine Compilation ist der Beweis, dass die relationale Schicht eigen und unverzichtbar ist. Sie ist kein Beutel aus Klängen, sondern ein Knoten, dessen Wert ganz in seinen Kanten liegt. Kein Fingerprint findet Volume 1 bis 11, nur die Beziehung *Serie* findet sie.

- **Blatt-Knoten:** ein Album, die Aussage eines Künstlers.
- **Querschnitt-Knoten:** eine Compilation, ein Knotenpunkt, der eine Ära bündelt. Ein **Zeitgeist-Knoten**.
- Die Bewegung von Bravo Hits 95 zu Dance Now aus demselben Jahr ist keine Ähnlichkeit, sondern eine eigene Kantenart: **gleiche Ära, gleiche Funktion**, Querschnitt zu Querschnitt.
- **Knotengewicht:** bekannt/beliebt gegen obskur (siehe 7).

Bist du in einem Blatt, traversierst du zum Künstler, seinem Album, seinem Jahrgang. Bist du in einem Querschnitt, traversierst du zu den Schwester-Knotenpunkten und zu den Blättern, die er verbindet.

## 6. Vektoren gegen Graph: zwei Paradigmen für zwei Signale

Die wichtigste technische Trennung, und der Punkt, an dem die FastText-Idee zu schärfen ist:

- **FastText und semantische Embeddings finden sprachliche Nähe.** Die Verwandtschaft zwischen Bravo Hits 95 und einem Scooter-Album von 1995 ist aber keine sprachliche (die Wörter liegen in keiner Sprache nah), sondern eine **faktische** (Scooter kommt auf Bravo Hits 95 vor, Scooter war 1995 aktiv). Diese liegt im **Datengraphen**, nicht im Wortraum.
- **Übertragbar von der Text-Engine ist nicht das Embedding, sondern die Methode:** große Daten in eine kompakte, schnelle lokale Nachschlagestruktur kompilieren (der Trick von 7 GB auf 25 MB). Aber das Ergebnis ist hier kein Vektorraum, sondern ein Graph.
- **Die Regel:** Vektoren für die akustische Schicht (den Charakter), dort transferiert die Methode perfekt. Aber zwinge die Fakten nicht in Vektoren, sie wollen eine **relationale, indizierte Datenbank, die du traversierst**.
- (Ein Musik-Gegenstück zu FastText existiert: Embeddings aus dem gemeinsamen Vorkommen in Playlists. Aber das ist genau das kollaborative Signal, das enttäuscht, und in der Nische am dünnsten. Der Faktengraph ist verlässlicher.)

## 7. Beliebtheit als Knotengewicht — zusammengesetzt und unscharf

Dass ein Titel bekannter ist, ist eine echte, wertvolle Achse, aber sie kommt nicht sauber aus einer Quelle:

- **MusicBrainz** kennt keine Beliebtheit, es ist eine Faktendatenbank.
- **ListenBrainz** hat Hörzahlen (wie oft weltweit gehört).
- **Chart-Tabellen** (Billboard, deutsche Charts) sind herunterladbar, aber regional, unsauber, unvollständig. Im deutschen Dance der Neunziger ordentlich, anderswo lückenhaft.

Markiere die bekannten Titel (war Chart-Hit, Höchstplatzierung, Wochen), aber **speichere die Quelle dazu**, damit du weißt, wie sicher die Markierung ist. Das ist direkt das Ehrlichkeitsgesetz: einen Titel als bekannten hervorzuheben ist eine Behauptung über die Welt. Tu nie sicherer, als du bist.

## 8. Empfehlung gegen Abfrage — zwei verschiedene Aufgaben

Sie fühlen sich ähnlich an und sind technisch entgegengesetzt.

- **Empfehlung:** ausgehend von einem Titel zeig mir Verwandtes. Graph-Traversierung, bei der **der Nutzer die Richtung wählt** (die Welt des Titels gegen den Zeitgeist der Compilation).
- **Abfrage:** ich sage genau, was ich will, gib es ohne Müll. „Pop von 95, nur den ich mag." „Hardtrance, nur Extended, nur Club, eine bestimmte Länge." „Rock aus den Achtzigern, nicht 70er, nicht 90er." Die **einfachere, zuverlässigere** Aufgabe, und die, die öfter glücklich macht.

**Die stille Erkenntnis:** Der ganze Fingerprint war nie nur Material für die Empfehlung. Er ist das, **wonach du filtern kannst**. Deine Abfrage ist deine eigene Datenbank, ehrlich befragt.

- **Der Bruch mit Apple Music** ist tiefer als Zufall gegen Ordnung: Streaming gibt keine Filter *mit Absicht*, es lebt vom Strom, von der entschiedenen Unentschiedenheit. Eine echte Abfrage gibt die Kontrolle zurück, die das Streaming nimmt. Anwesenheit statt Zugriff, diesmal in der Logik.
- **„Nur den ich mag":** die eigene, gepflegte Bibliothek *ist bereits der Geschmack*. Du hast diese Titel gerippt, gekauft, behalten. Allein in der eigenen Sammlung zu bleiben filtert das meiste Fremde schon weg, der unterschätzte Vorteil des lokalen Besitzes. Die wachsenden Signale (wie oft gehört, übersprungen, als Favorit markiert) verfeinern nur noch.

## 9. Steuerung, nicht Konfiguration

Die Richtung der Verwandtschaft ist eine **Entscheidung des Moments, nicht der Einstellung**. Eine Vorab-Einstellung, was automatisch priorisiert wird, sieht mächtig aus und ist meist tot (die wenigsten öffnen sie, und was du heute willst, ist nicht, was du nächste Woche willst).

Besser: die Wahl direkt an der Stelle, wo sie zählt, sichtbar, leicht, beim Hören. **Verwandte Titel und verwandte Compilations nebeneinander, ein Antippen genügt.** Ein guter Standard, der öfter trifft, plus die sichtbare Abzweigung schlägt jede vergrabene Voreinstellung.

## 10. Die Analyseseite als ehrlicher Spiegel

Lieblingsgenres, Lieblingsjahrgänge, Lieblingsbands, Compilations. Die ehrlichste Form von Personalisierung: sie behauptet nichts über dich, sie zeigt, **was du wirklich getan hast**. Ein Spiegel deines Hörens, kein Modell deiner Seele. Sie sagt nicht „das fühlst du", sie sagt „das hast du gehört". Daraus wächst Selbsterkenntnis, nicht Bevormundung. Deckt sich mit dem Grundprinzip: das Objektive zeigt die App, das Subjektive überlässt sie dir.

## 11. Stimmung — zwei Arten, nicht verwechseln

- **Stimmung im Klang** (treibend, düster, euphorisch): näherungsweise aus dem Audio rechenbar, ein Filter über Energie und BPM. Das ist die Fitness-Playlist.
- **Stimmung in dir** (dieser Track trägt jenen Sommer): liegt nicht in den Daten, nur in dir. Ein leeres Feld, in das du schreibst.

Die App braucht für die eine ein **Rechenwerk** und für die andere nur ein **leeres Feld**. Sie nie zu verwechseln ist die Bedingung dafür, dass die App ehrlich bleibt.

## 12. Das Datenmodell auf einer Zeile

> Ein Titel ist ein **Knoten** mit drei Arten von **Kanten** (klingt wie / gleiche Liga / gleiche Welt). Knoten haben **Typen** (Blatt oder Querschnitt) und **Gewichte** (bekannt oder obskur). Alles wird einmal gerechnet und gespeichert. Der Nutzer wählt, entlang welcher Kante er sich bewegt. Und dieselben Daten tragen beides, die **Empfehlung** und die **präzise Abfrage**.

Das ist Musicae auf Datenebene. Akustik als Vektor, Fakten als Graph, der Nutzer am Steuer, und nie eine Behauptung sicherer, als die Quelle hergibt.
