//
// ClickTrackGenerator.swift
//
// Erzeugt synthetische Mono-Signale mit einem stur durchlaufenden Beat bei
// exakt bekanntem Tempo. Damit lässt sich der Schätzer reproduzierbar prüfen,
// ohne echte Audiodateien — die Grundlage des eingebauten Selbsttests und der
// Unit-Tests. Jeder Schlag ist eine kurze, perkussive „Kick" (tieffrequenter
// Sinus mit Pitch-Drop plus breitbandiger Klick-Transient), wie sie eine
// Onset-Hüllkurve aus echtem Dance auch sieht.
//

import Foundation

public enum ClickTrackGenerator {
    /// Baut ein Click-/Kick-Signal.
    ///
    /// - Parameters:
    ///   - bpm: gewünschtes Tempo.
    ///   - durationSeconds: Gesamtlänge des Signals.
    ///   - sampleRate: Abtastrate.
    ///   - seed: Startwert für den Transient-Rauschanteil (reproduzierbar).
    public static func make(
        bpm: Double,
        durationSeconds: Double,
        sampleRate: Double = AudioLoader.defaultSampleRate,
        seed: UInt64 = 0x9E3779B97F4A7C15
    ) -> [Float] {
        precondition(bpm > 0 && durationSeconds > 0 && sampleRate > 0)

        let totalSamples = Int(durationSeconds * sampleRate)
        var signal = [Float](repeating: 0, count: totalSamples)

        let beatInterval = 60.0 / bpm * sampleRate
        let kick = makeKick(sampleRate: sampleRate, seed: seed)

        var beat = 0.0
        while Int(beat) < totalSamples {
            let start = Int(beat)
            for (offset, value) in kick.enumerated() {
                let index = start + offset
                if index >= totalSamples { break }
                signal[index] += value
            }
            beat += beatInterval
        }

        return signal
    }

    /// Eine einzelne Kick: exponentiell abklingender Sinus mit fallender
    /// Tonhöhe, plus ein paar Millisekunden Rauschtransient für breitbandige
    /// Onset-Energie.
    private static func makeKick(sampleRate: Double, seed: UInt64) -> [Float] {
        let length = Int(0.18 * sampleRate)
        var kick = [Float](repeating: 0, count: length)

        let decayTau = 0.06 * sampleRate          // Amplituden-Abklingzeit
        let startFreq = 120.0                       // Hz, Anfang des Pitch-Drops
        let endFreq = 50.0                          // Hz, Ende des Pitch-Drops
        let pitchTau = 0.03 * sampleRate

        var rng = SplitMix64(seed: seed)
        let noiseLength = Int(0.004 * sampleRate)   // ~4 ms Transient

        var phase = 0.0
        for sample in 0..<length {
            let t = Double(sample)
            let amplitude = exp(-t / decayTau)
            let freq = endFreq + (startFreq - endFreq) * exp(-t / pitchTau)
            phase += 2.0 * Double.pi * freq / sampleRate
            var value = amplitude * sin(phase)

            if sample < noiseLength {
                let noise = rng.nextUnit() * 0.5 * (1.0 - Double(sample) / Double(noiseLength))
                value += noise
            }

            kick[sample] = Float(value)
        }

        return kick
    }
}

/// Kleiner, deterministischer PRNG (SplitMix64) — ohne Abhängigkeit von
/// `Date`/Systemzufall, damit Signale exakt reproduzierbar sind.
private struct SplitMix64 {
    private var state: UInt64

    init(seed: UInt64) { self.state = seed }

    mutating func next() -> UInt64 {
        state &+= 0x9E3779B97F4A7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return z ^ (z >> 31)
    }

    /// Gleichverteilter Wert in [-1, 1).
    mutating func nextUnit() -> Double {
        let value = Double(next() >> 11) * (1.0 / 9007199254740992.0) // 2^53
        return value * 2.0 - 1.0
    }
}
