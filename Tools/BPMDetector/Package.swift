// swift-tools-version: 6.0
//
// Eigenständiges Kommandozeilen-Werkzeug für die native Audio-Analyse eines
// Titels (Musicae-Umsetzungsplan, Phase 2). Bewusst als separates Paket
// gebaut, damit es ohne Xcode mit `swift build`/`swift test` verifizierbar ist.
//
//   Teil 1 (#4): Tempo (BPM) per spektralem Fluss + Autokorrelation.
//   Teil 2 (#5): leichte Achsen (Lautheit, Dynamik, Helligkeit, Bass) plus
//                eine je Track persistierte Fingerprint-Zeile (GRDB).
//
// `BPMKit`     – die reine Analyselogik + die GRDB-Persistenz.
// `bpmdetect`  – das CLI-Frontend (Datei-, Ordner-, Selbsttest- und
//                Fingerprint-Modus).
//
import PackageDescription

let package = Package(
    name: "BPMDetector",
    platforms: [.macOS(.v13)],
    products: [
        // Nur die reine Analysebibliothek ist nach außen konsumierbar — sie wird
        // vom Musicae-App-Target gelinkt (Phase 5a, #15). Das `bpmdetect`-Executable
        // bleibt ein rein internes CLI-Frontend und wird bewusst nicht exponiert.
        .library(name: "BPMKit", targets: ["BPMKit"]),
    ],
    dependencies: [
        // Dieselbe Persistenzschicht wie die Musicae-App (dort 7.11.0).
        .package(url: "https://github.com/groue/GRDB.swift", from: "7.11.0"),
    ],
    targets: [
        // Reine Logik (Audio-Laden, spektraler Fluss, Autokorrelation, Achsen)
        // plus die Fingerprint-Persistenz. AVFoundation/Accelerate werden bei
        // `import` automatisch gelinkt; GRDB trägt die SQLite-Schicht.
        .target(
            name: "BPMKit",
            dependencies: [.product(name: "GRDB", package: "GRDB.swift")]
        ),

        .executableTarget(
            name: "bpmdetect",
            dependencies: ["BPMKit"]
        ),

        .testTarget(
            name: "BPMKitTests",
            dependencies: ["BPMKit"]
        ),
    ]
)
