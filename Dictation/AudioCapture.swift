import AVFoundation
import Foundation

/// Captures the current input device and exposes wire-ready PCM without retaining audio on disk.
///
/// The class is main-actor isolated because AVAudioEngine setup and teardown are main-thread work.
/// Its tap uses the lock-protected `CapturePipeline` below, so real-time conversion never queues
/// unbounded work back to the main actor.
@MainActor
final class AudioCapture {
    private static let targetSampleRate = 16_000.0
    private static let targetChannelCount: AVAudioChannelCount = 1

    private let engine = AVAudioEngine()
    private var capture: CapturePipeline?
    private var inputNode: AVAudioInputNode?
    private var configurationObserver: NSObjectProtocol?
    private var tapInstalled = false

    init() {}

    /// `true` only while the input engine and its converter are accepting microphone frames.
    var isCapturing: Bool {
        guard let capture, capture.isActive else {
            return false
        }

        // A stopped engine without an explicit configuration notification is still input loss.
        guard engine.isRunning else {
            capture.markInputUnavailable()
            return false
        }

        return true
    }

    /// Starts capture in the hardware's native input format and converts it to 16 kHz mono PCM.
    func start() throws {
        guard capture == nil else {
            throw AudioCaptureFailure.pendingAudioNeedsDrain
        }

        let inputNode = engine.inputNode
        let sourceFormat = inputNode.outputFormat(forBus: 0)
        guard sourceFormat.sampleRate.isFinite,
              sourceFormat.sampleRate > 0,
              sourceFormat.channelCount > 0 else {
            throw AudioCaptureFailure.inputUnavailable
        }

        guard let destinationFormat = AVAudioFormat(
            commonFormat: .pcmFormatInt16,
            sampleRate: Self.targetSampleRate,
            channels: Self.targetChannelCount,
            interleaved: true
        ) else {
            throw AudioCaptureFailure.unsupportedFormat
        }

        guard let pipeline = CapturePipeline(
            sourceFormat: sourceFormat,
            destinationFormat: destinationFormat
        ) else {
            throw AudioCaptureFailure.unsupportedFormat
        }

        var installedTap = false
        var observer: NSObjectProtocol?

        do {
            pipeline.activate()

            // Passing nil preserves the device's current native format for the tap. The converter
            // owns the explicit downmix and resampling to the fixed network format.
            inputNode.installTap(onBus: 0, bufferSize: 1_600, format: nil, block: pipeline.makeTap())
            installedTap = true

            // Do not touch the main-actor engine from this notification callback. The pipeline
            // becomes inactive immediately; drain() performs the engine cleanup on the main actor.
            observer = NotificationCenter.default.addObserver(
                forName: .AVAudioEngineConfigurationChange,
                object: engine,
                queue: nil
            ) { @Sendable [weak pipeline] _ in
                pipeline?.markConfigurationChanged()
            }

            engine.prepare()
            try engine.start()

            if let failure = pipeline.failure {
                throw failure
            }

            self.capture = pipeline
            self.inputNode = inputNode
            self.configurationObserver = observer
            self.tapInstalled = installedTap
        } catch {
            pipeline.stopAccepting()
            if installedTap {
                inputNode.removeTap(onBus: 0)
            }
            engine.stop()
            if let observer {
                NotificationCenter.default.removeObserver(observer)
            }
            pipeline.abort()

            if let failure = error as? AudioCaptureFailure {
                throw failure
            }
            throw AudioCaptureFailure.couldNotStart
        }
    }

    /// Stops accepting microphone frames. Converted full chunks and the final short tail remain
    /// available through `drain()` until they are consumed.
    func stop() {
        guard let capture else {
            return
        }

        capture.stopAccepting()
        tearDownEngine()

        if capture.failure == nil {
            capture.seal()
        } else {
            capture.abort()
        }
    }

    /// Returns ordered 16 kHz mono signed-Int16 little-endian PCM chunks.
    ///
    /// Full chunks are 100 ms (3,200 bytes); after `stop()`, the last chunk may be shorter.
    /// Any capture, input, conversion, or capacity failure is surfaced here instead of dropping
    /// audio silently.
    func drain() throws -> [Data] {
        guard let capture else {
            return []
        }

        if capture.isActive, !engine.isRunning {
            capture.markInputUnavailable()
        }

        if let failure = capture.failure {
            tearDownEngine()
            capture.abort()
            self.capture = nil
            throw failure
        }

        let chunks = capture.drainChunks()
        if capture.isSealedAndEmpty {
            self.capture = nil
        }
        return chunks
    }

    private func tearDownEngine() {
        if tapInstalled, let inputNode {
            // stopAccepting() ran before this method, so an in-flight callback can only finish
            // conversion; it cannot append new audio after the tap is removed.
            inputNode.removeTap(onBus: 0)
        }
        tapInstalled = false

        engine.stop()

        if let configurationObserver {
            NotificationCenter.default.removeObserver(configurationObserver)
        }
        configurationObserver = nil
        inputNode = nil
    }
}

enum AudioCaptureFailure: LocalizedError {
    case pendingAudioNeedsDrain
    case inputUnavailable
    case unsupportedFormat
    case couldNotStart
    case inputInterrupted
    case audioBufferOverflow
    case conversionFailed

    var errorDescription: String? {
        switch self {
        case .pendingAudioNeedsDrain:
            return "Finish the previous microphone capture before starting another one."
        case .inputUnavailable:
            return "The microphone input is unavailable."
        case .unsupportedFormat:
            return "The microphone format cannot be converted for dictation."
        case .couldNotStart:
            return "The microphone could not be started."
        case .inputInterrupted:
            return "The microphone input changed or was interrupted."
        case .audioBufferOverflow:
            return "Microphone audio could not be kept up with."
        case .conversionFailed:
            return "Microphone audio could not be converted."
        }
    }
}

/// State shared by AVAudioEngine's real-time tap and the main actor.
///
/// `@unchecked Sendable` is intentional: every mutable field, including the non-Sendable
/// AVAudioConverter and reusable output buffer, is accessed only while `lock` is held. The tap
/// never dispatches buffers elsewhere, so this also bounds both queued audio and pending work.
final class CapturePipeline: @unchecked Sendable {
    private static let chunkByteCount = 3_200 // 100 ms × 16,000 frames/s × 2 bytes/frame
    private static let maximumBufferedByteCount = 320_000 // Ten seconds of target PCM
    private static let maximumConversionPasses = 8

    private let lock = NSLock()
    private let converter: AVAudioConverter
    private let sourceSampleRate: Double
    private let sourceChannelCount: AVAudioChannelCount
    private let destinationFormat: AVAudioFormat

    private var reusableOutputBuffer: AVAudioPCMBuffer?
    // Borrowed only during synchronous convert(), while the pipeline lock is held.
    private var conversionInput: AVAudioPCMBuffer?
    private var chunks: [Data] = []
    private var chunkByteCount = 0
    private var pendingPCM = Data()
    private var bufferedByteCount = 0
    private var active = false
    private var sealed = false
    private var storedFailure: AudioCaptureFailure?

    // Create the callback outside AudioCapture's main actor. AVAudioEngine invokes it
    // on its audio queue; an actor-inheriting closure traps on the very first buffer.
    func makeTap() -> @Sendable (AVAudioPCMBuffer, AVAudioTime) -> Void {
        { [self] buffer, _ in process(buffer) }
    }

    init?(sourceFormat: AVAudioFormat, destinationFormat: AVAudioFormat) {
        guard let converter = AVAudioConverter(from: sourceFormat, to: destinationFormat) else {
            return nil
        }

        self.converter = converter
        self.sourceSampleRate = sourceFormat.sampleRate
        self.sourceChannelCount = sourceFormat.channelCount
        self.destinationFormat = destinationFormat
    }

    var isActive: Bool {
        lock.lock()
        defer { lock.unlock() }
        return active
    }

    var isSealedAndEmpty: Bool {
        lock.lock()
        defer { lock.unlock() }
        return sealed && chunks.isEmpty && pendingPCM.isEmpty
    }

    var failure: AudioCaptureFailure? {
        lock.lock()
        defer { lock.unlock() }
        return storedFailure
    }

    func activate() {
        lock.lock()
        defer { lock.unlock() }
        active = true
    }

    func stopAccepting() {
        lock.lock()
        defer { lock.unlock() }
        active = false
    }

    func markConfigurationChanged() {
        lock.lock()
        defer { lock.unlock() }
        failLocked(.inputInterrupted)
    }

    func markInputUnavailable() {
        lock.lock()
        defer { lock.unlock() }
        failLocked(.inputUnavailable)
    }

    func process(_ inputBuffer: AVAudioPCMBuffer) {
        lock.lock()
        defer { lock.unlock() }

        guard active, !sealed, storedFailure == nil else {
            return
        }

        guard inputBuffer.format.sampleRate == sourceSampleRate,
              inputBuffer.format.channelCount == sourceChannelCount else {
            failLocked(.inputInterrupted)
            return
        }

        guard inputBuffer.frameLength > 0 else {
            return
        }

        do {
            try convertLocked(inputBuffer)
        } catch let failure as AudioCaptureFailure {
            failLocked(failure)
        } catch {
            failLocked(.conversionFailed)
        }
    }

    func seal() {
        lock.lock()
        defer { lock.unlock() }

        guard !sealed else {
            return
        }

        active = false
        guard storedFailure == nil else {
            sealed = true
            return
        }

        do {
            try flushConverterLocked()
            guard storedFailure == nil else {
                sealed = true
                return
            }
            appendFinalTailLocked()
            sealed = true
        } catch let failure as AudioCaptureFailure {
            failLocked(failure)
            sealed = true
        } catch {
            failLocked(.conversionFailed)
            sealed = true
        }
    }

    func abort() {
        lock.lock()
        defer { lock.unlock() }

        active = false
        sealed = true
        chunks.removeAll(keepingCapacity: false)
        chunkByteCount = 0
        pendingPCM.removeAll(keepingCapacity: false)
        bufferedByteCount = 0
    }

    func drainChunks() -> [Data] {
        lock.lock()
        defer { lock.unlock() }

        let drained = chunks
        chunks.removeAll(keepingCapacity: true)
        bufferedByteCount -= chunkByteCount
        chunkByteCount = 0
        return drained
    }

    private func convertLocked(_ inputBuffer: AVAudioPCMBuffer) throws {
        let capacity = try outputCapacity(for: inputBuffer.frameLength)
        let outputBuffer = try outputBufferLocked(withCapacity: capacity)
        conversionInput = inputBuffer
        defer { conversionInput = nil }

        for _ in 0..<Self.maximumConversionPasses {
            outputBuffer.frameLength = 0
            var conversionError: NSError?
            let status = converter.convert(to: outputBuffer, error: &conversionError) { _, inputStatus in
                guard let input = self.conversionInput else {
                    inputStatus.pointee = .noDataNow
                    return nil
                }

                self.conversionInput = nil
                inputStatus.pointee = .haveData
                return input
            }

            guard conversionError == nil, status != .error else {
                throw AudioCaptureFailure.conversionFailed
            }

            try appendOutputLocked(outputBuffer)

            switch status {
            case .haveData:
                continue
            case .inputRanDry, .endOfStream, .error:
                return
            @unknown default:
                throw AudioCaptureFailure.conversionFailed
            }
        }

        // An output capacity based on the exact rate ratio should not require this many passes.
        // Treat an unexpected converter stall as an explicit failure rather than losing samples.
        throw AudioCaptureFailure.conversionFailed
    }

    private func flushConverterLocked() throws {
        let outputBuffer = try outputBufferLocked(withCapacity: 256)

        for _ in 0..<Self.maximumConversionPasses {
            outputBuffer.frameLength = 0
            var conversionError: NSError?
            let status = converter.convert(to: outputBuffer, error: &conversionError) { _, inputStatus in
                inputStatus.pointee = .endOfStream
                return nil
            }

            guard conversionError == nil, status != .error else {
                throw AudioCaptureFailure.conversionFailed
            }

            try appendOutputLocked(outputBuffer)

            switch status {
            case .haveData:
                continue
            case .inputRanDry, .endOfStream, .error:
                return
            @unknown default:
                throw AudioCaptureFailure.conversionFailed
            }
        }

        throw AudioCaptureFailure.conversionFailed
    }

    private func outputCapacity(for inputFrameCount: AVAudioFrameCount) throws -> AVAudioFrameCount {
        let convertedFrames = (
            Double(inputFrameCount) * destinationFormat.sampleRate / sourceSampleRate
        ).rounded(.up)
        let capacity = convertedFrames + 64 // covers sample-rate-converter filter delay

        guard capacity.isFinite,
              capacity > 0,
              capacity <= Double(AVAudioFrameCount.max) else {
            throw AudioCaptureFailure.conversionFailed
        }

        return AVAudioFrameCount(capacity)
    }

    private func outputBufferLocked(withCapacity capacity: AVAudioFrameCount) throws -> AVAudioPCMBuffer {
        if let reusableOutputBuffer, reusableOutputBuffer.frameCapacity >= capacity {
            return reusableOutputBuffer
        }

        guard let outputBuffer = AVAudioPCMBuffer(
            pcmFormat: destinationFormat,
            frameCapacity: capacity
        ) else {
            throw AudioCaptureFailure.conversionFailed
        }

        reusableOutputBuffer = outputBuffer
        return outputBuffer
    }

    private func appendOutputLocked(_ outputBuffer: AVAudioPCMBuffer) throws {
        let frameCount = Int(outputBuffer.frameLength)
        guard frameCount > 0 else {
            return
        }

        let byteCount = frameCount * MemoryLayout<Int16>.stride
        guard byteCount > 0,
              let sampleBytes = outputBuffer.audioBufferList.pointee.mBuffers.mData else {
            throw AudioCaptureFailure.conversionFailed
        }
        guard bufferedByteCount <= Self.maximumBufferedByteCount - byteCount else {
            throw AudioCaptureFailure.audioBufferOverflow
        }

        pendingPCM.append(sampleBytes.assumingMemoryBound(to: UInt8.self), count: byteCount)
        bufferedByteCount += byteCount

        while pendingPCM.count >= Self.chunkByteCount {
            let nextChunk = Data(pendingPCM.prefix(Self.chunkByteCount))
            chunks.append(nextChunk)
            chunkByteCount += nextChunk.count
            pendingPCM.removeFirst(Self.chunkByteCount)
        }
    }

    private func appendFinalTailLocked() {
        guard !pendingPCM.isEmpty else {
            return
        }

        chunks.append(pendingPCM)
        chunkByteCount += pendingPCM.count
        pendingPCM = Data()
    }

    private func failLocked(_ failure: AudioCaptureFailure) {
        guard storedFailure == nil else {
            return
        }

        storedFailure = failure
        active = false
    }
}
