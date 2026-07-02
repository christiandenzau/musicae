//
// AudioAxesTests.swift
//
// Prüft die leichten Achsen gegen synthetische Signale mit bekannten
// spektralen und Pegel-Eigenschaften — der automatisierte Teil von AK5 für
// Phase 2 Teil 2. Wie beim BPM hängt die Korrektheit nicht an Audiomaterial,
// das in CI nicht liegt.
//

import XCTest
@testable import BPMKit

final class AudioAxesTests: XCTestCase {
    private let sampleRate = AudioLoader.defaultSampleRate
    private let analyzer = AudioAxesAnalyzer()

    // MARK: - Helfer

    /// Ein reiner Sinus fester Frequenz und Amplitude.
    private func sine(freq: Double, amplitude: Double, seconds: Double) -> [Float] {
        let count = Int(seconds * sampleRate)
        return (0..<count).map { index in
            Float(amplitude * sin(2.0 * .pi * freq * Double(index) / sampleRate))
        }
    }

    // MARK: - Spektrale Helligkeit & Bass-Anteil

    func testBassSineIsDarkAndBassHeavy() throws {
        let axes = try XCTUnwrap(analyzer.analyze(samples: sine(freq: 80, amplitude: 0.6, seconds: 3), sampleRate: sampleRate))
        XCTAssertLessThan(axes.spectralBrightnessHz, 500, "80-Hz-Sinus sollte einen tiefen Schwerpunkt haben")
        XCTAssertGreaterThan(axes.bassRatio, 0.7, "80-Hz-Sinus sollte fast nur Bass-Energie tragen")
    }

    func testTrebleSineIsBrightAndBassLight() throws {
        let axes = try XCTUnwrap(analyzer.analyze(samples: sine(freq: 3000, amplitude: 0.6, seconds: 3), sampleRate: sampleRate))
        XCTAssertGreaterThan(axes.spectralBrightnessHz, 2000, "3-kHz-Sinus sollte einen hohen Schwerpunkt haben")
        XCTAssertLessThan(axes.bassRatio, 0.1, "3-kHz-Sinus sollte kaum Bass-Energie tragen")
    }

    func testBrightnessOrdersByFrequency() throws {
        let dark = try XCTUnwrap(analyzer.analyze(samples: sine(freq: 100, amplitude: 0.5, seconds: 2), sampleRate: sampleRate))
        let bright = try XCTUnwrap(analyzer.analyze(samples: sine(freq: 2500, amplitude: 0.5, seconds: 2), sampleRate: sampleRate))
        XCTAssertLessThan(dark.spectralBrightnessHz, bright.spectralBrightnessHz)
        XCTAssertGreaterThan(dark.bassRatio, bright.bassRatio)
    }

    // MARK: - Lautheit

    func testLoudnessTracksAmplitude() throws {
        let loud = try XCTUnwrap(analyzer.analyze(samples: sine(freq: 440, amplitude: 0.8, seconds: 2), sampleRate: sampleRate))
        let quiet = try XCTUnwrap(analyzer.analyze(samples: sine(freq: 440, amplitude: 0.08, seconds: 2), sampleRate: sampleRate))
        XCTAssertGreaterThan(loud.rmsLoudnessDb, quiet.rmsLoudnessDb)
        // Faktor 10 in der Amplitude ≈ 20 dB.
        XCTAssertEqual(loud.rmsLoudnessDb - quiet.rmsLoudnessDb, 20, accuracy: 3)
    }

    // MARK: - Dynamikumfang

    func testDynamicRangeHigherForVaryingSignal() throws {
        // Durchgehend gleich laut → kleine Streuung.
        let constant = sine(freq: 200, amplitude: 0.6, seconds: 4)
        // Laute erste Hälfte, leise zweite Hälfte → große Streuung der RMS.
        var varying = sine(freq: 200, amplitude: 0.6, seconds: 4)
        for index in (varying.count / 2)..<varying.count { varying[index] *= 0.06 }

        let constantAxes = try XCTUnwrap(analyzer.analyze(samples: constant, sampleRate: sampleRate))
        let varyingAxes = try XCTUnwrap(analyzer.analyze(samples: varying, sampleRate: sampleRate))

        XCTAssertLessThan(constantAxes.dynamicRangeDb, 2, "Konstanter Pegel sollte kaum Streuung zeigen")
        XCTAssertGreaterThan(varyingAxes.dynamicRangeDb, 5, "Laut/leise-Wechsel sollte deutliche Streuung zeigen")
        XCTAssertGreaterThan(varyingAxes.dynamicRangeDb, constantAxes.dynamicRangeDb)
    }

    // MARK: - Robustheit

    func testTooShortReturnsNil() {
        XCTAssertNil(analyzer.analyze(samples: [Float](repeating: 0.1, count: 256), sampleRate: sampleRate))
    }

    func testDeterministic() throws {
        let signal = sine(freq: 500, amplitude: 0.4, seconds: 2)
        let first = analyzer.analyze(samples: signal, sampleRate: sampleRate)
        let second = analyzer.analyze(samples: signal, sampleRate: sampleRate)
        XCTAssertEqual(first, second)
    }

    // MARK: - Beat-Regelmäßigkeit (#23)

    /// Anschläge in *zufälligen* Abständen (deterministischer LCG) — kein fester
    /// Loop, also schwache Autokorrelation.
    private func irregularClicks(seconds: Double, seed: UInt64 = 0xABCD_EF01_2345_6789) -> [Float] {
        let count = Int(seconds * sampleRate)
        var signal = [Float](repeating: 0, count: count)
        var state = seed
        var index = 0
        while index < count {
            signal[index] = 1
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            let unit = Double(state >> 40) / Double(1 << 24)   // 0…1
            index += max(1, Int((0.15 + 0.6 * unit) * sampleRate))   // Abstand 0,15…0,75 s
        }
        return signal
    }

    func testBeatRegularityHigherForSteadyPulse() throws {
        // Festes Metronom → starke Autokorrelation im Loop-Fenster; unregelmäßige
        // Anschläge → schwache. Genau die maschinell-vs-organisch-Trennung, die
        // Dance von Rock scheidet.
        let steady = ClickTrackGenerator.make(bpm: 128, durationSeconds: 12)
        let irregular = irregularClicks(seconds: 12)
        let steadyReg = try XCTUnwrap(analyzer.beatRegularity(samples: steady, sampleRate: sampleRate))
        let irregularReg = try XCTUnwrap(analyzer.beatRegularity(samples: irregular, sampleRate: sampleRate))
        XCTAssertGreaterThan(steadyReg, irregularReg, "Festes Metronom regelmäßiger als Zufallsanschläge")
        XCTAssertGreaterThan(steadyReg, 0.3, "Ein festes Metronom sollte klar loopregelmäßig sein")
    }

    func testBeatRegularityTooShortReturnsNil() {
        XCTAssertNil(analyzer.beatRegularity(samples: [Float](repeating: 0.1, count: 256), sampleRate: sampleRate))
    }

    func testBeatRegularityDeterministic() throws {
        let signal = ClickTrackGenerator.make(bpm: 130, durationSeconds: 8)
        XCTAssertEqual(analyzer.beatRegularity(samples: signal, sampleRate: sampleRate),
                       analyzer.beatRegularity(samples: signal, sampleRate: sampleRate))
    }
}
