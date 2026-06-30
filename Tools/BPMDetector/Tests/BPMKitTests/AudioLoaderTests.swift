//
// AudioLoaderTests.swift
//
// End-to-End-Abdeckung für den Datei-Pfad (AK1): ein echtes WAV bei 44,1 kHz
// in Stereo schreiben, über `AudioLoader` laden (Resampling auf 11025 Hz +
// Downmix zu Mono) und durch den Schätzer schicken. Stellt sicher, dass die
// AVAudioFile/AVAudioConverter-Kette real funktioniert, nicht nur die reine
// Rechenlogik auf vorgefertigten Arrays.
//

import AVFoundation
import XCTest
@testable import BPMKit

final class AudioLoaderTests: XCTestCase {
    func testLoadResampleAndEstimateFromRealFile() throws {
        let sourceSampleRate = 44_100.0
        let tempo = 136.0

        // 44,1-kHz-Mono-Signal erzeugen und als Stereo-WAV schreiben.
        let signal = ClickTrackGenerator.make(bpm: tempo, durationSeconds: 18, sampleRate: sourceSampleRate)
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("bpmkit-\(tempo)-test.wav")
        defer { try? FileManager.default.removeItem(at: url) }

        try writeStereoWAV(monoSamples: signal, sampleRate: sourceSampleRate, to: url)

        // Über die echte Lade-/Konvertierkette einlesen.
        let loaded = try AudioLoader.loadMonoSamples(url: url)
        XCTAssertFalse(loaded.isEmpty, "Geladenes Signal ist leer")

        // Resampling-Verhältnis grob prüfen (44100 → 11025 ≈ Faktor 4).
        let expectedFrames = Double(signal.count) * (AudioLoader.defaultSampleRate / sourceSampleRate)
        XCTAssertEqual(Double(loaded.count), expectedFrames, accuracy: expectedFrames * 0.05,
                       "Unerwartete Sample-Anzahl nach Resampling")

        // Tempo muss die volle Datei-Kette überstehen.
        let estimator = BPMEstimator(onsetBand: .full)
        let estimate = try XCTUnwrap(estimator.estimate(samples: loaded, sampleRate: AudioLoader.defaultSampleRate))
        XCTAssertEqual(estimate.bpm, tempo, accuracy: 2.0,
                       "Tempo nach Laden/Resampling nicht getroffen")
    }

    // MARK: - Hilfsfunktion

    /// Schreibt ein Mono-Signal als Stereo-Float-WAV (beide Kanäle gleich),
    /// um sowohl den Downmix als auch das Resampling im Loader zu prüfen.
    private func writeStereoWAV(monoSamples: [Float], sampleRate: Double, to url: URL) throws {
        // WAV ist immer interleaved; das On-Disk-Format daher ohne den
        // non-interleaved-Schlüssel angeben (sonst eine harmlose Warnung).
        // Geschrieben wird über das non-interleaved `processingFormat`.
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: 2,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true
        ]

        let file = try AVAudioFile(forWriting: url, settings: settings)
        let format = file.processingFormat
        let frameCount = AVAudioFrameCount(monoSamples.count)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount) else {
            XCTFail("WAV-Puffer konnte nicht angelegt werden")
            return
        }
        buffer.frameLength = frameCount

        guard let channels = buffer.floatChannelData else {
            XCTFail("Kein Kanalspeicher im Puffer")
            return
        }
        monoSamples.withUnsafeBufferPointer { src in
            for channel in 0..<2 {
                channels[channel].update(from: src.baseAddress!, count: monoSamples.count)
            }
        }

        try file.write(from: buffer)
    }
}
