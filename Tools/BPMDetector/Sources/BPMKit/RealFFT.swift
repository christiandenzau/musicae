//
// RealFFT.swift
//
// Dünner Wrapper um vDSPs reelle FFT (`vDSP_fft_zrip`). Hält das (teure)
// FFT-Setup über viele Frames hinweg, damit der spektrale Fluss eines ganzen
// Titels nur einen Setup-Aufbau kostet.
//

import Accelerate

/// Berechnet das Magnitudenspektrum reeller Eingangsfenster fester Länge.
final class RealFFT {
    let size: Int
    private let halfSize: Int
    private let log2n: vDSP_Length
    private let setup: FFTSetup
    private var realp: [Float]
    private var imagp: [Float]

    /// - Parameter size: Fensterlänge, muss eine Zweierpotenz sein.
    init(size: Int) {
        precondition(size > 0 && (size & (size - 1)) == 0, "FFT-Größe muss eine Zweierpotenz sein")
        self.size = size
        self.halfSize = size / 2
        self.log2n = vDSP_Length(log2(Double(size)).rounded())
        guard let setup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2)) else {
            fatalError("vDSP_create_fftsetup fehlgeschlagen für Größe \(size)")
        }
        self.setup = setup
        self.realp = [Float](repeating: 0, count: halfSize)
        self.imagp = [Float](repeating: 0, count: halfSize)
    }

    deinit {
        vDSP_destroy_fftsetup(setup)
    }

    /// Liefert die linearen Magnituden der `size/2` positiven Frequenzbins.
    ///
    /// - Parameter window: reelles Eingangsfenster der Länge `size` (bereits
    ///   mit einer Fensterfunktion multipliziert).
    /// - Returns: `size/2` Magnitudenwerte. Bin 0 (DC, mit Nyquist verpackt)
    ///   ist für Onset-Zwecke unbrauchbar und wird vom Aufrufer ignoriert.
    func magnitudes(of window: [Float]) -> [Float] {
        precondition(window.count == size, "Fenster muss \(size) Samples haben, hat \(window.count)")
        var output = [Float](repeating: 0, count: halfSize)

        realp.withUnsafeMutableBufferPointer { realpPtr in
            imagp.withUnsafeMutableBufferPointer { imagpPtr in
                var split = DSPSplitComplex(realp: realpPtr.baseAddress!, imagp: imagpPtr.baseAddress!)

                // Reellen Eingang in das Split-Complex-Format packen
                // (gerade Indizes → realp, ungerade → imagp).
                window.withUnsafeBufferPointer { inPtr in
                    inPtr.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: halfSize) { complexInput in
                        vDSP_ctoz(complexInput, 2, &split, 1, vDSP_Length(halfSize))
                    }
                }

                vDSP_fft_zrip(setup, &split, 1, log2n, FFTDirection(FFT_FORWARD))

                // Betrag pro Bin. Absolute Skalierung ist für den spektralen
                // Fluss (Differenzen) irrelevant, daher kein Normierungsfaktor.
                output.withUnsafeMutableBufferPointer { outPtr in
                    vDSP_zvabs(&split, 1, outPtr.baseAddress!, 1, vDSP_Length(halfSize))
                }
            }
        }

        return output
    }
}
