//
// BPMEstimatorTests.swift
//
// Verifiziert den Schätzer reproduzierbar gegen synthetische Beats mit exakt
// bekanntem Tempo — der automatisierte Teil von AK5. Echte Titel prüft man
// zusätzlich von Hand (siehe README), aber die Algorithmus-Korrektheit hängt
// nicht an Audiomaterial, das in CI nicht liegt.
//

import XCTest
@testable import BPMKit

final class BPMEstimatorTests: XCTestCase {
    private let sampleRate = AudioLoader.defaultSampleRate

    /// Toleranz der Schätzung in BPM. Bewusst eng — ein Beat-Tracker, der das
    /// Tempo nur grob trifft, taugt nicht als tragende Achse.
    private let tolerance = 1.5

    // MARK: - Genauigkeit über das Band (voller Spektralfluss)

    func testKnownTemposFullBand() {
        let estimator = BPMEstimator(onsetBand: .full)
        for tempo in [120.0, 124, 128, 132, 138, 140, 145, 150] {
            let signal = ClickTrackGenerator.make(bpm: tempo, durationSeconds: 20, sampleRate: sampleRate)
            let estimate = estimator.estimate(samples: signal, sampleRate: sampleRate)
            let bpm = try? XCTUnwrap(estimate?.bpm, "Keine Schätzung für \(tempo) BPM")
            XCTAssertEqual(bpm ?? .nan, tempo, accuracy: tolerance,
                           "Volles Band: \(tempo) BPM nicht getroffen")
        }
    }

    // MARK: - Genauigkeit mit Bass-Fokus (Härtung, AK6)

    func testKnownTemposBassBand() {
        let estimator = BPMEstimator(onsetBand: .lowFrequency(maxHz: 250))
        for tempo in [124.0, 128, 132, 140, 150] {
            let signal = ClickTrackGenerator.make(bpm: tempo, durationSeconds: 20, sampleRate: sampleRate)
            let estimate = estimator.estimate(samples: signal, sampleRate: sampleRate)
            let bpm = try? XCTUnwrap(estimate?.bpm, "Keine Schätzung für \(tempo) BPM (Bass)")
            XCTAssertEqual(bpm ?? .nan, tempo, accuracy: tolerance,
                           "Bass-Band: \(tempo) BPM nicht getroffen")
        }
    }

    // MARK: - Genauigkeit außerhalb des Eurodance-Bands (breites Suchband)

    /// Der eigentliche Zweck des breiten Bandes: langsameres Material (Rap ~90,
    /// Balladen) und schnelleres muss seinen *echten* Beat finden, nicht einen
    /// metrischen Nebenpeak im engen 120–150-Fenster.
    func testKnownTemposOutsideEurodanceBand() {
        let estimator = BPMEstimator(onsetBand: .full)
        for tempo in [80.0, 90, 100, 160] {
            let signal = ClickTrackGenerator.make(bpm: tempo, durationSeconds: 25, sampleRate: sampleRate)
            let estimate = estimator.estimate(samples: signal, sampleRate: sampleRate)
            let bpm = try? XCTUnwrap(estimate?.bpm, "Keine Schätzung für \(tempo) BPM")
            XCTAssertEqual(bpm ?? .nan, tempo, accuracy: tolerance,
                           "Breites Band: \(tempo) BPM nicht getroffen")
        }
    }

    // MARK: - Kein Oktavfehler

    /// Ein 130-BPM-Beat darf nicht als 65 (halb) oder 260 (doppelt) erkannt werden.
    /// Seit das Suchband breit ist (70–180), liegt 65 im Band — der Schutz kommt jetzt
    /// von der perzeptuellen Tempo-Gewichtung, nicht mehr von der engen Bandgrenze.
    /// Dieser Test hält die Garantie fest.
    func testNoOctaveError() {
        let estimator = BPMEstimator(onsetBand: .full)
        let signal = ClickTrackGenerator.make(bpm: 130, durationSeconds: 25, sampleRate: sampleRate)
        let estimate = estimator.estimate(samples: signal, sampleRate: sampleRate)
        let bpm = estimate?.bpm ?? .nan
        XCTAssertEqual(bpm, 130, accuracy: tolerance)
        XCTAssertFalse((60...70).contains(bpm), "Halb-Tempo-Oktavfehler")
        XCTAssertFalse((255...265).contains(bpm), "Doppel-Tempo-Oktavfehler")
    }

    // MARK: - Konfidenz

    func testConfidenceIsHighForCleanBeat() {
        let estimator = BPMEstimator(onsetBand: .full)
        let signal = ClickTrackGenerator.make(bpm: 134, durationSeconds: 20, sampleRate: sampleRate)
        let estimate = estimator.estimate(samples: signal, sampleRate: sampleRate)
        let confidence = estimate?.confidence ?? 0
        XCTAssertGreaterThan(confidence, 0.3, "Sauberer Beat sollte klare Selbstähnlichkeit zeigen")
    }

    // MARK: - Robustheit gegen Entartetes

    func testSilenceYieldsNoEstimate() {
        let estimator = BPMEstimator()
        let silence = [Float](repeating: 0, count: Int(sampleRate * 10))
        XCTAssertNil(estimator.estimate(samples: silence, sampleRate: sampleRate),
                     "Stille darf kein Tempo liefern")
    }

    func testTooShortYieldsNoEstimate() {
        let estimator = BPMEstimator()
        let tiny = [Float](repeating: 0.1, count: 256)
        XCTAssertNil(estimator.estimate(samples: tiny, sampleRate: sampleRate),
                     "Zu kurzes Signal darf kein Tempo liefern")
    }

    // MARK: - Determinismus

    func testEstimateIsDeterministic() {
        let estimator = BPMEstimator(onsetBand: .full)
        let signal = ClickTrackGenerator.make(bpm: 128, durationSeconds: 15, sampleRate: sampleRate)
        let first = estimator.estimate(samples: signal, sampleRate: sampleRate)
        let second = estimator.estimate(samples: signal, sampleRate: sampleRate)
        XCTAssertEqual(first, second)
    }
}
