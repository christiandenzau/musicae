# Musicae — Feature-Ideen für die Zukunft

*Sammelpunkt für Funktionen jenseits des ersten MVP, damit keine verloren geht. Bewusst nicht final, nur geordnet. Das Gegenstück zum Umsetzungsplan, der das Nächste hält, dieses hält das Spätere. Querlaufend gilt eine Regel über allem: Die App rechnet und fragt, sie behauptet nie ein Gefühl.*

---

## Stand der Umsetzung

Schon drin: die BPM-Erkennung, die spektrale Helligkeit, heller gegen dunkler Track, und der Bass-Anteil. Das Rückgrat des akustischen Fingerprints steht damit zum Teil. Der erste Stein ist gelegt.

## Die drei Schichten

Damit die Ideen nicht durcheinanderlaufen, halte drei Schichten sauber getrennt:

1. **Der gerechnete akustische Fingerprint.** Die Maschine misst den Klang.
2. **Das Nutzerprofil.** Der Mensch sagt einmal, wer er ist und was er mag.
3. **Die persönliche Bedeutungs-Schicht.** Der Mensch heftet Bedeutung an einzelne Titel und erkundet seine Zeit.

Die Maschine rät nie, was zur dritten Schicht gehört. Sie misst die erste, nimmt die zweite entgegen, und reicht der dritten nur das Werkzeug.

## 1. Der akustische Fingerprint, weitere Achsen

Vorhanden: BPM, Helligkeit, Bass. Aus dem Datenmodell folgen noch die übrigen robusten Achsen, Dynamikumfang über die Streuung der kurzzeitigen Lautheit, Lautheit als RMS jetzt und LUFS später, und die MFCCs als kompakter Klangfarben-Fingerprint.

**Neu, Tonart und Harmonie (Key).** Berechenbar über ein Chromagramm, die Energie in den zwölf Tonklassen gegen Tonart-Profile geprüft. Wichtige Ehrlichkeit, das ist fehleranfällig, es verwechselt Dur und Moll-Parallele und stolpert über Modulation. Behandle es als Zusatzpunkt und Hinweis, nie als harte Tatsache. Sein eigentlicher Reiz ist die harmonische Mischbarkeit, das Camelot-Rad der DJs, welcher Track als Nächstes tonal passt. Das nutzt sonst nur DJ-Software, kein Hörprogramm.

**Die schwere Achse, klangliche Charakteristik.** Was du an Musik liebst, analoge Synthesizer-Sounds, treibende Beats, üppige Streicherflächen, ist Klangfarbe und Textur, und die ist heute nur schwer und unzuverlässig zu rechnen. Die MFCCs fangen einen Teil davon, ein Etikett wie analoger Synthesizer fängt keiner sauber. Ehrliche Einordnung, das gehört vorerst nicht in die gerechneten Achsen, sondern ins Nutzerprofil als selbst genannte Vorliebe, und vielleicht eines Tages in ein trainiertes Modell. Tu nicht so, als sei es schon rechenbar.

## 2. Das Nutzerprofil und Onboarding

Bevor die Bibliothek ganz integriert ist, kann der Nutzer dir schon viel über sich geben, und daraus baust du einen Geschmacks-Fingerprint, der das Organisieren und die algorithmische Analyse im Hintergrund von Anfang an verbessert.

- **Geburtsjahr.** Lokal gespeichert, nur als Referenz, der Schlüssel für die Alters-Tür weiter unten.
- **Geschlecht, optional.** Nicht wichtig, aber es hat einen realen, kleinen Nutzen, der Erinnerungs-Höcker liegt bei Männern und Frauen verschieden, dazu unten mehr. Freiwillig.
- **Lieblingsgenres.** Dahinter eine kleine mitgelieferte Datenbank, die zu jedem Genre bekannte Künstler zeigt, damit der Nutzer bestätigen und erweitern kann, auch ohne dass seine Bibliothek schon analysiert ist.
- **Lieblingskünstler.**
- **Geliebte klangliche Charakteristika.** Genau das von oben, was sich schwer rechnen lässt, sagt der Nutzer hier selbst, ich liebe analoge Synthese, treibende Beats.
- **Ein paar einfache Fragen.** Sammelst du Alben, hörst du eher Compilations, und Ähnliches.

Wichtig zur Einordnung, das alles ist, was der Nutzer über sich erklärt. Objektiv in dem Sinn, dass er es selbst vergibt, nicht dass die Maschine es errät.

## 3. Die persönliche Schicht: Erinnerung, Epoche, Alter

Das emotionale Herz, und es ist ein Paar aus zwei Ideen, die sich am selben Ort treffen, der Epoche.

**Die antippbaren Erinnerungs-Marken.** Während ein Titel läuft, kann der Nutzer mit einem Klick eine persönliche Marke anheften, Erinnerung, Sommer 96, ein Ort, ein Mensch. Kein Schreiben, nur ein Tippen. Strenge Trennung, das sind Marken über den Titel, was er für dich bedeutet, nicht Gefühlswörter über den Klang. Treibend oder düster rechnet die App ohnehin aus dem Audio, dafür braucht es keinen Klick. Disziplin der Liste, zwei, drei klare persönliche Marken, die nur der Mensch vergeben kann, niemals zwanzig Stimmungswörter, sonst wird es eine Checkliste und entwertet das Anheften.

**Das ehrliche Aufpoppen.** Wenn ein Titel oft gehört wurde, darf unten ein Hinweis erscheinen, aber als Frage, nie als Behauptung. Nicht du hast eine Verbindung, sondern du hast das oft gehört, bedeutet es dir etwas. Das eine lädt den Nutzer ein, seine Bedeutung selbst zu setzen, das andere täte so, als wüsste die App sie schon, und das ist die Anmaßung, die wir vermeiden. Häufiges Hören ist eine Tatsache, eine emotionale Verbindung daraus zu schließen ist ein Sprung, den die Daten nicht hergeben. Die App fragt, sie weiß nicht.

**Die biografische Erkundung, die Alters-Tür.** Aus dem Geburtsjahr öffnet die App eine Tür zurück in die prägende Zeit. Die Wissenschaft dahinter heißt reminiscence bump, der Erinnerungs-Höcker. Musik aus den Jahren etwa zehn bis dreißig prägt am stärksten, mit einem Gipfel um fünfzehn, bei Männern eher sechzehn, bei Frauen später, nach neunzehn. Entscheidend, dieses Fenster ist zugleich persönlich, die Identität bildet sich, und kulturell, das geteilte Lebensskript, Schulabschluss, der Sommer danach. Genau deshalb fallen deine zwei Ideen, Alter und Zeitgeist, hier in eine zusammen. Die stärkste Fassung zeigt zuerst deine eigenen Titel aus dem Fenster, den vergessenen eigenen, dann das Kulturelle ringsum. Ehrlich, die App weiß, was damals da war, nicht, was du gehört hast, es sei denn, es liegt in deiner Bibliothek. Es ist eine Tür zu der Zeit, kein Protokoll deiner Vergangenheit.

**Die Zeitgeist-Schicht.** Pro Land eine Datensammlung, was wann präsent war, aus Chart-Tabellen, als Knotengewicht und als Querschnitt-Knoten einer Ära, beides steht im Datenmodell schon. Ehrliche Unschärfe, Charts sind Popularität, ein Stellvertreter, und der Sommer als Gefühl ist halb echt, halb nachträglicher Mythos, die Nostalgie-Compilations erzeugen ihn mit. Mit Quelle speichern, als Näherung zeigen. Die Schicht trägt für vergangene Epochen am besten, weil die Monokultur zerfallen ist, genau für deine Zielgruppe.

**Wie sie zusammenwirken.** Die Alters-Tür führt dich von außen in deine Zeit, über das, was die App weiß. Die antippbare Marke lässt dich von innen Bedeutung setzen, über das, was nur du weißt. Beide treffen sich an der Epoche. Markierst du einen Titel und die App kennt dein Jahr, wird deine persönliche Marke zum Eingang in den Graphen, hier ist mehr aus dem Fenster, das du gerade markiert hast. Gerechnete Struktur und menschliche Bedeutung, ohne dass eines das andere überschreibt.

## Die drei Modi der App

Damit hat Musicae drei Arten, sich zu bewegen, und zusammen sind sie das, was nirgends existiert:

1. **Die präzise Abfrage.** Ich weiß, was ich will, gib es ohne Müll.
2. **Die verwandte Empfehlung.** Von diesem Titel ausgehend, zeig Verwandtes, ich wähle die Richtung.
3. **Die biografische Erkundung.** Führ mich in mein Fenster, in meine Zeit.

Der dritte Modus ist das emotionale Herz, die persönliche Verbindung, die in jeder anderen App fehlt.

## Die visuelle und materielle Oberfläche

Bisher hielt dieses Dokument die unsichtbaren Schichten, den Fingerprint, das Profil, die Bedeutung. Hier kommt die sichtbare hinzu, die Oberfläche, die Musicae vom Dateimanager trennt. Über allem steht das Gestaltungsgesetz, jedes Element muss real wirken, das einzige Verbot ist die leere Animation, Bewegung ohne Ursache. Alles hier ist Zukunft, nach dem MVP, aber es ist der Teil, den sonst niemand ehrlich baut.

**Das 3D-Gerät als Abspielfläche.** Die Wiedergabe lebt auf einem gerenderten Gerät, Plattenspieler, Verstärker, Deck. Wichtige Gabelung, ein in Blender hochwertig gerendertes Modell ist zunächst nur ein schönes, totes Bild. Die Teile, die antworten müssen, Analyzer, Nadeln, drehende Platte, Zustand der Regler, dürfen nicht vorgetäuscht, sie müssen live vom echten Signal getrieben werden. Die ehrliche Lösung ist ein Hybrid, der Körper hochwertig aus Blender, die reagierenden Teile als lebende Ebenen darüber. Nativer Weg in Swift ist SceneKit für echtes Echtzeit-3D, oder die Komposition aus gerendertem Körper und lebenden Ebenen. Regel, das Gerät zeigt nichts, was es nicht tut. Die drei Regler für Höhen, Tiefen, Mitten greifen real ins DSP ein, Bediensprache, nicht Zierde.

**Die Bibliothek als Regal.** Vorbild ist das alte Delicious Library, das die Sammlung als Objekte im Holzregal zeigte statt als Liste. Die Materialität hört nicht an der Abspielfläche auf, sie reicht in die Bibliothek, die eigene Sammlung als Regal in echten Hüllen zu sehen ist selbst Teil der Anwesenheit. Ehrliche Grenze, das Regal ist herrlich zum Wandern, aber langsam zum Finden, bei zweitausend CDs scrollst du dich tot. Also beides, das Regal als Anwesenheits-Ansicht zum Erleben, die schnelle Liste und Suche zum gezielten Zugreifen. Erkunden und Zugreifen, dieselben zwei Modi, jetzt im Bild der Bibliothek.

**Das Mixtape als Kassette.** Eine Playlist ist kein Eintrag, sie ist ein Objekt, eine Kassette, die der Nutzer benennt, deren Hülle er aus einem Bild oder einer Vorlage gestaltet, mit automatisch gesetzter Schrift. Das Mixtape war im Konzept schon der Gegenentwurf zur Algorithmus-Playlist, hier bekommt es einen Körper. Geringes Risiko, hohe Freude.

**Das native Booklet.** Der reinste Ausdruck der These gegen Roon, in kleinster Form. Roon holte die Information der Liner Notes zurück, Text und Biografien. Das Booklet als Gegenstand, die gescannten Seiten mit Layout, Fotos, gedruckten Texten, zum Durchblättern, holt niemand zurück. Kein Player liest Booklets nativ, die Lücke ist echt. Und sie ist billig, per Drag and Drop wird ein PDF oder gescannte Bilder dem Album zugeordnet, in der Datenbank abgelegt, in der Oberfläche blätterbar gezeigt, auf Apple mit PDFKit. Von allen Oberflächen-Ideen trägt diese am meisten von der These bei den geringsten Kosten, sie könnte ein früher Beweis sein, kein fernes Ziel.

**Die Kassetten-Färbung, wählbare Decks.** Für die ferne Zukunft, wenn die App reif ist. Wählbare Decks, CD, universell, Kassette. Eine echte Kassette, die eine Playlist trägt, wird ins Deck geschoben, lädt die Playlist und legt eine Kassetten-Färbung auf den Klang, die die Treue absichtlich verschlechtert, Wärme und Unvollkommenheit, das Gegenteil des Audiophilen. Besteht die Anker-Prüfung, weil das Einschieben zwei reale Dinge tut, Musik wählen und Ton färben. Echte Herstellernamen wie BASF wären eine Lizenzfrage, eher die Ästhetik andeuten. Der Anti-Audiophilen-Player, als Kür, nie als Hauptsache.

## Ehrliche Leitplanken

Damit künftige Entscheidungen nicht abdriften:

- Die App fragt, sie behauptet nie ein Gefühl.
- Sie rechnet das Objektive, nimmt das Subjektive entgegen, modelliert das Subjektive nie.
- Stimmung im Klang wird gerechnet, Bedeutung in dir wird vom Menschen vergeben, beides wird nie vermischt.
- Unscharfe Daten, Popularität, Charts, Tonart, werden mit Quelle gespeichert und als Näherung gezeigt.
- Die Wissenschaft begründet, wohin die Tür zeigt, sie ist kein Modell deiner Seele.
- Wenige echte persönliche Marken, nie eine Stimmungs-Checkliste.
- Jedes sichtbare Element wirkt real, keine leere Animation, keine Bewegung ohne Ursache.

## Einordnung zur Reihenfolge

All das ist nach dem MVP. Der erste Stein bleibt der gerechnete Fingerprint und die ehrliche Abfrage auf der Eurodance-Scheibe. Diese Funktionen brauchen die Chart-Daten, das Onboarding und die Erkundungs-Oberfläche, also spätere Phasen. Hier festgehalten, damit sie nicht verloren gehen, nicht damit sie sich vordrängen.
