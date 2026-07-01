//
// BPMEstimator.swift
//
// Native Tempo-Schätzung ohne Fremdbibliotheken. Der Weg ist bewusst der
// klassische, robuste:
//
//   1. Onset-Hüllkurve über den spektralen Fluss (positive Energieänderung
//      zwischen kurzen FFT-Fenstern). Schläge erzeugen Energiesprünge.
//   2. Autokorrelation der Hüllkurve: die Schlagperiode ist der Lag, bei dem
//      sich die Hüllkurve am ähnlichsten ist.
//   3. Die Suche ist von vornherein auf ein BPM-Band (Default 120–150,
//      Eurodance) eingegrenzt — so entsteht der berüchtigte Oktavfehler
//      (70 gegen 140) gar nicht erst.
//
// Die Logik ist rein und I/O-frei: sie arbeitet auf `[Float]` plus Samplerate
// und ist damit gegen synthetische Signale mit bekanntem Tempo testbar.
//

import Accelerate
import Foundation

/// Ergebnis einer Tempo-Schätzung.
public struct BPMEstimate: Equatable, Sendable {
    /// Geschätztes Tempo in Schlägen pro Minute.
    public let bpm: Double
    /// Selbstähnlichkeit am Peak (0…1): normalisierte Autokorrelation am
    /// gewählten Lag. Grobes Vertrauensmaß — hoch bei klarem, stetem Beat.
    public let confidence: Double
}

/// Worüber der spektrale Fluss summiert wird.
public enum OnsetBand: Equatable, Sendable {
    /// Gesamtes Spektrum (Standard).
    case full
    /// Nur Bins bis `maxHz` — fokussiert die Onset-Messung auf Bass/untere
    /// Mitten, wo bei elektronischer Musik die Kick sitzt (Härtung, AK6).
    case lowFrequency(maxHz: Double)
}

public struct BPMEstimator: Sendable {
    /// Untere Bandgrenze der Suche (BPM).
    public var minBPM: Double
    /// Obere Bandgrenze der Suche (BPM).
    public var maxBPM: Double
    /// FFT-Fensterlänge in Samples (Zweierpotenz).
    public var fftSize: Int
    /// Sprungweite zwischen Fenstern in Samples. Kleiner = feinere zeitliche
    /// Auflösung der Hüllkurve und damit feinere BPM-Auflösung.
    public var hopSize: Int
    /// Frequenzband, über das der Fluss summiert wird.
    public var onsetBand: OnsetBand

    /// - Note: Das Suchband ist bewusst breit (70–180), damit auch langsameres
    ///   Material (Rap, Balladen) seinen *echten* Beat findet statt eines
    ///   metrischen Nebenpeaks im engen Eurodance-Fenster. Gegen den dadurch
    ///   möglichen Oktavfehler wirkt die perzeptuelle Tempo-Gewichtung in der
    ///   Autokorrelation (siehe `tempoPreference`), die die gefühlte Tempo-Ebene
    ///   bevorzugt — nicht mehr die enge Bandgrenze.
    public init(
        minBPM: Double = 70,
        maxBPM: Double = 180,
        fftSize: Int = 1024,
        hopSize: Int = 128,
        onsetBand: OnsetBand = .full
    ) {
        self.minBPM = minBPM
        self.maxBPM = maxBPM
        self.fftSize = fftSize
        self.hopSize = hopSize
        self.onsetBand = onsetBand
    }

    // MARK: - Öffentliche API

    /// Schätzt das Tempo eines Mono-Signals.
    ///
    /// - Parameters:
    ///   - samples: Mono-PCM, beliebige Skalierung.
    ///   - sampleRate: Abtastrate in Hz.
    /// - Returns: die Schätzung oder `nil`, wenn das Signal zu kurz ist, um
    ///   auch nur eine Periode der unteren Bandgrenze zu fassen.
    public func estimate(samples: [Float], sampleRate: Double) -> BPMEstimate? {
        guard sampleRate > 0, minBPM > 0, maxBPM >= minBPM else { return nil }

        let envelope = onsetEnvelope(samples: samples, sampleRate: sampleRate)
        guard envelope.count > 2 else { return nil }

        let frameRate = sampleRate / Double(hopSize)
        return autocorrelationBPM(envelope: envelope, frameRate: frameRate)
    }

    /// Berechnet die Onset-Hüllkurve (spektraler Fluss je Frame). Öffentlich,
    /// damit Werkzeuge/Tests die Zwischenschicht inspizieren können.
    public func onsetEnvelope(samples: [Float], sampleRate: Double) -> [Float] {
        guard samples.count >= fftSize else { return [] }

        let fft = RealFFT(size: fftSize)
        let hann = hannWindow(fftSize)
        let halfSize = fftSize / 2

        // Höchster zu berücksichtigender Bin je nach Onset-Band.
        let maxBin: Int = {
            switch onsetBand {
            case .full:
                return halfSize - 1
            case .lowFrequency(let maxHz):
                let binWidth = sampleRate / Double(fftSize)
                let bin = Int((maxHz / binWidth).rounded())
                return min(max(bin, 1), halfSize - 1)
            }
        }()

        let frameCount = 1 + (samples.count - fftSize) / hopSize
        guard frameCount > 1 else { return [] }

        var envelope = [Float](repeating: 0, count: frameCount)
        var previousMagnitudes = [Float](repeating: 0, count: halfSize)
        var windowed = [Float](repeating: 0, count: fftSize)

        for frame in 0..<frameCount {
            let start = frame * hopSize

            // Fenster ausschneiden und mit Hann gewichten.
            samples.withUnsafeBufferPointer { src in
                windowed.withUnsafeMutableBufferPointer { dst in
                    vDSP_vmul(src.baseAddress! + start, 1, hann, 1, dst.baseAddress!, 1, vDSP_Length(fftSize))
                }
            }

            let magnitudes = fft.magnitudes(of: windowed)

            // Spektraler Fluss: Summe der positiven Magnitudenzuwächse.
            // Bin 0 (DC/Nyquist verpackt) wird übersprungen.
            var flux: Float = 0
            for bin in 1...maxBin {
                let diff = magnitudes[bin] - previousMagnitudes[bin]
                if diff > 0 { flux += diff }
            }
            envelope[frame] = flux

            previousMagnitudes = magnitudes
        }

        // Mittelwert abziehen (DC entfernen), damit die Autokorrelation die
        // Periodizität misst und nicht den konstanten Sockel.
        var mean: Float = 0
        vDSP_meanv(envelope, 1, &mean, vDSP_Length(envelope.count))
        var negMean = -mean
        vDSP_vsadd(envelope, 1, &negMean, &envelope, 1, vDSP_Length(envelope.count))

        return envelope
    }

    // MARK: - Autokorrelation

    private func autocorrelationBPM(envelope: [Float], frameRate: Double) -> BPMEstimate? {
        let n = envelope.count

        // Lag-Bereich, der dem BPM-Band entspricht. Hohes BPM → kurzer Lag.
        let minLag = max(1, Int((60.0 * frameRate / maxBPM).rounded(.down)))
        let maxLag = Int((60.0 * frameRate / minBPM).rounded(.up))
        guard maxLag > minLag, maxLag + 1 < n else { return nil }

        // Energie bei Lag 0 zur Normalisierung der Confidence.
        var energy: Float = 0
        vDSP_dotpr(envelope, 1, envelope, 1, &energy, vDSP_Length(n))
        guard energy > 0 else { return nil }

        // Unbiased-Autokorrelation je Lag im Band. Die Peak-Auswahl gewichtet jeden
        // Lag mit der perzeptuellen Tempo-Präferenz, damit im breiten Band nicht die
        // halbe/doppelte Oktave (oder ein metrischer Nebenpeak) gewinnt.
        var bestLag = minLag
        var bestScore = -Double.greatestFiniteMagnitude
        var corr = [Float](repeating: 0, count: maxLag + 2)

        for lag in (minLag - 1)...(maxLag + 1) where lag >= 1 {
            var sum: Float = 0
            let count = n - lag
            envelope.withUnsafeBufferPointer { ptr in
                vDSP_dotpr(ptr.baseAddress!, 1, ptr.baseAddress! + lag, 1, &sum, vDSP_Length(count))
            }
            // Auf die Überlappungslänge normieren, damit lange Lags nicht
            // systematisch benachteiligt werden.
            let normalized = sum / Float(count)
            corr[lag] = normalized
            if lag >= minLag && lag <= maxLag {
                let candidateBPM = 60.0 * frameRate / Double(lag)
                let score = Double(normalized) * tempoPreference(candidateBPM)
                if score > bestScore {
                    bestScore = score
                    bestLag = lag
                }
            }
        }

        // Parabolische Interpolation um den Peak für Sub-Frame-Genauigkeit.
        let refinedLag = parabolicPeak(
            left: Double(corr[bestLag - 1]),
            center: Double(corr[bestLag]),
            right: Double(corr[bestLag + 1]),
            centerIndex: Double(bestLag)
        )

        guard refinedLag > 0 else { return nil }
        let bpm = 60.0 * frameRate / refinedLag

        // Confidence aus der ROHEN Autokorrelation am gewählten Lag (nicht der
        // gewichteten): sie misst die tatsächliche Selbstähnlichkeit einer Periode,
        // unabhängig von der Tempo-Präferenz. Ein unklarer Rhythmus (Rap, Rock) liegt
        // dadurch niedrig, ein sauberer Four-on-the-Floor hoch — das trägt #17.
        let confidence = max(0, min(1, Double(corr[bestLag]) / (Double(energy) / Double(n))))

        return BPMEstimate(bpm: bpm, confidence: confidence)
    }

    /// Perzeptuelle Tempo-Gewichtung: eine weiche Log-Gauss um das gefühlte
    /// Vorzugstempo. Dämpft die halbe/doppelte Oktave (und metrische Nebenpeaks),
    /// damit das breite Suchband keine Oktavfehler einführt, ohne einen echten, klar
    /// stärkeren Peak zu verwerfen. Auf das Eurodance-Zentrum gelegt, damit die
    /// saubere Scheibe stabil bleibt.
    private func tempoPreference(_ bpm: Double) -> Double {
        let preferred = 128.0
        let sigma = 0.9   // Standardabweichung in Oktaven (log2)
        let octaves = log2(bpm / preferred)
        return exp(-0.5 * (octaves / sigma) * (octaves / sigma))
    }

    /// Scheitel einer Parabel durch drei äquidistante Punkte. Gibt den
    /// interpolierten x-Wert (Lag) zurück.
    private func parabolicPeak(left: Double, center: Double, right: Double, centerIndex: Double) -> Double {
        let denominator = left - 2 * center + right
        guard abs(denominator) > 1e-12 else { return centerIndex }
        let offset = 0.5 * (left - right) / denominator
        // Auf einen Frame begrenzen — größere Verschiebungen wären unphysikalisch.
        let clamped = max(-1, min(1, offset))
        return centerIndex + clamped
    }

    // MARK: - Fensterfunktion

    private func hannWindow(_ length: Int) -> [Float] {
        var window = [Float](repeating: 0, count: length)
        vDSP_hann_window(&window, vDSP_Length(length), Int32(vDSP_HANN_NORM))
        return window
    }
}
