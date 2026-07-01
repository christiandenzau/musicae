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

    /// Beat-Regelmäßigkeit 0…1: die Stärke der stärksten Autokorrelation der
    /// Onset-Hüllkurve im Loop-Fenster (über einen einzelnen Beat hinaus). Hoch =
    /// maschinell-loopregelmäßig (Dance/Techno, programmierter Four-on-the-Floor),
    /// niedrig = variabel-organisch (echtes Schlagzeug, Rock). **Anders als die
    /// BPM-Confidence** (wie *klar* ein Beat erkennbar ist) misst dies, wie
    /// *regelmäßig* sich der Rhythmus über mehrere Beats wiederholt — laut
    /// DB-Analyse der stärkste tag-unabhängige Trenner zwischen Gitarrenrock und
    /// Eurodance (#23). Braucht die höhere Analyserate (`AudioLoader.beatSampleRate`),
    /// damit die perkussiven Hochfrequenzen die Onsets scharf zeichnen.
    ///
    /// - Returns: die Regelmäßigkeit oder `nil`, wenn das Signal zu kurz für ein
    ///   Loop-Fenster ist.
    public func beatRegularity(samples: [Float], sampleRate: Double) -> Double? {
        guard sampleRate > 0, samples.count >= fftSize else { return nil }
        let flux = spectralFlux(samples: samples)
        // Loop-Lag-Fenster: ~0,9 s (über einen einzelnen Beat hinaus) bis ~9 s.
        let framesPerSecond = sampleRate / Double(hopSize)
        let minLag = max(1, Int(0.9 * framesPerSecond))
        let maxLag = Int(9.0 * framesPerSecond)
        guard flux.count > minLag + 1, maxLag > minLag else { return nil }
        return peakAutocorrelation(flux, minLag: minLag, maxLag: min(maxLag, flux.count - 1))
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

    // MARK: - Rhythmus (Beat-Regelmäßigkeit)

    /// Onset-Hüllkurve: der positive spektrale Fluss je Frame — die Summe der
    /// Magnituden-*Zunahmen* gegenüber dem Vorframe (Anschläge/Transienten heben
    /// ihn, Ausklänge zählen nicht). Auf der bestehenden FFT, ein Wert je Frame.
    private func spectralFlux(samples: [Float]) -> [Double] {
        let fft = RealFFT(size: fftSize)
        let hann = hannWindow(fftSize)
        let halfSize = fftSize / 2
        let frameCount = 1 + (samples.count - fftSize) / hopSize
        guard frameCount > 1 else { return [] }

        var windowed = [Float](repeating: 0, count: fftSize)
        var previous = [Float](repeating: 0, count: halfSize)
        var flux = [Double]()
        flux.reserveCapacity(frameCount)
        for frame in 0..<frameCount {
            let start = frame * hopSize
            samples.withUnsafeBufferPointer { src in
                windowed.withUnsafeMutableBufferPointer { dst in
                    vDSP_vmul(src.baseAddress! + start, 1, hann, 1, dst.baseAddress!, 1, vDSP_Length(fftSize))
                }
            }
            let magnitudes = fft.magnitudes(of: windowed)
            var sum = 0.0
            for bin in 1..<halfSize {
                let rise = magnitudes[bin] - previous[bin]
                if rise > 0 { sum += Double(rise) * Double(rise) }
            }
            flux.append(sum.squareRoot())
            previous = magnitudes
        }
        return flux
    }

    /// Stärkster Autokorrelations-Peak einer Reihe im Lag-Fenster `[minLag, maxLag]`,
    /// auf Lag 0 (die Gesamtenergie) normiert → 0…1. Für die Onset-Hüllkurve misst
    /// das, wie stark sich der Rhythmus loopartig wiederholt.
    private func peakAutocorrelation(_ signal: [Double], minLag: Int, maxLag: Int) -> Double {
        let n = signal.count
        guard n > 1, minLag <= maxLag else { return 0 }
        let mean = signal.reduce(0, +) / Double(n)
        let centered = signal.map { $0 - mean }
        let energy = centered.reduce(0) { $0 + $1 * $1 }
        guard energy > 0 else { return 0 }
        var peak = 0.0
        for lag in minLag...maxLag {
            var sum = 0.0
            for index in 0..<(n - lag) {
                sum += centered[index] * centered[index + lag]
            }
            peak = Swift.max(peak, sum / energy)
        }
        return Swift.max(0, Swift.min(1, peak))
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
