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
      bpmdetect <datei>        BPM einer einzelnen Audiodatei
      bpmdetect <ordner>       je Datei im Ordner den BPM (Testmodus)
      bpmdetect --selftest     synthetische Beats prüfen (ohne Dateien)

    Optionen:
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

if isDirectory.boolValue {
    await runFolder(url, options: options)
} else {
    await runSingleFile(url, options: options)
}
