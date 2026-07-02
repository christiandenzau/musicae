//
//  SpectrumAnalyzer.swift
//  Musicae
//
//  Turns a block of PCM samples into a small set of log-spaced frequency-band
//  levels suitable for driving a visualizer. Optimized for a lively, stable
//  display rather than analysis precision. The (expensive) FFT setup is created
//  once and reused across frames.
//

import Accelerate

final class SpectrumAnalyzer {
    let fftSize: Int
    let bandCount: Int

    private let halfSize: Int
    private let log2n: vDSP_Length
    private let setup: FFTSetup
    private var window: [Float]          // Hann window, applied before the FFT
    private var realp: [Float]
    private var imagp: [Float]
    private var windowed: [Float]
    private let bandEdges: [Int]         // bin-index boundaries, bandCount + 1 entries

    /// - Parameters:
    ///   - fftSize: window length, must be a power of two.
    ///   - sampleRate: used only to lay out the log-spaced band edges.
    ///   - bandCount: number of output bands (one per Spectrum_Bar in the model).
    init(fftSize: Int = 2048, sampleRate: Double = 44_100, bandCount: Int = 12) {
        precondition(fftSize > 0 && (fftSize & (fftSize - 1)) == 0, "fftSize must be a power of two")
        self.fftSize = fftSize
        self.bandCount = bandCount
        self.halfSize = fftSize / 2
        self.log2n = vDSP_Length(log2(Double(fftSize)).rounded())

        guard let setup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2)) else {
            fatalError("vDSP_create_fftsetup failed for size \(fftSize)")
        }
        self.setup = setup
        self.realp = [Float](repeating: 0, count: halfSize)
        self.imagp = [Float](repeating: 0, count: halfSize)
        self.windowed = [Float](repeating: 0, count: fftSize)

        var win = [Float](repeating: 0, count: fftSize)
        vDSP_hann_window(&win, vDSP_Length(fftSize), Int32(vDSP_HANN_NORM))
        self.window = win

        // Log-spaced band edges from ~40 Hz up to Nyquist, mapped to bin indices.
        // Bin 0 (DC) is skipped by clamping the lower bound to 1.
        let nyquist = sampleRate / 2
        let minFreq = 40.0
        var edges = [Int]()
        for i in 0...bandCount {
            let frac = Double(i) / Double(bandCount)
            let freq = minFreq * pow(nyquist / minFreq, frac)
            let bin = Int((freq / nyquist * Double(halfSize)).rounded())
            edges.append(min(max(bin, 1), halfSize))
        }
        self.bandEdges = edges
    }

    deinit {
        vDSP_destroy_fftsetup(setup)
    }

    /// Returns `bandCount` normalized band levels in 0...1 (dB-mapped).
    /// `samples` must be exactly `fftSize` long.
    ///
    /// The dB floor and range below are heuristics tuned by eye; expect to
    /// nudge them once real signal is flowing.
    func analyze(_ samples: [Float]) -> [Float] {
        precondition(samples.count == fftSize, "expected \(fftSize) samples, got \(samples.count)")

        // Window the input (reduces spectral leakage).
        vDSP_vmul(samples, 1, window, 1, &windowed, 1, vDSP_Length(fftSize))

        var magnitudes = [Float](repeating: 0, count: halfSize)
        realp.withUnsafeMutableBufferPointer { rp in
            imagp.withUnsafeMutableBufferPointer { ip in
                var split = DSPSplitComplex(realp: rp.baseAddress!, imagp: ip.baseAddress!)

                // Pack the real input into split-complex form (even → realp,
                // odd → imagp), then run the in-place real forward FFT.
                windowed.withUnsafeBufferPointer { inPtr in
                    inPtr.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: halfSize) { complexInput in
                        vDSP_ctoz(complexInput, 2, &split, 1, vDSP_Length(halfSize))
                    }
                }
                vDSP_fft_zrip(setup, &split, 1, log2n, FFTDirection(FFT_FORWARD))

                magnitudes.withUnsafeMutableBufferPointer { out in
                    vDSP_zvabs(&split, 1, out.baseAddress!, 1, vDSP_Length(halfSize))
                }
            }
        }

        // Group bins into bands (mean magnitude), map to dB, normalize to 0...1.
        var bands = [Float](repeating: 0, count: bandCount)
        let scale = 1.0 / Float(fftSize)
        for b in 0..<bandCount {
            let lo = bandEdges[b]
            let hi = max(bandEdges[b + 1], lo + 1)
            var sum: Float = 0
            for bin in lo..<hi { sum += magnitudes[bin] }
            let mean = sum / Float(hi - lo) * scale
            let db = 20 * log10f(max(mean, 1e-7))       // -140 dB … 0 dB-ish
            let norm = (db + 60) / 60                    // -60 dB floor → 0, 0 dB → 1
            bands[b] = min(max(norm, 0), 1)
        }
        return bands
    }
}
