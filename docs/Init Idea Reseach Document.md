# Bausteine für eine lokale, abofreie Apple-Silicon-Musik-App: Bestandsaufnahme

## TL;DR
- **Es gibt kein fertiges Open-Source-Projekt, das alle fünf Anforderungen (lokales Tagging aus freien Quellen, Cover/Booklet, kuratierte Album-Empfehlungen, Milkdrop-Visualizer + Skins, lokale KI) vereint** — aber alle Einzelbausteine existieren als reife, frei lizenzierte Komponenten und lassen sich auf Apple Silicon kombinieren. Das beste forkbare native Fundament ist **Petrichor** (Swift/SwiftUI, MIT, macOS-only, AVFoundation + SFBAudioEngine).
- **Technisch ist die Visualizer-/Spektrum-Idee für eigene, nicht-DRM-Dateien klar zulässig**: Bei lokalen Dateien über AVAudioEngine darf das dekodierte PCM-Signal per `installTap` abgegriffen werden; nur DRM-geschützte Apple-Music-Streams sind gesperrt.
- **Die größte echte Lücke ist das „kuratierte, ehrliche" Empfehlungssystem auf Album-Ebene** — seit der AcousticBrainz-Abschaltung (Ankündigung 16. Februar 2022, Seiten-Abschaltung Anfang 2023) gibt es keine fertige freie Lösung dafür; man muss MusicBrainz-Relationen + Discogs-Styles + ListenBrainz-Daten + lokale Essentia-/MLX-Features selbst zu einer Heuristik verbinden.

## Key Findings

**(1) Forkbare Fundamente.** Native Apple-first: **Petrichor** (MIT, macOS 14+, v1.5.2 vom 9. Mai 2026, reif, ~1,5k Sterne), **Cog** (GPL, sehr aktiv, Objective-C/AppKit), **SFBAudioEngine-SimplePlayer** (MIT, macOS+iOS Referenzcode). Cross-Platform-Subsonic-Clients (**Cassette**, MPL-2.0, nativ Swift iOS/macOS; **Feishin** etc.) sind nur sinnvoll, wenn man einen Server akzeptiert — für „rein lokal" eher Ballast. Desktop-Player mit Skin-Kultur (foobar2000, MusicBee, Strawberry) sind auf macOS entweder eingeschränkt, nicht quelloffen oder nicht nativ.

**(2) Tagging & freie Metadaten.** MusicBrainz (Kerndaten CC0, Genres/Tags aber CC-BY-NC-SA), Cover Art Archive (frei, MBID-basiert), AcoustID/Chromaprint (akustischer Fingerprint, LGPL-2.1), Discogs (reichste Styles/Editionsdaten, aber restriktive API-TOS und nur authentifizierte, signierte Bild-URLs mit Rate-Limit). Bibliotheken: TagLib via Swift-Wrapper, SFBAudioEngine, beets/Picard als Vorbild.

**(3) Empfehlung/Ähnlichkeit.** Lokale Feature-Extraktion: Essentia (AGPL-3.0 + TensorFlow-Modelle Discogs-EffNet/MusiCNN), librosa, aubio; Apple-seitig Core ML, MLX, SoundAnalysis. Kuratorische Nähe kommt nicht aus Audio, sondern aus MusicBrainz-Relationen, Discogs-Styles und ListenBrainz-Kollaborativdaten.

**(4) Visualizer & Skins.** projectM/libprojectM (LGPL-2.1, nur OpenGL/GLES — kein Metal!), Butterchurn (MIT, WebGL2), Webamp (MIT). Auf Apple läuft die GL-Linie nur über Apples deprecated OpenGL-auf-Metal-Layer; ein nativer Metal-Pfad fehlt.

**(5) Apple-Restriktionen.** Lokale, nicht-DRM-Dateien: voller PCM-Zugriff via AVAudioEngine-Tap, Hintergrundwiedergabe, breite Formatunterstützung. DRM-Apple-Music: kein Raw-Audio ohne Spezial-Entitlement.

## Details

### A) FORKBARE PLAYER-FUNDAMENTE (Apple-first)

**Petrichor** — *Bester Kandidat für einen Fork.*
- **Beschreibung:** Offline-Musikplayer für macOS, in Swift/SwiftUI (mit AppKit-Teilen). Scannt Ordner, extrahiert Metadaten in eine SQLite-Datenbank (via GRDB.swift), verändert die Dateien nicht. FTS5-Suche, Folder-View, Lyrics-Download, Playlists (M3U-Import/Export), Last.fm-Scrobbling, Menubar/Dock-Integration, Dark Mode. Cover-Art wird als BLOB in der DB gehalten (Tracks/Alben/Artists/Playlists). Das Schema enthält bereits Felder für `discogs_id`, `musicbrainz_id`, `spotify_id`, `apple_music_id`, `bio`, `genres` (JSON) — ist also bereits auf externe Metadatenquellen vorbereitet.
- **Lizenz:** MIT (App-Code); Kern-Dependencies SFBAudioEngine, GRDB, Sparkle ebenfalls MIT; dynamisch gelinkte Codec-Libraries (FLAC, Vorbis, Opus) unter GPL/LGPL — relevant nur bei Distribution.
- **Plattform/Apple-Eignung:** macOS 14+ only, Apple-Silicon-nativ, sandboxed und notarisiert, Homebrew-Cask (`brew install --cask petrichor`). Kein iOS.
- **Reifegrad:** Reif. Aktuelle Version **v1.5.2 (9. Mai 2026)** laut GitHub-Releases und Homebrew-Cask (macOS ≥ 14); ~1,5k Sterne / ~52 Forks; 98,4% Swift. Audio-Backend: AVFoundation + SFBAudioEngine → sehr breite Formatliste (MP3, AAC/M4A, ALAC, FLAC, Ogg Vorbis, Opus, APE, Musepack, WavPack, True Audio, DSD, Tracker-Formate).
- **Eignung lokal+abofrei+Apple Silicon:** Sehr hoch. Bereits offline, lokal, ohne Abo, mit Metadaten-DB, die für Discogs/MusicBrainz vorbereitet ist. Quelle: github.com/kushalpandya/Petrichor.

**Cog** — *Reifer, aber Objective-C/AppKit.*
- **Beschreibung:** Freier macOS-Audioplayer (losnoco/Cog-Fork, da Originalautor pausierte). Gapless, Cuesheets, sehr breite Formate (Ogg, MP3, FLAC, Musepack, Monkey's Audio, WavPack, AAC, ALAC, Tracker- und Videospiel-Formate), TagLib-basiertes Tagging, HLS/HTTP-Streaming, Last.fm. App-Sandbox-Modus, App-Store-Branch vorhanden.
- **Lizenz:** GPL (App-Code; Libraries je eigene Lizenzen).
- **Plattform/Reifegrad:** macOS 10.15+, sehr aktiv (Release v3592 vom Juni 2026). Kein SwiftUI, kein iOS.
- **Eignung:** Gutes Fundament für Wiedergabe/Decoding, aber UI ist klassisch AppKit; für ein modernes „entschleunigtes" SwiftUI-Erlebnis weniger geeignet als Petrichor. Quelle: github.com/losnoco/Cog.

**SFBAudioEngine SimplePlayer (Referenz)** — Apple-Referenzcode.
- macOS-Variante (Swift/AppKit, gapless), iOS-Variante (Swift/SwiftUI). MIT. Ideal als Lern-/Startgerüst für die Audio-Pipeline. SFBAudioPlayer nutzt einen AVAudioEngine-Graph (AVAudioSourceNode). Quelle: github.com/sbooth/SFBAudioEngine.

**Cross-Platform (Subsonic/Navidrome-Ökosystem) — mit Vor-/Nachteilen für Apple-only + lokal:**
- **Cassette** (MPL-2.0): nativ Swift/SwiftUI für iOS+macOS, Liquid-Glass-Design, Offline-Download, Cover-Art-Farbgebung, FLAC/Lossless-Badges, kein Electron. **Nachteil:** Erfordert einen Subsonic/OpenSubsonic-Server — widerspricht „rein lokal". **Vorteil:** Sauberster nativer Swift-Code als UI-Vorbild. Quelle: getcassette.app.
- **Navidrome/Feishin/Sonixd/Symphonium/Plexamp:** Allesamt Client-Server-Architekturen. Für einen reinen Lokal-Player auf einem Mac ist die Server-Schicht unnötiger Overhead; zudem ist die lokale-KI-Integration in eine eigene Swift-Engine bei einem Electron-/Web-Client (Feishin, Sonixd) schwieriger als bei nativem Swift. Plexamp und Symphonium sind proprietär (nicht forkbar). **Fazit:** Als Architektur-Inspiration ja, als Fork-Basis für „lokal + Apple-nativ + lokale KI" nein.

**Desktop-Player mit Skin-/Plugin-Kultur:**
- **foobar2000:** Freeware (nicht Open Source), hat eine native macOS-Version, aber die mächtige Komponenten-/Skin-Kultur ist Windows-zentriert. Nicht forkbar (closed source).
- **MusicBee:** Windows-only (läuft nur via WINE/CrossOver auf macOS/Linux), proprietär. Starke Skin-/Plugin-Kultur, aber nicht forkbar und nicht nativ.
- **Winamp/WACUP:** Windows-zentriert; Milkdrop stammt von hier. WACUP proprietär.
- **Clementine/Strawberry:** Qt-basiert, Open Source (GPL), Cross-Platform inkl. macOS. Strawberry (aktiver Fork von Clementine) hat MusicBrainz-Tag-Fetch, projectM-Visualisierungen, Cover-Art. **Nachteil für dieses Projekt:** Qt/C++-Codebasis statt Swift; eine eigene Swift-KI-Engine zu integrieren bedeutet C++/Swift-Bridging; UI ist nicht „Apple-nativ". Als Feature-Referenz wertvoll, als Fork-Basis für ein Apple-Silicon-natives Erlebnis suboptimal.

### B) TAGGING & FREIE METADATEN

**Freie Tagging-Tools (als Vorbild/Referenz, nicht direkt einbettbar):**
- **MusicBrainz Picard** (GPL 2.0+, Python/Qt): Album-orientiertes Tagging, AcoustID-Fingerprinting, Cover-Art-Download, Scripting. Cross-Platform inkl. macOS. Quelle: picard.musicbrainz.org.
- **beets** (Python, CLI): Bibliotheksmanager + MusicBrainz-Tagger, Plugin-Ökosystem (Discogs, Beatport, AcoustID, fetchart, ReplayGain, lyrics). Speichert MBIDs in den Dateien. Skalierbar auf große Sammlungen. Quelle: github.com/beetbox/beets.
- **Mp3tag** (proprietär, Windows), **Yate/Meta** (macOS, kommerziell) — als Vorbild für Workflows.
- **Hinweis:** Diese sind separate Apps; für die eigene App nutzt man besser direkt die Bibliotheken (TagLib/SFBAudioEngine) plus die freien Daten-APIs.

**Freie Metadaten-/Cover-Quellen und Lizenzen:**

| Quelle | Daten | Lizenz/TOS | Rate-Limit | Kommerziell/Offline |
|---|---|---|---|---|
| **MusicBrainz** | Künstler, Releases, Recordings, Release-Groups, Relationen, MBIDs, Jahr/Land/Label/Barcode | **Kerndaten CC0** (Public Domain); **Genres/Tags/Ratings = CC-BY-NC-SA 3.0** (supplementary) | ~1 req/s pro IP, Pflicht-User-Agent | Kerndaten frei (auch kommerziell); für Genre-Daten kommerziell → MetaBrainz-Lizenz nötig. **Offline:** komplette DB-Dumps (PostgreSQL + JSON) 2×/Woche → lokal spiegelbar, umgeht Rate-Limit |
| **Cover Art Archive** | Cover/Booklet-Scans, MBID-verknüpft | Bilder von Internet Archive gehostet; API frei | über coverartarchive.org | Frei nutzbar; ideal für Cover + Booklet (mehrere Bildtypen pro Release) |
| **AcoustID + Chromaprint** | Akustischer Fingerprint → Recording-MBID | Chromaprint **LGPL-2.1**; AcoustID-Web-Service: nicht-kommerziell frei, eigener API-Key | Server-seitig | Fingerprint-Lib offline nutzbar (fpcalc); Web-Lookup braucht Key. Nutzt vDSP-FFT auf macOS |
| **Discogs** | Reichste Editions-/Style-/Pressungsdaten, Mix-Versionen, Jahr | **Restriktive TOS**: kein Bulk/ML-Training; Bilder nur via authentifizierte Signatur-URLs | 60 req/min (auth), Bilder getrennt limitiert | Kommerzielle Nutzung „generell erlaubt, aber widerruflich"; Restricted Data (Bilder/User-Daten) **nicht** kommerziell. Daten-Dumps (CC0-Teil) existieren |
| **ListenBrainz** | Hörhistorie, kollaborative Empfehlungen, Artist-Similarity, Popularität | **CC0** | Header-basiert | Frei, auch kommerziell; Similarity-Daten noch lückenhaft |

**Cover über Apple/iTunes oder Amazon:**
- **iTunes Search API** liefert hochauflösende Cover (bis ~3000×3000+) per einfachem GET — technisch frei abrufbar, keine Authentifizierung. **Rechtlich:** Die Cover sind urheberrechtlich geschützt (Labels/Künstler); Apples API ist für „personal use"/zur Bewerbung von iTunes-Inhalten gedacht. Für eine private, lokale App zur eigenen Sammlung praktisch unproblematisch; eine kommerzielle Weiterverbreitung der Bilder ist es nicht. Apple phast iTunes aus → Ergebnisse zunehmend unzuverlässig.
- **Amazon:** Früher häufige Cover-Quelle; heute über Product-Advertising-API mit strengen Bedingungen (Affiliate-Pflicht) — für diesen Zweck nicht empfehlenswert. CAA ist die bevorzugte freie Alternative.

**Programmierbibliotheken (Tags + eingebettete Bilder):**
- **SFBAudioEngine** (MIT, sbooth): Swift/Obj-C, macOS+iOS+tvOS. Liest/schreibt Metadaten (`SFBAudioFile`), inkl. eingebetteter Bilder; sehr breite Decoder/Encoder. Bereits in Petrichor genutzt.
- **SwiftTagLib / SwiftTagLib.cpp** (Anywhere-Music-Player): Swift-Wrapper um TagLib v2.1 via C++-Interop; liest/schreibt `attachedPictures` (frontCover etc.). XCFramework für iOS/macOS.
- **TagLibSwift** (jeonghi): TagLib als XCFramework-SPM.
- **spfk-metadata** (ryanfrancesconi): TagLib + libsndfile + Core Audio, inkl. BEXT/Marker; >100 Tag-Keys; Kapitel-Parsing.
- **TagLib** selbst: De-facto-Standard (auch foobar2000, Cog, Clementine nutzen es).
- **Booklet-Scans (PDF/Bilder) an Alben binden:** Es gibt **keinen** Standard-Embed für mehrseitige Booklets in Audio-Tags (ID3 `APIC`/Vorbis `METADATA_BLOCK_PICTURE` können mehrere Bilder mit Typ-Codes wie „booklet" tragen, aber keine PDFs). Praktikabler, etablierter Weg: Booklet-PDFs/JPGs als Sidecar-Dateien im Album-Ordner (Konvention z.B. `booklet.pdf`, `artwork/`) und in der eigenen SQLite-DB referenzieren — genau das Muster, das Petrichor mit seinem BLOB-Artwork + Folder-Scan bereits nahelegt. PDF-Anzeige nativ über PDFKit (macOS/iOS).

### C) EMPFEHLUNG / ÄHNLICHKEIT (lokal, ohne Cloud-Abo)

**Lokale Audio-Feature-Extraktion:**
- **Essentia** (MTG/UPF, **AGPL-3.0**, proprietäre Lizenz auf Anfrage): C++ mit Python-/JS-Bindings, macOS/iOS-fähig. Liefert BPM, Key, Energie, Loudness, ~127 Deskriptoren; dazu **TensorFlow-Modelle** (Discogs-EffNet → 400 Genres/Styles; MSD-MusiCNN; Mood/Danceability/Aggressive). **Wichtig:** Vortrainierte MTG-Modelle sind **CC BY-NC-ND 4.0 (nur nicht-kommerziell)**; Essentia-Lib selbst AGPL → bei kommerzieller App Lizenzproblem, bei privater App ok.
- **librosa** (Python, ISC): MFCC, Spektren, Beat — gut zum Prototyping, nicht für eine native Swift-App in Produktion.
- **aubio** (GPL): Onset, BPM, Pitch — C-Lib, einbettbar.
- **Apple-Frameworks:** **Core ML** (Modell-Inferenz), **MLX** (Open-Source-Array-Framework für Apple Silicon, Swift-API, Unified Memory; ideal für eigene Modelle/Embeddings), **Create ML**, **SoundAnalysis** (klassifiziert Audio via vortrainierte/eigene Modelle). Diese passen am besten zur bestehenden Swift-KI-Engine des Nutzers.

**Offene Datensätze/Modelle für Genre/Stil/Szene + „kuratorische" statt akustische Nähe:**
- **AcousticBrainz** wurde im MetaBrainz-Blog am **16. Februar 2022** beendet angekündigt („AcousticBrainz: Making a hard decision to end the project"); Daten-Submissions wurden eingestellt, die Seite „in early 2023" abgeschaltet. Begründung von MetaBrainz selbst, im Wortlaut: *„We spent some time introducing content-based similarity to AcousticBrainz, but when we used this data ourselves for generating similar / recommended recordings, it didn't give good results."* Zur Datenqualität nannte MetaBrainz konkret: der BPM-Algorithmus sei nur *„correct about 80% of the time"*, die Daten könnten *„unable to indicate a confidence level"* sein, und insgesamt *„the data simply isn't of high enough quality to be useful for much at all."* Der komplette **7,5-Mio-Track-Dump bleibt verfügbar** als eingefrorener Fallback-Layer, mit diesen bekannten Schwächen.
- **Kuratorische Nähe** approximiert man am ehrlichsten **nicht** über reine Audio-Ähnlichkeit, sondern über:
  - **MusicBrainz-Relationen** (gleiche Künstler/Produzenten/Label/Serie, Remix-/Cover-/Live-Beziehungen, Release-Group-Typen, Jahr/Ära),
  - **Discogs-Styles** (feinere Substile als Genres, Editions-/Mix-Version-Infos),
  - **ListenBrainz** (kollaboratives Filtering via `/1/cf/recommendation/...`, Artist-Similarity über die Labs-API, Popularität — alles CC0),
  - plus lokale Essentia-Features nur als ergänzendes Signal (Energie, BPM, Länge, Loudness/„Mix-Version").
- **Album-Ebene + Ära/Länge/Mix/Energie/Szene:** Genau dieses zusammengesetzte Scoring (gewichtete Kombination aus Editions-Metadaten + Relationen + kollaborativen Daten + Audio-Features) ist **nirgends fertig** verfügbar — es ist die Kern-Eigenleistung des Projekts und der natürliche Einsatzort der eigenen Swift-KI-Engine (Bedeutungs-/Wichtigkeitsanalyse der Metadaten-Texte → Gewichtung von Relationen/Tags).
- **Ehrliche Grenzen im Long Tail:** Für seltene/obskure Alben fehlen ListenBrainz-Kollaborativdaten (zu wenige Hörer; die Artist-Similarity-Labs-API liefert für viele Künstler bereits heute keine oder nur Teilergebnisse), Discogs-Styles sind dann oft die einzige Substanz, und MusicBrainz-Relationen können dünn sein. Audio-Features funktionieren zwar immer, geben aber nur akustische, keine kuratorische Nähe. Realistisch: gute Empfehlungen im „Head", deutlich schwächere im Long Tail — das sollte die App transparent machen.

### D) VISUALIZER & SKIN/STYLING-SYSTEM

**Milkdrop-Linie (quelloffen):**
- **projectM / libprojectM** (**LGPL-2.1**): Cross-Platform-Reimplementierung von Milkdrop; parst Presets (Milkdrop-kompatibel; Default ist der „Cream of the Crop"-Pack mit ~10K Presets, optional der „MegaPack" mit 130k+ Presets / 4,08 GB inkl. Texturen), macht FFT/Beat-Detection auf PCM, rendert **ausschließlich über OpenGL bzw. OpenGL ES 3 — keinen Metal-Backend**. Aktuell: v4.1.6 (Nov 2025), neue stabile C-API; ein 4.1.x-Maintenance-Fix betraf gezielt macOS (*„Fix a linker/runtime issue on systems only providing core OpenGL 4.1 libraries or lower … This mainly affects macOS"*). Lizenz im Wortlaut: *„The core projectM library is released under the GNU Lesser General Public License 2.1 to keep any changes open-sourced, but also enable the use of libprojectM in closed-source applications (as a shared library) as long as the license terms are adhered to."* **Apple-Eignung:** Auf macOS läuft die GL-Linie nur über Apples **deprecated** OpenGL (seit 10.14; auf Apple Silicon intern auf Metal abgebildet) — funktioniert, ist aber Legacy. Es existiert ein **offizielles Apple-Music-Plugin für macOS** (unsigned Development Preview) und SDL2-/Rust-Standalone-Previews. **Kein offizieller iOS-Port / kein Metal-Port**; ein Metal/Vulkan-Backend ist nur ein offener Feature-Request (Issues #683/#681, WIP-PR #877). **Reales lokales Audiosignal einspeisen:** Ja — die Lib nimmt PCM-Buffer entgegen; man füttert sie mit den per AVAudioEngine-Tap gewonnenen Samples der eigenen Dateien (kein Loopback-Hack nötig, da man die Quelle selbst kontrolliert). Quelle: github.com/projectM-visualizer/projectm.
- **Butterchurn** (**MIT**): WebGL2-Port von Milkdrop (JS), sehr hohe Preset-Treue, von Webamp genutzt. Verbindet sich mit Web-Audio-`audioNode`. **Apple-Eignung:** Läuft in WKWebView; man kann den dekodierten Audiostream der lokalen Datei in einen Web-Audio-Kontext leiten oder Frequenzdaten per Bridge übergeben. Eleganter Weg, das fehlende Metal-Problem von projectM zu umgehen (WebGL2 läuft auf Apple-Geräten gut). Quelle: github.com/jberg/butterchurn.
- **Webamp** (MIT): Winamp-2.9-Reimplementierung in HTML5/JS inkl. Butterchurn-Milkdrop und **klassischem Winamp-Skin-System** (.wsz-Skins). Als Web-Komponente in WKWebView einbettbar; liefert sowohl Visualizer als auch ein fertiges, nostalgisches Skin-Modell. Quelle: docs.webamp.org.
- **MilkDrop3 / „eatme"-Butterchurn-Builds:** Windows-zentriert bzw. Web-Pakete; weniger relevant für Apple-nativ.

**Eigenes Skin-/Theming-System in SwiftUI/AppKit:**
- Es gibt **kein** etabliertes „Skin-Format" für SwiftUI wie bei Winamp/foobar2000. Der idiomatische Apple-Weg: ein **Theme-Modell** (Farb-/Font-/Spacing-Tokens) über die **SwiftUI-`Environment`** und `EnvironmentValues` injizieren, `ShapeStyle`/`Color`-Assets, `ViewModifier`-basierte Stil-Komponenten und benutzerdefinierte `ButtonStyle`/`ToggleStyle`. Für ladbare Nutzer-Skins bietet sich ein eigenes deklaratives Format (JSON/Property-List mit Farben/Bildern) an, das in das Theme-Environment gemappt wird. **Etablierte Muster:** Token-/Environment-basiertes Theming ist gängige Praxis, aber ein vollständiges „lade beliebige Community-Skins"-System muss man selbst bauen. Wer ein fertiges, nutzerdefinierbares Skin-System will, findet das nur im Webamp-Modell (Winamp-Skins) — über WKWebView integrierbar.

### E) RELEVANTE APPLE-RESTRIKTIONEN

- **Eigene, nicht-DRM-Dateien (gerippte CDs, eigene FLAC/MP3 etc.):** Voller Zugriff auf das **dekodierte PCM-Signal** ist erlaubt und vorgesehen. Über **AVAudioEngine** hängt man per `installTap(onBus:bufferSize:format:)` einen Tap an einen Node (z.B. mainMixerNode oder PlayerNode) und erhält `AVAudioPCMBuffer` (~alle 0,1 s; die reale Buffergröße kann von der angeforderten abweichen — Apple-Doku: „The implementation may choose another size"). Mit **Accelerate/vDSP** rechnet man daraus FFT/Spektrum → Visualizer-Input. Für niedrige Latenz/feste Buffergrößen ist alternativ ein **AUAudioUnit-Effect-Node** mit Pass-Through der saubere Weg.
- **Unterstützte Formate:** Über AVFoundation/Core Audio nativ MP3, AAC/ALAC, WAV, AIFF; mit SFBAudioEngine zusätzlich FLAC, Ogg Vorbis/Opus, Musepack, Monkey's Audio, WavPack, True Audio, DSD u.a.
- **Hintergrundwiedergabe:** Auf iOS via Audio-Background-Mode + AVAudioSession; auf macOS unkritisch. MediaPlayer-Framework für Lock-Screen/Now-Playing-Controls.
- **DRM-Grenze (zur Klarstellung):** Bei **DRM-geschützten Apple-Music-Streams** gibt es **keinen** öffentlichen Zugang zu Raw-PCM/FFT/Beat-Markern; MusicKit liefert nur Wiedergabe-APIs (von Entwicklern in den Apple-Foren bestätigt). DJ-Apps (djay, Serato, rekordbox) haben dafür ein spezielles Apple-Entitlement. **Für die Idee des Nutzers (ausschließlich eigene, nicht-DRM-Dateien) ist die Visualizer-/Analyse-Pipeline somit technisch und lizenzrechtlich uneingeschränkt zulässig.**

## Recommendations

**Stufe 1 — Fundament wählen und Audio/Tagging verdrahten (Wochen 1–4).**
- **Petrichor forken** (MIT, Swift/SwiftUI, bereits SFBAudioEngine + SQLite/GRDB, Schema mit MBID/Discogs-Feldern). Das spart das gesamte Gerüst (Scan, DB, Wiedergabe, Cover-BLOBs).
- Tagging-Pipeline: **SFBAudioEngine** (vorhanden) für Tag-/Bild-I/O; **Chromaprint/fpcalc** lokal für Fingerprints; **AcoustID + MusicBrainz** (CC0-Kerndaten) für Identifikation/Metadaten; **Cover Art Archive** für Cover/Booklet, mit iTunes-Search-API als Fallback.
- Booklets als **Sidecar-Dateien** im Album-Ordner + Referenz in der DB; Anzeige via **PDFKit**.
- *Benchmark zum Weitergehen:* Bibliothek scannt, identifiziert und zeigt Cover/Booklet für >90% der eigenen Alben korrekt.

**Stufe 2 — Visualizer + Theming (Wochen 5–8).**
- Schnellster Weg zum Milkdrop-Erlebnis: **Butterchurn oder Webamp in WKWebView**, gefüttert mit dem AVAudioEngine-Tap-Signal (umgeht projectMs fehlenden Metal-Backend). Wenn nativ Metal gewünscht: libprojectM über Apples OpenGL-Layer einbinden — funktioniert heute, ist aber Legacy-Risiko.
- Theming: SwiftUI-**Environment-basiertes Token-System**; optional Webamp-Skins (.wsz) für ein sofort nutzbares, nutzerdefinierbares Skin-Modell.
- *Benchmark:* Visualizer reagiert sichtbar auf reales lokales Audio; mind. ein umschaltbares Theme.

**Stufe 3 — Empfehlungssystem (Wochen 9+, das eigentliche Differenzierungsmerkmal).**
- Daten lokal spiegeln: **MusicBrainz-Dump** (umgeht Rate-Limit), **ListenBrainz**-Daten (CC0), **Discogs**-Styles (TOS beachten — privat ok).
- Lokale Audio-Features mit **Essentia** (privat/nicht-kommerziell) ODER eigenen **MLX/Core-ML**-Modellen (lizenzsauber, Apple-Silicon-optimiert) für Energie/BPM/Loudness/Länge/Mix-Heuristik.
- Die **eigene Swift-KI-Engine** auf Metadaten-Texte (Relationen, Tags, Liner-Notes) ansetzen, um Relationen/Styles zu gewichten → **gewichtetes Album-Scoring** (Ära/Jahr + Länge + Mix-Version + Energie + Szene/Relationen).
- *Benchmark / Wechsel-Schwelle:* Wenn ListenBrainz-Similarity für den eigenen Geschmack zu lückenhaft ist (Long Tail), stärker auf MusicBrainz-Relationen + Discogs-Styles gewichten; wenn Audio-Features dominieren, wird es „rein akustisch" — dann zurückregeln.

**Lizenz-Leitplanken:** Solange die App **privat/nicht-kommerziell** bleibt, sind AGPL (Essentia), CC-BY-NC (MusicBrainz-Genres, MTG-Modelle) und LGPL (projectM/Chromaprint) unproblematisch. Bei einer **kommerziellen** Veröffentlichung: MetaBrainz-Lizenz für Genre-Daten, kommerzielle Essentia-Lizenz bzw. Verzicht auf MTG-Modelle (eigene MLX-Modelle trainieren), Discogs-Bilder/Restricted-Data meiden, projectM als Shared Library linken (so erlaubt die LGPL-2.1 die Nutzung auch in Closed-Source-Apps).

## Caveats
- **Kein All-in-One-Projekt:** Die Integration aller fünf Säulen + das kuratierte Album-Empfehlungssystem existiert nirgends fertig — das ist die eigentliche Bauleistung.
- **projectM hat keinen Metal-Backend** (Stand v4.1.6); macOS-Betrieb hängt an Apples deprecated OpenGL. Langfristig ist Butterchurn/WebGL2 oder ein eigener Metal-Renderer robuster. Ein nativer iOS-projectM-Port fehlt.
- **Empfehlungsqualität im Long Tail ist prinzipiell begrenzt** (fehlende Kollaborativdaten); seit AcousticBrainz-Abschaltung gibt es keine fertige freie High-Level-Genre/Mood-Quelle mehr — und MetaBrainz selbst hat die alte AcousticBrainz-Mood/Genre-Qualität als unzureichend bezeichnet.
- **Lizenz-Fallstricke** bei kommerzieller Nutzung (AGPL/CC-BY-NC/Discogs-TOS) — bei privater Nutzung entschärft.
- **Discogs-API** ist restriktiv (Bilder nur via signierte URLs, ML-Training untersagt, kommerzielle Restricted-Data-Nutzung verboten); auf MusicBrainz/CAA als primäre freie Quelle setzen.
- **iTunes/Apple-Cover** sind urheberrechtlich geschützt; nur für private Nutzung unbedenklich, nicht weiterverbreitbar; iTunes wird ausgephast → Quelle wird unzuverlässiger.
- Einige Detailangaben (genaue aktuelle Sterne/Commit-Zahlen, exakte Versionsstände kleinerer Libraries) können sich seit Juni 2026 leicht verschoben haben.