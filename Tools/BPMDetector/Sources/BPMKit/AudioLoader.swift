//
// AudioLoader.swift
//
// Lädt eine beliebige von AVFoundation lesbare Audiodatei und liefert sie als
// Mono-Float-Signal bei einer Zielrate (Default 11025 Hz). Genau die Form, die
// der `BPMEstimator` erwartet. Die Sample-Rate-Konversion und der Downmix zu
// Mono übernimmt `AVAudioConverter`.
//

import AVFoundation

public enum AudioLoaderError: Error, CustomStringConvertible {
    case formatCreationFailed
    case converterCreationFailed
    case bufferAllocationFailed
    case readFailed(String)

    public var description: String {
        switch self {
        case .formatCreationFailed: return "Zielformat konnte nicht erstellt werden"
        case .converterCreationFailed: return "AVAudioConverter konnte nicht erstellt werden"
        case .bufferAllocationFailed: return "Audiopuffer konnte nicht angelegt werden"
        case .readFailed(let message): return "Lesen/Konvertieren fehlgeschlagen: \(message)"
        }
    }
}

public enum AudioLoader {
    /// Standard-Zielrate für die Analyse. Niedrig genug, dass die FFT billig
    /// bleibt, hoch genug für den Bass- und Mittenbereich, der den Beat trägt.
    public static let defaultSampleRate: Double = 11025

    /// Höhere Zielrate für die Beat-Regelmäßigkeit (#23). Erst hier liegen die
    /// perkussiven Hochfrequenzen — Becken, Hi-Hats, Snare-Transienten über 5,5 kHz —
    /// im Analyseband (Nyquist 11 kHz); sie zeichnen die Onsets scharf, auf denen
    /// die rhythmische Regelmäßigkeit gemessen wird.
    public static let beatSampleRate: Double = 22050

    /// Lädt `url` als Mono-Float-Signal bei `sampleRate`.
    public static func loadMonoSamples(
        url: URL,
        sampleRate: Double = defaultSampleRate
    ) throws -> [Float] {
        let file = try AVAudioFile(forReading: url)
        let sourceFormat = file.processingFormat
        let sourceLength = AVAudioFrameCount(file.length)
        guard sourceLength > 0 else { return [] }

        guard let targetFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: sampleRate,
            channels: 1,
            interleaved: false
        ) else {
            throw AudioLoaderError.formatCreationFailed
        }

        guard let converter = AVAudioConverter(from: sourceFormat, to: targetFormat) else {
            throw AudioLoaderError.converterCreationFailed
        }

        guard let inputBuffer = AVAudioPCMBuffer(
            pcmFormat: sourceFormat,
            frameCapacity: sourceLength
        ) else {
            throw AudioLoaderError.bufferAllocationFailed
        }
        try file.read(into: inputBuffer)

        // Den gesamten Datei-Inhalt einmal anbieten, danach das Stream-Ende
        // signalisieren. Der Converter zieht nach Bedarf nach. Der Zustand
        // liegt in einer Klasse: der Input-Block ist `@Sendable`, darf also
        // keine veränderliche Variable und keinen non-Sendable-Buffer direkt
        // einfangen. Der Converter ruft den Block synchron auf demselben
        // Thread auf — daher ist `@unchecked Sendable` hier sicher.
        let feed = ConversionFeed(inputBuffer)
        let inputBlock: AVAudioConverterInputBlock = { _, outStatus in feed.next(outStatus) }

        var samples = [Float]()
        let chunkFrames: AVAudioFrameCount = 16384

        while true {
            guard let outputBuffer = AVAudioPCMBuffer(
                pcmFormat: targetFormat,
                frameCapacity: chunkFrames
            ) else {
                throw AudioLoaderError.bufferAllocationFailed
            }

            var conversionError: NSError?
            let status = converter.convert(to: outputBuffer, error: &conversionError, withInputFrom: inputBlock)

            if let conversionError {
                throw AudioLoaderError.readFailed(conversionError.localizedDescription)
            }

            append(outputBuffer, to: &samples)

            switch status {
            case .haveData:
                continue
            case .endOfStream, .inputRanDry:
                return samples
            case .error:
                throw AudioLoaderError.readFailed("Converter meldete .error")
            @unknown default:
                return samples
            }
        }
    }

    private static func append(_ buffer: AVAudioPCMBuffer, to samples: inout [Float]) {
        let count = Int(buffer.frameLength)
        guard count > 0, let channel = buffer.floatChannelData?[0] else { return }
        samples.append(contentsOf: UnsafeBufferPointer(start: channel, count: count))
    }
}

/// Liefert den gesamten Eingabepuffer genau einmal an den Converter und
/// signalisiert danach das Stream-Ende. Kapselt den veränderlichen Zustand,
/// damit der `@Sendable` Input-Block ihn nicht direkt einfangen muss.
private final class ConversionFeed: @unchecked Sendable {
    private let buffer: AVAudioPCMBuffer
    private var provided = false

    init(_ buffer: AVAudioPCMBuffer) { self.buffer = buffer }

    func next(_ outStatus: UnsafeMutablePointer<AVAudioConverterInputStatus>) -> AVAudioPCMBuffer? {
        if provided {
            outStatus.pointee = .endOfStream
            return nil
        }
        provided = true
        outStatus.pointee = .haveData
        return buffer
    }
}
