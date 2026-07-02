//
//  AudioVisualizationProvider.swift
//  Musicae
//
//  Central observable source of visualization data (spectrum + VU levels) for
//  the 3D amplifier panel. Fed either by a real audio tap (SFB backend, via
//  `ingest(buffer:)`) or by a synthetic fallback (Crescendo backend, which
//  exposes no tap point — see MA90-integration notes).
//
//  Published values are smoothed with simple attack/decay ballistics so meters
//  rise quickly and fall back gently, the way a real VU meter behaves.
//

import AVFoundation
import Accelerate
import Combine

@MainActor
final class AudioVisualizationProvider: ObservableObject {
    static let shared = AudioVisualizationProvider()

    /// `bandCount` frequency-band levels in 0...1, ordered low → high frequency.
    @Published private(set) var spectrum: [Float]
    /// Left / right VU levels in 0...1.
    @Published private(set) var levelL: Float = 0
    @Published private(set) var levelR: Float = 0

    let bandCount = 12
    private let fftSize = 2048
    private let analyzer: SpectrumAnalyzer

    // Rolling buffer so we can assemble a full FFT window even when the tap
    // hands us smaller chunks.
    private var monoAccum: [Float] = []

    private init() {
        self.spectrum = [Float](repeating: 0, count: bandCount)
        self.analyzer = SpectrumAnalyzer(fftSize: fftSize, bandCount: bandCount)
    }

    // MARK: - Real audio tap input

    /// Called from an audio-engine tap block (audio thread). Extracts the data
    /// synchronously here, then hops to the main actor to update state.
    /// `AVAudioPCMBuffer` is not Sendable, so nothing but plain `[Float]` /
    /// scalars crosses the actor boundary.
    nonisolated func ingest(buffer: AVAudioPCMBuffer) {
        guard let channelData = buffer.floatChannelData else { return }
        let frames = Int(buffer.frameLength)
        guard frames > 0 else { return }
        let channelCount = Int(buffer.format.channelCount)

        // RMS per channel for the VU meters.
        var rmsL: Float = 0
        vDSP_rmsqv(channelData[0], 1, &rmsL, vDSP_Length(frames))
        var rmsR = rmsL
        if channelCount > 1 {
            vDSP_rmsqv(channelData[1], 1, &rmsR, vDSP_Length(frames))
        }

        // Mono downmix for the spectrum, copied into an owned array.
        var mono = [Float](repeating: 0, count: frames)
        if channelCount > 1 {
            vDSP_vadd(channelData[0], 1, channelData[1], 1, &mono, 1, vDSP_Length(frames))
            var half: Float = 0.5
            vDSP_vsmul(mono, 1, &half, &mono, 1, vDSP_Length(frames))
        } else {
            mono = Array(UnsafeBufferPointer(start: channelData[0], count: frames))
        }

        Task { @MainActor in
            self.processReal(mono: mono, rmsL: rmsL, rmsR: rmsR)
        }
    }

    private func processReal(mono: [Float], rmsL: Float, rmsR: Float) {
        monoAccum.append(contentsOf: mono)
        if monoAccum.count >= fftSize {
            let windowSlice = Array(monoAccum.suffix(fftSize))
            monoAccum.removeAll(keepingCapacity: true)
            applySpectrum(analyzer.analyze(windowSlice))
        }
        applyLevels(Self.rmsToUnit(rmsL), Self.rmsToUnit(rmsR))
    }

    // MARK: - Synthetic fallback (Crescendo backend)

    private var synthTimer: Timer?
    private var synthPhase: Double = 0
    private var isPlayingProbe: (() -> Bool)?
    private var volumeProbe: (() -> Float)?

    /// Drives plausible motion from playback state alone, for backends that
    /// don't expose a tap. `isPlaying` / `volume` are sampled every tick.
    func startSynthetic(isPlaying: @escaping () -> Bool, volume: @escaping () -> Float) {
        stopSynthetic()
        isPlayingProbe = isPlaying
        volumeProbe = volume
        let timer = Timer(timeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tickSynthetic() }
        }
        RunLoop.main.add(timer, forMode: .common)
        synthTimer = timer
    }

    func stopSynthetic() {
        synthTimer?.invalidate()
        synthTimer = nil
        isPlayingProbe = nil
        volumeProbe = nil
    }

    private func tickSynthetic() {
        let playing = isPlayingProbe?() ?? false
        let volume = volumeProbe?() ?? 0
        guard playing else {
            applySpectrum([Float](repeating: 0, count: bandCount))
            applyLevels(0, 0)
            return
        }
        synthPhase += 0.1
        let base = Double(0.25 + 0.6 * volume)

        var bands = [Float](repeating: 0, count: bandCount)
        for i in 0..<bandCount {
            let t = synthPhase + Double(i) * 0.7
            let wobble = 0.5 + 0.5 * sin(t) * cos(t * 0.37 + Double(i))
            let tilt = 1.0 - Double(i) / Double(bandCount) * 0.4     // gentle low-end emphasis
            bands[i] = Float(base * wobble * tilt)
        }
        applySpectrum(bands)
        applyLevels(Float(base * (0.6 + 0.4 * sin(synthPhase * 1.3))),
                    Float(base * (0.6 + 0.4 * sin(synthPhase * 1.3 + 0.5))))
    }

    // MARK: - Shared helpers

    private static func rmsToUnit(_ rms: Float) -> Float {
        let db = 20 * log10f(max(rms, 1e-7))
        return min(max((db + 50) / 50, 0), 1)       // -50 dB floor
    }

    // These publish raw targets now; per-frame ballistics (smoothing) happens in
    // the render loop (AmplifierRig), decoupled from the audio tap rate.
    private func applySpectrum(_ target: [Float]) {
        spectrum = target
    }

    private func applyLevels(_ targetL: Float, _ targetR: Float) {
        levelL = targetL
        levelR = targetR
    }

    func reset() {
        spectrum = [Float](repeating: 0, count: bandCount)
        levelL = 0
        levelR = 0
        monoAccum.removeAll(keepingCapacity: true)
    }
}
