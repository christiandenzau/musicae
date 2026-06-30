//
// AudioAxes.swift
//
// Die leichten, je Track einmal gerechneten Audio-Achsen (Phase 2, Teil 2).
// Bewusst die billige, robuste erste Fassung — alles direkt aus Wellenform und
// FFT, kein Modell, kein echtes LUFS (das ist eine spätere Verfeinerung).
//
//   • RMS-Lautheit     – wie laut das Master insgesamt ist (dBFS).
//   • Dynamikumfang    – Streuung der kurzzeitigen Lautheit: trennt den
//                        durchgehend lauten Track vom Track mit echtem
//                        Breakdown und Drop.
//   • Spektrale Helligkeit – energiegewichteter Frequenzschwerpunkt (Centroid).
//   • Bass-Anteil      – Anteil der Spektralenergie im Tiefen.
//
// Wie der `BPMEstimator` ist die Logik rein und I/O-frei: sie arbeitet auf
// `[Float]` plus Samplerate und ist damit gegen synthetische Signale testbar.
// Sie teilt sich mit dem BPM-Schätzer die 11025-Hz-Ladung — eine Datei wird
// genau einmal dekodiert.
//

import Accelerate
import Foundation

/// Die persistierten leichten Achsen eines Titels (erste Fassung).
public struct AudioAxes: Equatable, Sendable {
    /// Gesamtlautheit als RMS in dBFS (0 dB = Vollausschlag, negativ = leiser).
    public let rmsLoudnessDb: Double
    /// Dynamikumfang: Standardabweichung der kurzzeitigen Lautheit (in dB).
    /// Klein = durchgehend laut, groß = ruhige und laute Passagen.
    public let dynamicRangeDb: Double
    /// Spektrale Helligkeit: energiegewichteter Frequenzschwerpunkt in Hz.
    /// Bei der 11025-Hz-Analyse ein relativer Index bis Nyquist (5512 Hz) —
    /// für den Vergleich zwischen Titeln aussagekräftig, keine Vollband-Größe.
    public let spectralBrightnessHz: Double
    /// Bass-Anteil: Anteil der Spektralenergie unterhalb der Bass-Grenze (0…1).
    public let bassRatio: Double

    public init(
        rmsLoudnessDb: Double,
        dynamicRangeDb: Double,
        spectralBrightnessHz: Double,
        bassRatio: Double
    ) {
        self.rmsLoudnessDb = rmsLoudnessDb
        self.dynamicRangeDb = dynamicRangeDb
        self.spectralBrightnessHz = spectralBrightnessHz
        self.bassRatio = bassRatio
    }
}

public struct AudioAxesAnalyzer: Sendable {
    /// FFT-Fensterlänge in Samples (Zweierpotenz).
    public var fftSize: Int
    /// Sprungweite zwischen FFT-Fenstern in Samples.
    public var hopSize: Int
    /// Obergrenze des Bassbands in Hz (Energie darunter zählt als Bass-Anteil).
    public var bassCutoffHz: Double
    /// Fensterlänge der kurzzeitigen RMS für die Dynamik (Sekunden).
    public var rmsWindowSeconds: Double
    /// Lautheits-Untergrenze in dB. Fenster darunter gelten als Stille und
    /// zählen nicht in die Dynamik (sonst zieht jede Pause die Streuung hoch).
    public var silenceFloorDb: Double

    public init(
        fftSize: Int = 1024,
        hopSize: Int = 512,
        bassCutoffHz: Double = 200,
        rmsWindowSeconds: Double = 0.05,
        silenceFloorDb: Double = -60
    ) {
        self.fftSize = fftSize
        self.hopSize = hopSize
        self.bassCutoffHz = bassCutoffHz
        self.rmsWindowSeconds = rmsWindowSeconds
        self.silenceFloorDb = silenceFloorDb
    }

    // MARK: - Öffentliche API

    /// Berechnet die Achsen eines Mono-Signals.
    ///
    /// - Returns: die Achsen oder `nil`, wenn das Signal kürzer als ein
    ///   FFT-Fenster ist.
    public func analyze(samples: [Float], sampleRate: Double) -> AudioAxes? {
        guard sampleRate > 0, samples.count >= fftSize else { return nil }

        let loudness = loudnessAndDynamics(samples: samples, sampleRate: sampleRate)
        let spectral = spectralAxes(samples: samples, sampleRate: sampleRate)

        return AudioAxes(
            rmsLoudnessDb: loudness.rmsDb,
            dynamicRangeDb: loudness.dynamicsDb,
            spectralBrightnessHz: spectral.centroidHz,
            bassRatio: spectral.bassRatio
        )
    }

    // MARK: - Lautheit & Dynamik

    private func loudnessAndDynamics(samples: [Float], sampleRate: Double) -> (rmsDb: Double, dynamicsDb: Double) {
        // Gesamt-RMS über das ganze Signal.
        var totalRms: Float = 0
        vDSP_rmsqv(samples, 1, &totalRms, vDSP_Length(samples.count))
        let rmsDb = amplitudeToDb(Double(totalRms))

        // Kurzzeitige RMS über nicht-überlappende Fenster; ihre Streuung ist
        // der Dynamikumfang.
        let windowSamples = max(1, Int((rmsWindowSeconds * sampleRate).rounded()))
        var levelsDb: [Double] = []
        var start = 0
        while start + windowSamples <= samples.count {
            var rms: Float = 0
            samples.withUnsafeBufferPointer { ptr in
                vDSP_rmsqv(ptr.baseAddress! + start, 1, &rms, vDSP_Length(windowSamples))
            }
            let db = amplitudeToDb(Double(rms))
            if db > silenceFloorDb { levelsDb.append(db) }
            start += windowSamples
        }

        return (rmsDb, standardDeviation(levelsDb))
    }

    // MARK: - Spektrale Achsen

    private func spectralAxes(samples: [Float], sampleRate: Double) -> (centroidHz: Double, bassRatio: Double) {
        let fft = RealFFT(size: fftSize)
        let hann = hannWindow(fftSize)
        let halfSize = fftSize / 2
        let binWidth = sampleRate / Double(fftSize)
        let bassCutBin = max(1, min(halfSize - 1, Int((bassCutoffHz / binWidth).rounded())))

        let frameCount = 1 + (samples.count - fftSize) / hopSize
        guard frameCount > 0 else { return (0, 0) }

        var windowed = [Float](repeating: 0, count: fftSize)
        // Energiegewichtete Akkumulation über alle Frames: laute Frames prägen
        // den Klang, stille tragen von selbst kaum bei (keine Stille-Filterung nötig).
        var sumWeightedFreq = 0.0
        var sumMagnitude = 0.0
        var sumBassMagnitude = 0.0

        for frame in 0..<frameCount {
            let start = frame * hopSize
            samples.withUnsafeBufferPointer { src in
                windowed.withUnsafeMutableBufferPointer { dst in
                    vDSP_vmul(src.baseAddress! + start, 1, hann, 1, dst.baseAddress!, 1, vDSP_Length(fftSize))
                }
            }

            let magnitudes = fft.magnitudes(of: windowed)
            // Bin 0 (DC/Nyquist verpackt) überspringen.
            for bin in 1..<halfSize {
                let magnitude = Double(magnitudes[bin])
                let frequency = Double(bin) * binWidth
                sumWeightedFreq += frequency * magnitude
                sumMagnitude += magnitude
                if bin <= bassCutBin { sumBassMagnitude += magnitude }
            }
        }

        guard sumMagnitude > 0 else { return (0, 0) }
        return (sumWeightedFreq / sumMagnitude, sumBassMagnitude / sumMagnitude)
    }

    // MARK: - Helfer

    private func amplitudeToDb(_ amplitude: Double) -> Double {
        guard amplitude > 0 else { return silenceFloorDb }
        return max(silenceFloorDb, 20 * log10(amplitude))
    }

    private func standardDeviation(_ values: [Double]) -> Double {
        guard values.count > 1 else { return 0 }
        let mean = values.reduce(0, +) / Double(values.count)
        let variance = values.reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / Double(values.count)
        return variance.squareRoot()
    }

    private func hannWindow(_ length: Int) -> [Float] {
        var window = [Float](repeating: 0, count: length)
        vDSP_hann_window(&window, vDSP_Length(length), Int32(vDSP_HANN_NORM))
        return window
    }
}
