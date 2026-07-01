# Musicae — Schema-Karte der Bibliotheksdatenbank

*Ergebnis von Phase 0 ([#2](https://github.com/christiandenzau/musicae/issues/2)). Eine Bestandsaufnahme: Was steckt heute schon in der Datenbank, bevor wir für die Empfehlung etwas hinzufügen? Quelle der Wahrheit ist der Code (GRDB-Schema + Modelle), nicht eine laufende DB-Datei.*

Stand: 2026-06-30 · Schema-Version: `v11` (siehe [Migrationshistorie](#7-migrationshistorie))

---

## 1. Wo die Datenbank liegt und wie Musicae sie liest

**Persistenzschicht:** [GRDB](https://github.com/groue/GRDB.swift) über eine einzelne `DatabaseQueue`. Es gibt genau eine zentrale Klasse [`DatabaseManager`](../Managers/Database/DatabaseManager.swift), deren domänenspezifische Logik auf `DM*.swift`-Erweiterungen verteilt ist (`DMQueries`, `DMMetadata`, `DMTrackProcessing`, …). Modelle sind GRDB-`FetchableRecord`/`PersistableRecord`-Structs/Classes unter [`Models/Core/`](../Models/Core/).

**Dateipfad** (`DatabaseManager.init`, [DatabaseManager.swift:24](../Managers/Database/DatabaseManager.swift)): Musicae läuft **App-Sandbox** (`ENABLE_APP_SANDBOX = YES` in beiden Build-Konfigurationen). Daher liefert `FileManager.default.url(for: .applicationSupportDirectory, …)` **nicht** das globale `~/Library/Application Support`, sondern das Application-Support-Verzeichnis **im Sandbox-Container**:

| Build | Bundle-ID | Datei (im Container) |
|---|---|---|
| Release | `org.Musicae` | `~/Library/Containers/org.Musicae/Data/Library/Application Support/org.Musicae/musicae.db` |
| Debug | `org.Musicae.debug` | `~/Library/Containers/org.Musicae.debug/Data/Library/Application Support/org.Musicae.debug/musicae-debug.db` |

Der innere Ordnername ist die Bundle-ID (`Bundle.main.bundleIdentifier`, Fallback `org.Musicae` aus [Constants.swift:96](../Utilities/Constants.swift)); der Dateiname hängt am `.debug`-Suffix der Bundle-ID. **Praxis-Hinweis:** Wer die DB von außen lesen will (z. B. ein Analyse-Tool), findet den exakten Pfad zur Laufzeit am zuverlässigsten via `lsof -p <pid> -Fn | grep musicae` — und sollte gegen eine **Kopie** (inkl. `-wal`/`-shm`) arbeiten, solange die App läuft (WAL-Lock).

**PRAGMA-Konfiguration** (bei jedem Verbindungsaufbau, `prepareDatabase`):
- `journal_mode = WAL` (Write-Ahead-Log; daneben liegen `-wal`- und `-shm`-Dateien)
- `synchronous = NORMAL`
- `busy_timeout = 5000` (ms)

**Migrationen:** GRDBs eingebautes `DatabaseMigrator`-System ([DatabaseMigration.swift](../Managers/Database/DatabaseMigration.swift)). Beim Start läuft `DatabaseMigrator.migrate(dbQueue)`. Das frische Initialschema baut [`DatabaseManager.setupDatabaseSchema(in:)`](../Managers/Database/DMSetup.swift) (Migration `v1`); spätere `v2…v11` ergänzen Spalten, Indizes und Tabellen. Zusätzlich gibt es **Hintergrund-Migrationen** ([DMBackgroundMigration.swift](../Managers/Database/DMBackgroundMigration.swift)), die über die Tabelle `background_migrations` getrackt werden (z. B. Artwork→HEIC, Künstler-Verknüpfungen neu aufbauen).

---

## 2. Tabellenübersicht

Das Schema kennt **14 echte Tabellen**, **1 FTS5-Virtualtabelle** und **3 Trigger**.

| Tabelle | Zweck | Primärschlüssel |
|---|---|---|
| `folders` | Beobachtete Bibliotheksordner (mit Security-Scoped Bookmark) | `id` (autoinc) |
| `artists` | Künstler-Entitäten inkl. externer IDs & Anreicherung | `id` (autoinc) |
| `albums` | Album-Entitäten inkl. externer IDs & Anreicherung | `id` (autoinc) |
| `album_artists` | Junction Album ↔ Künstler (mit Rolle/Position) | (`album_id`,`artist_id`,`role`) |
| `genres` | Genre-Lookup (nur Name) | `id` (autoinc) |
| `tracks` | **Die Titel — Kerntabelle.** Datei + Tags + Audio-Props + JSON | `id` (autoinc) |
| `playlists` | Manuelle & Smart-Playlists | `id` (Text/UUID) |
| `playlist_tracks` | Junction Playlist ↔ Titel (mit Position) | (`playlist_id`,`track_id`) |
| `track_artists` | Junction Titel ↔ Künstler (mit Rolle/Position) | (`track_id`,`artist_id`,`role`) |
| `track_genres` | Junction Titel ↔ Genre | (`track_id`,`genre_id`) |
| `pinned_items` | Angepinnte Einträge in der Seitenleiste | `id` (autoinc) |
| `artist_aliases` | Merge-Aliase Künstler (overleben Re-Import) | `normalized_alias` |
| `album_aliases` | Merge-Aliase Album (overleben Re-Import) | `normalized_key` |
| `background_migrations` | Status langlaufender Hintergrund-Migrationen | `identifier` |
| `track_fingerprints` | **Berechnete Audio-Achsen (BPMKit): BPM+Konfidenz, Lautheit, Dynamik, Helligkeit, Bass, Mix-Version** — 1:1 an `tracks` (v12) | `track_id` (=`tracks.id`) |
| `tracks_fts` | FTS5-Volltextindex über Titel-Textfelder | (extern, rowid=`tracks.id`) |

**Typ-Konvention** (GRDB → SQLite): `.text`→TEXT, `.integer`→INTEGER, `.double`→DOUBLE/REAL, `.boolean`→BOOLEAN (numerische Affinität), `.blob`→BLOB, `.datetime`→DATETIME (von GRDB als ISO-8601-Text gespeichert).

---

## 3. Die Kerntabelle `tracks`

Definiert in [`createTracksTable`](../Managers/Database/DMSetup.swift), gelesen/geschrieben über zwei Modelle:
- **[`FullTrack`](../Models/Core/FullTrack.swift)** — die *vollständige* Abbildung; mappt **alle** Spalten inkl. `bpm` und `extended_metadata`.
- **[`Track`](../Models/Core/Track.swift)** — eine *leichtgewichtige* Projektion für Listen; mappt bewusst **nicht** `bpm`, `extended_metadata`, `rating`, `compilation`, `file_size` u. a.

> ⚠️ **Wichtig für spätere Phasen:** Wer Achsen/Fingerprints oder MBIDs auf Titelebene liest oder schreibt, muss über `FullTrack` gehen (oder rohes SQL). Das schlanke `Track` sieht diese Felder nicht.

| Spalte | Typ | Constraints / Default | Bemerkung |
|---|---|---|---|
| `id` | INTEGER | PK autoinc | |
| `folder_id` | INTEGER | NOT NULL, FK→`folders` (CASCADE) | Herkunftsordner |
| `album_id` | INTEGER | FK→`albums` (SET NULL) | Verknüpftes Album (nullable) |
| `path` | TEXT | NOT NULL, **UNIQUE** | **Dateipfad** (absolut) |
| `filename` | TEXT | NOT NULL | Dateiname (indiziert ab v10) |
| `title` | TEXT | | Titel |
| `artist` | TEXT | | Künstler (denormalisiert) |
| `album` | TEXT | | Albumtitel (denormalisiert) |
| `composer` | TEXT | | Komponist |
| `genre` | TEXT | | Genre (denormalisiert, Einzelstring) |
| `year` | TEXT | | **Jahr als Text** (nicht Integer!) |
| `duration` | DOUBLE | CHECK ≥ 0 | **Dauer** in Sekunden |
| `format` | TEXT | | Container/Endung (z. B. „mp3") |
| `file_size` | INTEGER | | Bytes |
| `date_added` | DATETIME | NOT NULL | |
| `date_modified` | DATETIME | | |
| `track_artwork_data` | BLOB | | Eingebettetes Cover des Titels |
| `is_favorite` | BOOLEAN | NOT NULL, default 0 | |
| `play_count` | INTEGER | NOT NULL, default 0 | Wachsendes Signal |
| `last_played_date` | DATETIME | | Wachsendes Signal |
| `is_duplicate` | BOOLEAN | NOT NULL, default 0 | Duplikat-Tracking |
| `primary_track_id` | INTEGER | FK→`tracks.id` (SET NULL) | „Original" eines Duplikats |
| `duplicate_group_id` | TEXT | | Duplikat-Gruppe |
| `album_artist` | TEXT | | **Albumkünstler** |
| `track_number` | INTEGER | | |
| `total_tracks` | INTEGER | | |
| `disc_number` | INTEGER | | |
| `total_discs` | INTEGER | | |
| `rating` | INTEGER | CHECK 0–5 | |
| `compilation` | BOOLEAN | default 0 | **Compilation-Kennzeichen** |
| `release_date` | TEXT | | |
| `original_release_date` | TEXT | | |
| `bpm` | INTEGER | | **BPM — aus Tags, siehe §6** |
| `media_type` | TEXT | | z. B. Musik/Hörbuch/Podcast |
| `bitrate` | INTEGER | CHECK > 0 | Audio-Property |
| `sample_rate` | INTEGER | | Audio-Property |
| `channels` | INTEGER | | Audio-Property |
| `codec` | TEXT | | Audio-Property |
| `bit_depth` | INTEGER | | Audio-Property |
| `lossless` | BOOLEAN | (v5) | |
| `sort_title` | TEXT | | |
| `sort_artist` | TEXT | | |
| `sort_album` | TEXT | | |
| `sort_album_artist` | TEXT | | |
| `extended_metadata` | TEXT | | **JSON-Blob, siehe §5** |

---

## 4. Empfehlungsrelevante Felder — vorhanden / fehlt / nur indirekt

Die Felder, die die spätere Empfehlungslogik trägt (laut [#2](https://github.com/christiandenzau/musicae/issues/2)):

| Benötigtes Feld | Status | Ort |
|---|---|---|
| Titel | ✅ vorhanden | `tracks.title` |
| Künstler | ✅ vorhanden | `tracks.artist` (Text) + Entität `artists` via `track_artists` |
| Album | ✅ vorhanden | `tracks.album` (Text) + Entität `albums` via `album_id` |
| Albumkünstler | ✅ vorhanden | `tracks.album_artist` (Text) |
| Jahr | ✅ vorhanden | `tracks.year` ⚠️ **als TEXT**; zuverlässiges Jahr auf `albums.release_year` (INTEGER) |
| Genre | ✅ vorhanden | `tracks.genre` (Einzelstring) + Mehrfach via `track_genres`/`genres` |
| Dauer | ✅ vorhanden | `tracks.duration` (DOUBLE, Sek.) |
| Dateipfad | ✅ vorhanden | `tracks.path` (UNIQUE) |
| Compilation-Kennzeichen | ✅ vorhanden | `tracks.compilation` (Bool) + `albums.album_type` |
| MusicBrainz-ID (Künstler) | ✅ vorhanden | `artists.musicbrainz_id` (eigene Spalte) |
| MusicBrainz-ID (Album/Release) | ✅ vorhanden | `albums.musicbrainz_id` (eigene Spalte) |
| **MusicBrainz-ID (Recording/Titel)** | 🟡 **nur indirekt** | `tracks.extended_metadata` → JSON-Feld `musicBrainzTrackId` (= Recording-MBID, siehe §6) |
| Discogs-ID (Künstler/Album) | ✅ vorhanden | `artists.discogs_id`, `albums.discogs_id` |
| **Discogs-ID (Titel)** | ❌ fehlt | keine Track-Discogs-ID; nur indirekt über Album/Künstler |
| **Berechnete Audio-Achsen** (LUFS, Dynamik, Spektralhelligkeit, Bass, MFCC, Embedding) | ❌ fehlt | keine Spalte/Tabelle — kommt in Phase 2 ([#5](https://github.com/christiandenzau/musicae/issues/5)) |
| **Mix-Version** (Extended/Radio/Club) | 🟡 nur indirekt | steckt im `title`-Text; kein strukturiertes Feld |
| **Beliebtheit / Chart-Daten** | ❌ fehlt | keine Spalte; bewusst noch nicht modelliert |

**Faustregel:** Auf **Entitätsebene** (`artists`, `albums`) sind die externen IDs erstklassige, indizierbare Spalten. Auf **Titelebene** (`tracks`) sind sie es **nicht** — dort liegt alles Externe im `extended_metadata`-JSON.

---

## 5. Das `extended_metadata`-JSON ([`ExtendedMetadata`](../Models/Core/ExtendedMetadata.swift))

`tracks.extended_metadata` ist ein TEXT-Feld mit einem JSON-serialisierten `ExtendedMetadata`-Struct (sortierte Schlüssel). Nur über `FullTrack` zugänglich. Es enthält genau die titelgenauen Fakten, die kein eigenes Spaltenkorsett haben — relevant für die Phasen 1–4:

- **MusicBrainz-IDs (titelgenau):** `musicBrainzTrackId` (≙ **Recording**-MBID, siehe §6), `musicBrainzReleaseGroupId`, `musicBrainzWorkId`, `musicBrainzArtistId`, `musicBrainzAlbumId`, `musicBrainzAlbumArtistId`
- **Akustischer Fingerprint (extern):** `acoustId`, `acoustIdFingerprint` — der AcoustID/Chromaprint-Fingerprint, falls vom Tagger (z. B. Picard) geschrieben
- **Weitere IDs:** `isrc`, `barcode`, `catalogNumber`
- **Deskriptiv:** `key` (Tonart), `mood`, `language`, `lyrics`, `comment`, `grouping`, `movement`
- **Technisch:** `replayGainTrack`, `replayGainAlbum`, `encodedBy`, `encoderSettings`
- **Credits:** `producer`, `engineer`, `remixer`, `lyricist`, `conductor`, `originalArtist`, `performer`
- **Sonstiges:** `recordingDate`, Podcast-/iTunes-Felder, `customFields` (frei erweiterbar)

> 🔎 **Konsequenz für die Abfrage:** Felder im JSON sind **nicht indiziert und nicht per SQL-Spalte filterbar** ohne JSON-Extraktion. Wer titelgenaue MBIDs oder einen vorhandenen AcoustID-Fingerprint für die Phasen 2/4 verlässlich abfragen will, sollte erwägen, sie in eigene (indizierte) Spalten oder eine Fingerprint-Tabelle zu heben (genau das Thema von [#5](https://github.com/christiandenzau/musicae/issues/5)).

---

## 6. Sonderfall BPM und MBID auf Titel-/Recording-Ebene (AK4)

**BPM:**
- Es gibt **ein** Feld: `tracks.bpm` (INTEGER), gemappt nur in `FullTrack.bpm: Int?`.
- Es wird beim Import **aus den Tags** gefüllt: `track.bpm = metadata.bpm` ([DMMetadata.swift:40](../Managers/Database/DMMetadata.swift)), Quelle sind die Metadaten-Reader ([SFBMetadataReader](../Core/Metadata/SFBMetadataReader.swift), [CrescendoMetadataReader](../Core/Metadata/CrescendoMetadataReader.swift)).
- Es ist damit ein **getaggtes**, kein **berechnetes** BPM. Eine Confidence, eine Quelle („getaggt vs. selbst gerechnet") oder ein separates Feld für den BPM-**Schätzer** aus Phase 2 ([#4](https://github.com/christiandenzau/musicae/issues/4)) **existiert nicht**. Beim Bau des Schätzers ist zu entscheiden: dieses Feld überschreiben/ergänzen oder ein neues, quellenbewusstes Feld anlegen (passt zum Ehrlichkeitsgesetz aus dem [Datenmodell-Dokument](Musicae_Datenmodell_und_Empfehlungslogik.md)).

**MBID auf Recording-/Titelebene:**
- **Keine eigene Spalte** in `tracks`. Vorhanden ist sie **nur indirekt** im `extended_metadata`-JSON als `musicBrainzTrackId`.
- Dass dies die **Recording**-MBID ist, belegt das Import-Mapping: `metadata.extended.musicBrainzTrackId = source.musicBrainzRecordingID` ([CrescendoMetadataReader.swift:114](../Core/Metadata/CrescendoMetadataReader.swift)). Für den MusicBrainz-Graphen ([#7](https://github.com/christiandenzau/musicae/issues/7)) ist die Recording-MBID der zentrale Anker — sie ist also dem Prinzip nach da, aber unbequem (im JSON, nicht indiziert, nur via `FullTrack`).
- ⚠️ **Terminologie-Vorsicht:** In der MusicBrainz/Picard-Welt ist „MusicBrainz Track Id" konventionell die *Recording*-ID, während die echte *Release-Track*-ID separat ist. Hier folgt der Code dieser Konvention (Feldname `…TrackId`, Inhalt = Recording-ID). Beim Graphen-Bau das Mapping einmal an echten Tags verifizieren.

---

## 7. Migrationshistorie

Reihenfolge aus [DatabaseMigration.swift](../Managers/Database/DatabaseMigration.swift):

| Version | Inhalt |
|---|---|
| `v1_initial_schema` | Komplettes Startschema via `setupDatabaseSchema` (alle Tabellen, Indizes, FTS, Seed-Daten) |
| `v2_add_folder_content_hash` | `folders.shasum_hash` (TEXT) |
| `v3_add_category_query_indices` | Composite-Indizes (track_artists, duplikat-bewusste tracks-Indizes, album_artists); Recalc der Künstler-Trackzahlen |
| `v4_rebuild_fts_with_unicode61_tokenizer` | FTS neu mit `unicode61`-Tokenizer (ohne Porter-Stemming) |
| `v5_add_lossless_column` | `tracks.lossless` (BOOLEAN) |
| `v6_update_most_played_criteria` | Smart-Kriterium „Most Played" angepasst |
| `v7_create_background_migrations_table` | Tabelle `background_migrations` |
| `v8_convert_artwork_to_heic` | Flag für Hintergrund-Migration (Artwork→HEIC) |
| `v9_rebuild_artist_associations` | Flag für Hintergrund-Migration (Künstler-Verknüpfungen) |
| `v10_add_filename_index_and_drop_pinned_icon_name` | Index `idx_tracks_filename`; `pinned_items.icon_name` entfernt |
| `v11_add_merge_support` | Tabellen `artist_aliases` & `album_aliases` + Indizes; Backfill `album_id` auf Album-Pins |
| `v12_add_track_fingerprints_table` | Tabelle `track_fingerprints` (1:1 an `tracks`, FK/Cascade); flaggt den resumablen Hintergrundlauf `v12_background_compute_fingerprints` (BPMKit-Analyse der Bibliothek) |

Neue Migrationen werden als `v13_…` in `setupMigrator()` ergänzt (Marker „Future Migrations" am Ende der Funktion).

---

## 8. Referenz: Entitäts- und Hilfstabellen (Spalten kompakt)

### `artists` ([Artist.swift](../Models/Core/Artist.swift))
`id` (PK) · `name`* · `normalized_name`* (UNIQUE-Index) · `sort_name` · `artwork_data` (BLOB) · **Anreicherung:** `bio`, `bio_source`, `bio_updated_at`, `image_url`, `image_source`, `image_updated_at` · **Externe IDs:** `discogs_id`, `musicbrainz_id`, `spotify_id`, `apple_music_id` · **Meta:** `country`, `formed_year`, `disbanded_year`, `genres` (JSON), `websites` (JSON), `members` (JSON) · **Stats:** `total_tracks`* (≥0), `total_albums`* (≥0) · `created_at`*, `updated_at`*  *(*=NOT NULL)*

### `albums` ([Album.swift](../Models/Core/Album.swift))
`id` (PK) · `title`* · `normalized_title`* · `sort_title` · `artwork_data` (BLOB) · **Meta:** `release_date` (TEXT), `release_year` (INT, CHECK 1900–2100), `album_type`, `total_tracks` (≥0), `total_discs` (≥0) · **Anreicherung:** `description`, `review`, `review_source`, `cover_art_url`, `thumbnail_url` · **Externe IDs:** `discogs_id`, `musicbrainz_id`, `spotify_id`, `apple_music_id` · **Meta:** `label`, `catalog_number`, `barcode`, `genres` (JSON) · `created_at`*, `updated_at`*

### `folders` ([Folder.swift](../Models/Core/Folder.swift))
`id` (PK) · `name`* · `path`* (UNIQUE) · `track_count`* (default 0) · `date_added`* · `date_updated`* · `bookmark_data` (BLOB, Security-Scoped Bookmark) · `shasum_hash` (TEXT, v2)

### `genres` ([Genre.swift](../Models/Core/Genre.swift))
`id` (PK) · `name`* (UNIQUE) — reines Lookup; die Zuordnung lebt in `track_genres`.

### `playlists` ([Playlist.swift](../Models/Core/Playlist.swift))
`id` (PK, **TEXT/UUID**) · `name`* · `type`* (manual/smart) · `is_user_editable`* · `is_content_editable`* · `date_created`* · `date_modified`* · `cover_artwork_data` (BLOB) · `smart_criteria` (TEXT/JSON) · `sort_order`* (default 0)

### `pinned_items` ([PinnedItem.swift](../Models/Core/PinnedItem.swift))
`id` (PK) · `item_type`* (library/playlist) · `filter_type` · `filter_value` · `entity_id` · `artist_id` · `album_id` · `playlist_id` · `display_name`* · `subtitle` · `sort_order`* · `date_added`* *(`icon_name` in v10 entfernt)*

### Junction-Tabellen
- **`album_artists`** ([AlbumArtist.swift](../Models/Core/AlbumArtist.swift)): `album_id`→albums, `artist_id`→artists, `role`* (default „primary"), `position`* — PK (`album_id`,`artist_id`,`role`)
- **`track_artists`** ([TrackArtist.swift](../Models/Core/TrackArtist.swift)): `track_id`→tracks, `artist_id`→artists, `role`* (default „artist"), `position`* — PK (`track_id`,`artist_id`,`role`)
- **`track_genres`** ([TrackGenre.swift](../Models/Core/TrackGenre.swift)): `track_id`→tracks, `genre_id`→genres — PK (`track_id`,`genre_id`)
- **`playlist_tracks`** ([PlaylistTrack.swift](../Models/Core/PlaylistTrack.swift)): `playlist_id`→playlists, `track_id`→tracks, `position`*, `date_added`* — PK (`playlist_id`,`track_id`)

### Merge-Aliase (v11, [AlbumAlias.swift](../Models/Core/AlbumAlias.swift) / [ArtistAlias.swift](../Models/Core/ArtistAlias.swift))
- **`artist_aliases`**: `normalized_alias` (PK), `display_name`*, `canonical_artist_id`*→artists, `created_at`*
- **`album_aliases`**: `normalized_key` (PK), `display_title`*, `canonical_album_id`*→albums, `created_at`*

Beide bilden „alter Name → kanonische Entität" ab, damit manuelle Merges einen Re-Import überleben. Maschinen-lokal, vom Datenexport ausgenommen.

### `background_migrations` (v7)
`identifier` (PK) · `completed_at` · `progress` · `resumable` (default 1)

### `track_fingerprints` (v12, [ComputedFingerprint.swift](../Models/Core/ComputedFingerprint.swift))
`track_id` (PK, FK→`tracks`, `ON DELETE CASCADE`) · `calculated_bpm` · `bpm_confidence` · `rms_loudness_db`* · `dynamic_range_db`* · `spectral_brightness_hz`* · `bass_ratio`* · `mix_version` · `analyzed_at`* *(*=NOT NULL)*

Die **berechnete** (nicht getaggte) Achsenschicht aus `BPMKit`, 1:1 an `tracks` gekoppelt. Quellenbewusst getrennt vom getaggten `tracks.bpm` (§6, Ehrlichkeitsgesetz): der Schätzer landet hier und überschreibt den Tag nie. Gefüllt vom resumablen Hintergrundlauf `v12_background_compute_fingerprints` ([DMFingerprintAnalysis.swift](../Managers/Database/DMFingerprintAnalysis.swift)). Löst die in §5/§9 empfohlene Hebung der titelgenauen Achsen aus der separaten `fingerprints.db` in die App-DB.

### `tracks_fts` (FTS5-Virtualtabelle)
Spalten: `track_id` (not indexed), `title`, `artist`, `album`, `album_artist`, `composer`, `genre`, `year`. Tokenizer `unicode61` (ohne Porter, ab v4). `rowid` = `tracks.id`. Synchron gehalten über die Trigger `tracks_fts_insert` / `tracks_fts_update` / `tracks_fts_delete`.

---

## 9. Fazit für die nächsten Phasen

1. **Die harte Faktenschicht ist solide vorhanden:** Titel, Künstler, Album, Albumkünstler, Genre, Dauer, Jahr, Compilation, Dateipfad — plus echte Entitäten mit MBID/Discogs-IDs auf Künstler- und Album-Ebene. Das trägt die „gleiche Liga / gleiche Welt"-Kanten weitgehend schon heute.
2. **Was für die akustische Schicht fehlt, fehlt vollständig:** keine berechneten Achsen (LUFS, Dynamik, Spektralhelligkeit, Bass, MFCC, Embedding), kein quellenbewusstes BPM. Das ist Neuland für [#4](https://github.com/christiandenzau/musicae/issues/4) (BPM-Schätzer) und [#5](https://github.com/christiandenzau/musicae/issues/5) (Achsen + Fingerprint-Tabelle) — sinnvollerweise als **eigene Tabelle** statt weiterer `tracks`-Spalten.
3. **Titelgenaue Externdaten sind „da, aber unbequem":** Recording-MBID und AcoustID-Fingerprint leben im `extended_metadata`-JSON, nicht indiziert, nur via `FullTrack`. Für den Graphen ([#7](https://github.com/christiandenzau/musicae/issues/7)) und verlässliche Abfragen wird man die titelgenauen IDs voraussichtlich in indizierte Spalten/Tabellen heben wollen.
4. **`year` ist Text, `album.release_year` ist Integer.** Für jahresbasierte Abfragen („Pop von 95", „nicht 70er") ist `albums.release_year` die saubere Quelle; `tracks.year` muss man tolerant parsen.

Siehe begleitend: [Musicae_Datenmodell_und_Empfehlungslogik.md](Musicae_Datenmodell_und_Empfehlungslogik.md) (das Wie der Daten) und [Musicae_Umsetzungsplan.md](Musicae_Umsetzungsplan.md) (die Phasen).
