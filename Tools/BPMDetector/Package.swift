// swift-tools-version: 6.0
//
// Eigenständiges Kommandozeilen-Werkzeug zum nativen Schätzen des Tempos (BPM)
// eines Titels. Phase 2 (Teil 1) des Musicae-Umsetzungsplans — das riskante
// Stück der Audio-Analyse, bewusst als separates Paket gebaut, damit es ohne
// Xcode mit `swift build`/`swift test` verifizierbar ist.
//
// `BPMKit`     – die reine, I/O-freie Schätzlogik (unit-testbar).
// `bpmdetect`  – das CLI-Frontend (Datei- und Ordner-/Testmodus).
//
import PackageDescription

let package = Package(
    name: "BPMDetector",
    platforms: [.macOS(.v13)],
    targets: [
        // Reine Logik: Audio-Laden, spektraler Fluss, Autokorrelation.
        // AVFoundation/Accelerate werden bei `import` automatisch gelinkt.
        .target(name: "BPMKit"),

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
