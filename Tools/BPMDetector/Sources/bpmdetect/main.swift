//
// bpmdetect — CLI-Frontend des nativen BPM-Schätzers.
//
// Nutzung:
//   bpmdetect <datei>            BPM einer einzelnen Audiodatei
//   bpmdetect <ordner>           je Datei im Ordner den BPM (Testmodus)
//   bpmdetect --selftest         synthetische Beats prüfen (ohne Dateien)
//
// Optionen:
//   --bass [hz]   Onset-Messung auf Bass/untere Mitten fokussieren (Default 250)
//   --min <bpm>   untere Bandgrenze (Default 120)
//   --max <bpm>   obere Bandgrenze (Default 150)
//   --help        diese Hilfe
//
// Bewusst ohne Fremd-Dependencies (auch kein ArgumentParser): ein Werkzeug,
// eine Sprache, kein Ballast.
//

import AVFoundation
import BPMKit
import Foundation

// MARK: - Argumente

struct Options {
    var paths: [String] = []
    var selfTest = false
    var fingerprint = false
    var dbPath: String?
    var help = false
    var onsetBand: OnsetBand = .full
    var minBPM = 120.0
    var maxBPM = 150.0
}

func parseArguments(_ args: [String]) -> Options {
    var options = Options()
    var index = 0
    while index < args.count {
        let arg = args[index]
        switch arg {
        case "--help", "-h":
            options.help = true
        case "--selftest":
            options.selfTest = true
        case "fingerprint":
            options.fingerprint = true
        case "--db":
            if index + 1 < args.count {
                options.dbPath = args[index + 1]
                index += 1
            }
        case "--bass":
            // Optionaler Hz-Wert als nächstes Argument.
            var maxHz = 250.0
            if index + 1 < args.count, let value = Double(args[index + 1]) {
                maxHz = value
                index += 1
            }
            options.onsetBand = .lowFrequency(maxHz: maxHz)
        case "--min":
            if index + 1 < args.count, let value = Double(args[index + 1]) {
                options.minBPM = value
                index += 1
            }
        case "--max":
            if index + 1 < args.count, let value = Double(args[index + 1]) {
                options.maxBPM = value
                index += 1
            }
        default:
            options.paths.append(arg)
        }
        index += 1
    }
    return options
}

func printUsage() {
    print("""
    bpmdetect — nativer BPM-Schätzer (Musicae, Phase 2)

    Nutzung:
      bpmdetect <datei>               BPM einer einzelnen Audiodatei
      bpmdetect <ordner>              je Datei im Ordner den BPM (Testmodus)
      bpmdetect --selftest            synthetische Beats prüfen (ohne Dateien)
      bpmdetect fingerprint <ordner>  Achsen je Titel rekursiv berechnen und
                                      als Fingerprint-Zeile persistieren (#5)

    Optionen:
      --db <pfad>   Ziel-SQLite-Datei für fingerprint (Default ./fingerprints.db)
      --bass [hz]   Onset auf Bass/untere Mitten fokussieren (Default 250 Hz)
      --min <bpm>   untere Bandgrenze (Default 120)
      --max <bpm>   obere Bandgrenze (Default 150)
      --help        diese Hilfe
    """)
}

// MARK: - Hilfsfunktionen

let audioExtensions: Set<String> = [
    "mp3", "m4a", "aac", "wav", "wave", "aif", "aiff", "aifc",
    "flac", "ogg", "oga", "opus", "caf", "alac", "mp4"
]

/// Liest den im Tag hinterlegten BPM (falls vorhanden) zum Abgleich.
func taggedBPM(url: URL) async -> Double? {
    let asset = AVURLAsset(url: url)
    guard let metadata = try? await asset.load(.metadata) else { return nil }
    for item in metadata {
        guard let identifier = item.identifier else { continue }
        guard identifier == .id3MetadataBeatsPerMinute
            || identifier == .iTunesMetadataBeatsPerMin else { continue }
        if let number = try? await item.load(.numberValue) {
            return number.doubleValue
        }
        if let string = try? await item.load(.stringValue),
           let value = Double(string.trimmingCharacters(in: .whitespaces)) {
            return value
        }
    }
    return nil
}

/// Liest den im Tag hinterlegten Titel (für das Mix-Version-Parsing). Fällt
/// auf den Dateinamen ohne Endung zurück, falls kein Titel-Tag vorhanden ist.
func trackTitle(url: URL) async -> String? {
    let asset = AVURLAsset(url: url)
    if let common = try? await asset.load(.commonMetadata) {
        let titleItems = AVMetadataItem.metadataItems(from: common, filteredByIdentifier: .commonIdentifierTitle)
        if let item = titleItems.first, let value = try? await item.load(.stringValue), !value.isEmpty {
            return value
        }
    }
    return url.deletingPathExtension().lastPathComponent
}

func makeEstimator(_ options: Options) -> BPMEstimator {
    BPMEstimator(minBPM: options.minBPM, maxBPM: options.maxBPM, onsetBand: options.onsetBand)
}

func analyzeFile(_ url: URL, estimator: BPMEstimator) -> BPMEstimate? {
    guard let samples = try? AudioLoader.loadMonoSamples(url: url) else { return nil }
    return estimator.estimate(samples: samples, sampleRate: AudioLoader.defaultSampleRate)
}

func pad(_ string: String, to width: Int) -> String {
    string.count >= width ? string : string + String(repeating: " ", count: width - string.count)
}

func leftPad(_ string: String, to width: Int) -> String {
    string.count >= width ? string : String(repeating: " ", count: width - string.count) + string
}

// MARK: - Modi

func runSingleFile(_ url: URL, options: Options) async {
    let estimator = makeEstimator(options)
    guard let estimate = analyzeFile(url, estimator: estimator) else {
        FileHandle.standardError.write(Data("Fehler: \(url.lastPathComponent) konnte nicht analysiert werden\n".utf8))
        exit(1)
    }
    let tagged = await taggedBPM(url: url)
    var line = String(format: "%@: %.1f BPM (Konfidenz %.2f)", url.lastPathComponent, estimate.bpm, estimate.confidence)
    if let tagged {
        line += String(format: " — getaggt %.0f, Δ %+.1f", tagged, estimate.bpm - tagged)
    }
    print(line)
}

func runFolder(_ url: URL, options: Options) async {
    let estimator = makeEstimator(options)
    let fileManager = FileManager.default
    guard let entries = try? fileManager.contentsOfDirectory(
        at: url,
        includingPropertiesForKeys: nil,
        options: [.skipsHiddenFiles]
    ) else {
        FileHandle.standardError.write(Data("Fehler: Ordner \(url.path) nicht lesbar\n".utf8))
        exit(1)
    }

    let audioFiles = entries
        .filter { audioExtensions.contains($0.pathExtension.lowercased()) }
        .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }

    guard !audioFiles.isEmpty else {
        print("Keine Audiodateien in \(url.path)")
        return
    }

    print(pad("Datei", to: 44) + leftPad("Geschätzt", to: 11) + leftPad("Konfidenz", to: 11)
        + leftPad("Getaggt", to: 9) + leftPad("Δ", to: 8))
    print(String(repeating: "-", count: 83))

    var deviations: [Double] = []
    for file in audioFiles {
        guard let estimate = analyzeFile(file, estimator: estimator) else {
            print(pad(String(file.lastPathComponent.prefix(43)), to: 44) + leftPad("—", to: 11))
            continue
        }
        let tagged = await taggedBPM(url: file)
        var row = pad(String(file.lastPathComponent.prefix(43)), to: 44)
        row += leftPad(String(format: "%.1f", estimate.bpm), to: 11)
        row += leftPad(String(format: "%.2f", estimate.confidence), to: 11)
        if let tagged {
            row += leftPad(String(format: "%.0f", tagged), to: 9)
            let delta = estimate.bpm - tagged
            row += leftPad(String(format: "%+.1f", delta), to: 8)
            deviations.append(abs(delta))
        } else {
            row += leftPad("—", to: 9) + leftPad("—", to: 8)
        }
        print(row)
    }

    if !deviations.isEmpty {
        let mean = deviations.reduce(0, +) / Double(deviations.count)
        let maxDev = deviations.max() ?? 0
        print(String(repeating: "-", count: 83))
        print(String(format: "Gegen getaggten BPM: \(deviations.count) Titel, |Δ| Ø %.2f, max %.2f", mean, maxDev))
    }
}

func runSelfTest(options: Options) {
    print("Selbsttest — synthetische Beats durch die volle Pipeline\n")
    let tempos: [Double] = [120, 124, 128, 132, 138, 140, 145, 150]
    let bands: [(String, OnsetBand)] = [("voll", .full), ("bass≤250Hz", .lowFrequency(maxHz: 250))]

    var worst = 0.0
    var allPassed = true

    for (label, band) in bands {
        print("Onset-Band: \(label)")
        print(pad("  Soll", to: 10) + leftPad("Ist", to: 10) + leftPad("Δ", to: 10) + leftPad("Konfidenz", to: 12))
        let estimator = BPMEstimator(minBPM: options.minBPM, maxBPM: options.maxBPM, onsetBand: band)
        for tempo in tempos {
            let signal = ClickTrackGenerator.make(bpm: tempo, durationSeconds: 20)
            guard let estimate = estimator.estimate(samples: signal, sampleRate: AudioLoader.defaultSampleRate) else {
                print(pad("  \(Int(tempo))", to: 10) + leftPad("FEHLER", to: 10))
                allPassed = false
                continue
            }
            let delta = estimate.bpm - tempo
            worst = max(worst, abs(delta))
            if abs(delta) > 1.5 { allPassed = false }
            print(pad("  \(Int(tempo))", to: 10)
                + leftPad(String(format: "%.1f", estimate.bpm), to: 10)
                + leftPad(String(format: "%+.2f", delta), to: 10)
                + leftPad(String(format: "%.2f", estimate.confidence), to: 12))
        }
        print("")
    }

    print(String(format: "Größte Abweichung: %.2f BPM", worst))
    if allPassed {
        print("✓ Selbsttest bestanden (alle Abweichungen ≤ 1.5 BPM)")
    } else {
        print("✗ Selbsttest NICHT bestanden")
        exit(1)
    }
}

// MARK: - Fingerprint-Modus (#5)

/// Analysiert eine Datei zu einem Fingerprint (BPM + Achsen + Mix-Version),
/// ohne zu persistieren. CPU-lastig (Dekodieren + FFT) — wird begrenzt parallel
/// aufgerufen. Eine Datei wird genau einmal dekodiert und trägt beide Analysen.
func analyzeOne(
    _ url: URL,
    bpmEstimator: BPMEstimator,
    axesAnalyzer: AudioAxesAnalyzer,
    analyzedAt: Date
) async -> TrackFingerprint? {
    guard let samples = try? AudioLoader.loadMonoSamples(url: url) else { return nil }
    let sampleRate = AudioLoader.defaultSampleRate
    guard let axes = axesAnalyzer.analyze(samples: samples, sampleRate: sampleRate) else { return nil }

    let bpm = bpmEstimator.estimate(samples: samples, sampleRate: sampleRate)
    let title = await trackTitle(url: url)
    let mixVersion = title.flatMap { MixVersionParser.parse(title: $0) }
    let duration = Double(samples.count) / sampleRate

    return TrackFingerprint(
        path: url.path,
        title: title,
        durationSeconds: duration,
        bpm: bpm?.bpm,
        bpmConfidence: bpm?.confidence,
        axes: axes,
        mixVersion: mixVersion,
        analyzedAt: analyzedAt
    )
}

/// Sammelt rekursiv alle Audiodateien unter `folder`. Synchron, weil sich der
/// `DirectoryEnumerator` nicht aus einem async-Kontext iterieren lässt.
/// `nil` = Ordner nicht lesbar, `[]` = lesbar, aber keine Audiodateien.
func collectAudioFiles(in folder: URL) -> [URL]? {
    guard let enumerator = FileManager.default.enumerator(
        at: folder,
        includingPropertiesForKeys: nil,
        options: [.skipsHiddenFiles]
    ) else {
        return nil
    }
    var audioFiles: [URL] = []
    for case let url as URL in enumerator where audioExtensions.contains(url.pathExtension.lowercased()) {
        audioFiles.append(url)
    }
    return audioFiles
}

func runFingerprint(_ folder: URL, options: Options) async {
    let dbPath = options.dbPath ?? "fingerprints.db"
    let store: FingerprintStore
    do {
        store = try FingerprintStore(path: dbPath)
    } catch {
        FileHandle.standardError.write(Data("Fehler: Fingerprint-DB \(dbPath) nicht nutzbar: \(error)\n".utf8))
        exit(1)
    }

    // Rekursiv alle Audiodateien einsammeln — die Testscheibe hat Albumordner.
    guard var audioFiles = collectAudioFiles(in: folder) else {
        FileHandle.standardError.write(Data("Fehler: Ordner \(folder.path) nicht lesbar\n".utf8))
        exit(1)
    }
    audioFiles.sort { $0.path.localizedStandardCompare($1.path) == .orderedAscending }

    guard !audioFiles.isEmpty else {
        print("Keine Audiodateien in \(folder.path)")
        return
    }

    print("Fingerprint-Lauf über \(audioFiles.count) Titel → \(dbPath)")
    let bpmEstimator = makeEstimator(options)
    let axesAnalyzer = AudioAxesAnalyzer()
    let analyzedAt = Date()
    let maxConcurrent = max(2, ProcessInfo.processInfo.activeProcessorCount - 1)
    let total = audioFiles.count

    var processed = 0
    var failed = 0

    // Gleitendes Fenster: stets ~maxConcurrent Analysen parallel, Persistenz
    // seriell beim Einsammeln (die DatabaseQueue serialisiert Schreibzugriffe ohnehin).
    await withTaskGroup(of: TrackFingerprint?.self) { group in
        var next = 0
        func schedule(_ index: Int) {
            let file = audioFiles[index]
            group.addTask {
                await analyzeOne(file, bpmEstimator: bpmEstimator, axesAnalyzer: axesAnalyzer, analyzedAt: analyzedAt)
            }
        }
        while next < min(maxConcurrent, total) { schedule(next); next += 1 }

        for await result in group {
            if let result, (try? store.save(result)) != nil {
                processed += 1
            } else {
                failed += 1
            }
            if next < total { schedule(next); next += 1 }

            let done = processed + failed
            if done % 25 == 0 || done == total {
                FileHandle.standardError.write(Data("\r  \(done)/\(total) (\(failed) Fehler)".utf8))
            }
        }
    }
    FileHandle.standardError.write(Data("\n".utf8))

    let stored = (try? store.count()) ?? processed
    print(String(repeating: "-", count: 50))
    print("Fertig: \(processed) Fingerprints geschrieben, \(failed) Fehler.")
    print("In der DB: \(stored) Zeilen in `track_fingerprints`.")
}

// MARK: - Einstieg

let options = parseArguments(Array(CommandLine.arguments.dropFirst()))

if options.help {
    printUsage()
    exit(0)
}

if options.selfTest {
    runSelfTest(options: options)
    exit(0)
}

guard let firstPath = options.paths.first else {
    printUsage()
    exit(1)
}

let url = URL(fileURLWithPath: firstPath)
var isDirectory: ObjCBool = false
guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else {
    FileHandle.standardError.write(Data("Fehler: \(firstPath) existiert nicht\n".utf8))
    exit(1)
}

if options.fingerprint {
    guard isDirectory.boolValue else {
        FileHandle.standardError.write(Data("Fehler: `fingerprint` erwartet einen Ordner\n".utf8))
        exit(1)
    }
    await runFingerprint(url, options: options)
} else if isDirectory.boolValue {
    await runFolder(url, options: options)
} else {
    await runSingleFile(url, options: options)
}
