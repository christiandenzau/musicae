# Musicae — Umsetzungsplan für die ersten Ergebnisse

*Der Übergang vom Denken zum Bauen. Eine Reihenfolge von Phasen, jede klein genug für eine Claude-Code-Sitzung. Prinzip durchgehend: in die Tiefe statt in die Breite. Der überzeugende Moment, ein wirklich passender Vorschlag auf einer kleinen Scheibe, kommt in Phase 3, bevor schwere Infrastruktur nötig wird.*

---

## Zwei Entscheidungen vorab

**1. Noch kein voller MusicBrainz-Dump.** Der komplette Dump ist Dutzende Gigabyte plus ein eigener PostgreSQL-Server. Für die ersten Ergebnisse unnötig. Für die kleine Scheibe genügen Picard zum Säubern und die kostenlose MusicBrainz-Web-API für einzelne Abfragen, ratenbegrenzt auf etwa eine Anfrage pro Sekunde. Der volle lokale Dump ist der Skalierungsschritt, nicht der Start.

**2. Alles in Swift, kein Python-Zwischenschritt.** Bewusste Entscheidung. Eine Sprache, eine Datenbank, kein Portieren und kein zweites Mal Prüfen, und das Werkzeug lebt direkt in Petrichors Welt. Der Start dauert minimal länger, dafür reißt du das Fundament nie wieder auf. Die Achsen rechnest du nativ über Accelerate und vDSP. Ehrlich dazu, zwei Achsen sind in reinem Swift aufwendiger, die integrierte Lautheit nach LUFS-Norm und der BPM. Das Gegenmittel steht in Phase 2, für die erste Fassung RMS statt echtem LUFS und ein auf das Eurodance-Band eingegrenzter BPM. Der Rest ist geradliniges vDSP.

---

## Phase 0 — Den Boden verstehen

Bevor du irgendetwas hinzufügst, verstehe, was schon da ist. Öffne Petrichors SQLite-Datenbank und lies das Schema aus, welche Tabellen, welche Felder. Achte besonders auf Titel, Künstler, Album, Albumkünstler, Jahr, Genre, Dauer, Dateipfad, ein etwaiges Compilation-Kennzeichen und die Felder für MusicBrainz- und Discogs-IDs. Verstehe, wo die Bibliotheksdaten liegen und wie Petrichor sie liest.

*Claude-Code-Auftrag:* Finde und dokumentiere das Datenbankschema von Petrichor, gib eine Übersicht aller Tabellen und Spalten aus, und markiere, welche der oben genannten Felder vorhanden sind und welche fehlen.

*Ergebnis:* Eine Schema-Karte. Du weißt genau, was du schon hast.

## Phase 1 — Die Testscheibe wählen und säubern

Wähle ein kleines Eurodance-Set, das du tief kennst, ein Ankeralbum und seine Nachbarn, etwa fünfzig bis zweihundert Titel. Säubere nur diese Scheibe mit Picard von Hand, korrektes Jahr, sauberer Titel, die Mix-Version im Titel sichtbar, und lass Picard die MusicBrainz-IDs in die Tags schreiben. Importiere die Scheibe danach neu in Petrichor, damit die sauberen Tags in der Datenbank stehen.

*Kein Claude-Code, das ist Handarbeit in Picard.* Genau hier zählt der eine externe Datenpunkt, der die Empfehlung trägt, das richtige Jahr.

*Ergebnis:* Eine kleine, vertrauenswürdige Dateninsel mit korrektem Jahr, Titel, Version und MBIDs.

## Phase 2 — Die lokalen Audio-Achsen rechnen

Baue das Analysewerkzeug als eigenes Swift-Target oder kleines Paket, das dieselbe Persistenzschicht wie Petrichor nutzt, vermutlich GRDB, das hast du in Phase 0 geprüft. Nicht in die Player-Oberfläche hineindrücken, ein abgegrenztes Stück, das über die Scheibe läuft und je Titel eine Zeile in eine neue Fingerprint-Tabelle schreibt. Das Schema bleibt damit sauber und umkehrbar. Die Samples liest du über AVAudioFile in einen Mono-Puffer, bei Bedarf heruntergerechnet. Die Achsen kommen aus Accelerate und vDSP, spektrale Helligkeit und Bass-Anteil direkt aus der FFT, Lautheit und Dynamikumfang aus RMS über Fenster, der Dynamikumfang über die Streuung der kurzzeitigen RMS-Werte, genau deine Intuition von durchgehend laut gegen drei Teile. Echtes LUFS nach Norm braucht K-Weighting und Gating, das ist eine spätere Verfeinerung, für die erste Fassung reicht RMS. Die Mix-Version parst du per Textsuche aus dem Titel, Extended, Radio Edit, Club Mix. Die Dauer hast du schon.

Reihenfolge innerhalb der Phase, das Schwere zuerst. Der BPM ist das einzige riskante Stück, alles andere ist leicht. Bau ihn zuerst, denn trifft er nicht zuverlässig, wackelt eine tragende Achse, und das willst du am Tag eins wissen. Der Weg, Audio zu Mono bei 11025 Hertz, eine Onset-Hüllkurve aus dem spektralen Fluss über kurze FFT-Fenster, dann Autokorrelation dieser Kurve, um die Periode des Takts zu finden, und die Suche von vornherein auf das Eurodance-Band eingegrenzt, etwa 120 bis 150, damit der Oktavfehler gar nicht erst entstehen kann. Bau dir sofort eine winzige Prüfung mit, lass das Werkzeug über zehn bis zwanzig Titel mit bekanntem BPM laufen und vergleiche. So weißt du an einer Handvoll Titeln, ob der Algorithmus trägt, nicht erst, wenn die ganze Maschine steht. Zickt die einfache Version, härtest du an genau einer Stelle, die Onset-Messung auf Bass und untere Mitten fokussieren, oder eine kleine fokussierte Bibliothek nur für diesen einen Schritt.

*Claude-Code-Auftrag:* Baue ein Swift-Kommandozeilen-Target, das eine Audiodatei über AVAudioFile lädt und zu Mono mit 11025 Hertz wandelt, über vDSP eine Onset-Hüllkurve aus dem spektralen Fluss bildet und daraus per Autokorrelation den BPM im Bereich 120 bis 150 schätzt, und gib einen Testmodus dazu, der über einen Ordner läuft und je Datei den geschätzten Wert ausgibt. Danach im selben Target die leichten Achsen, RMS-Lautheit und Dynamikumfang, spektrale Helligkeit und Bass-Anteil über vDSP, die Mix-Version aus dem Titel, und schreibe je Track eine Fingerprint-Zeile in eine neue SQLite-Tabelle über dieselbe Persistenzschicht wie Petrichor.

*Ergebnis:* Jeder Titel der Scheibe hat seine nativ gerechneten Achsen gespeichert, und der BPM ist gegen bekannte Werte geprüft.

## Phase 3 — Die ehrliche Abfrage bauen (der überzeugende Moment)

Jetzt der Kern, der alles beweist. Baue die präzise Abfrage über die Achsen der Scheibe, zum Beispiel Eurodance, Jahr 1995 bis 1996, nur Extended, hohe Energie, Länge fünf bis acht Minuten. Reine Filter, keine KI, keine Cloud. Und baue daneben den filterbasierten Nachbarvorschlag, gegeben ein Titel, zeige die Nachbarn nach gleichem Jahresfenster, gleicher Längenklasse, gleicher Mix-Art und ähnlicher Energie. Dann prüfst du mit dem Ohr. Schlägt es dir bei deinem Ankertitel die richtigen vor, nicht den Müll, den andere Player liefern?

*Claude-Code-Auftrag:* Baue auf der Fingerprint-Tabelle eine Abfragefunktion mit kombinierbaren Filtern für Jahr, Länge, Mix-Version und Energie, und eine zweite Funktion, die zu einem gegebenen Track die nächsten Nachbarn nach diesen Achsen ordnet.

*Ergebnis:* Der erste Moment, in dem es funktioniert und sich richtig anfühlt. Das ist der Beweis. Mehr brauchst du jetzt nicht.

## Phase 4 — Relationen über die MusicBrainz-API (nur wenn Phase 3 überzeugt)

Erst wenn der Filter trägt, hol die relationale Schicht für die Scheibe. Für die MBIDs der Scheibe rufst du über die MusicBrainz-Web-API, ratenbegrenzt, die Fakten und Beziehungen ab, das verlässliche Jahr, das Label, vor allem die Beziehungen, auf welchem Release erscheint diese Aufnahme, Remix-von, Cover-von. Speichere das als Kanten. Damit baust du den ersten echten Faden, die Maxi zum Album des Jahres, das diesen Song enthält.

*Claude-Code-Auftrag:* Baue einen kleinen API-Client für MusicBrainz, der die Ratenbegrenzung beachtet, für eine Liste von MBIDs die Releases und Beziehungen abruft und sie als Kantentabelle speichert.

*Ergebnis:* Ein kleiner Beziehungsgraph für die Scheibe, der erste begehbare Faden.

## Phase 5 — Integration und Skalierung (später)

Erst nachdem das Konzept hält. Bringe die Abfrage und den Vorschlag in Petrichors Oberfläche. Und erst jetzt werden die schweren Dinge sinnvoll, der volle MusicBrainz-Dump für die ganze Bibliothek offline, die akustische Embedding-Schicht für das Klingt-wie, und die visuelle, lebende Oberfläche, das Instrument. Jedes davon ist ein eigener Plan, den du angehst, wenn der Beweis aus Phase 3 und 4 dich trägt.

---

## Die Logik dahinter

Der schwere Teil, die externe Anreicherung der ganzen Bibliothek, ist für deinen ersten Beweis gar nicht nötig. Die Achsen, die zählen, liegen schon in deinen Dateien oder sind lokal rechenbar. Phase 0 bis 3 brauchen keine Cloud, keinen Server, keinen Dump, nur Petrichor, Picard, ein Swift-Analysewerkzeug und etwas Abfragelogik. Du kannst den überzeugenden Moment in Tagen haben, nicht in Monaten. Genau das schützt dich vor der langen, unbelohnten Mitte, an der Soloprojekte sterben.
