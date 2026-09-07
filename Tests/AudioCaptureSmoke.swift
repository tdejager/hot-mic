import AVFoundation
import Foundation

@main
@MainActor
struct AudioCaptureSmoke {
    static func main() async throws {
        for rate in [16_000.0, 44_100.0, 48_000.0] {
            for channels: AVAudioChannelCount in [1, 2] {
                let source = AVAudioFormat(standardFormatWithSampleRate: rate, channels: channels)!
                let target = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16_000,
                                           channels: 1, interleaved: true)!
                let pipeline = CapturePipeline(sourceFormat: source, destinationFormat: target)!
                // Obtain the exact production callback on MainActor, as AudioCapture.start does.
                let tap = pipeline.makeTap()
                pipeline.activate()
                var bytes = try await Task.detached {
                    precondition(!Thread.isMainThread)
                    let input = AVAudioFormat(standardFormatWithSampleRate: rate, channels: channels)!
                    let frames = AVAudioFrameCount(rate / 50)
                    let buffer = AVAudioPCMBuffer(pcmFormat: input, frameCapacity: frames)!
                    buffer.frameLength = frames
                    for channel in 0..<Int(channels) {
                        buffer.floatChannelData![channel].initialize(repeating: 0.25, count: Int(frames))
                    }
                    var converted = Data()
                    for _ in 0..<50 {
                        tap(buffer, AVAudioTime(sampleTime: 0, atRate: rate))
                        if let error = pipeline.failure { throw error }
                        for chunk in pipeline.drainChunks() {
                            precondition(chunk.count == 3_200, "Non-final wire chunk is not 100 ms")
                            converted.append(chunk)
                        }
                    }
                    return converted
                }.value
                pipeline.stopAccepting()
                pipeline.seal()
                if let error = pipeline.failure { throw error }
                for chunk in pipeline.drainChunks() { bytes.append(chunk) }
                let samples = bytes.withUnsafeBytes { Array($0.bindMemory(to: Int16.self)) }
                precondition(samples.count == 16_000, "Resampler lost samples or final tail")
                precondition(samples.dropFirst(100).dropLast(100).allSatisfy { abs(Int($0) - 8_192) <= 2 },
                             "Wrong signed PCM magnitude or stereo downmix")
                pipeline.seal()
                precondition(!pipeline.isActive && pipeline.drainChunks().isEmpty)
                print("PASS background production tap: \(Int(rate)) Hz / \(channels) ch, 16000 output samples")
            }
        }
        let input = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1)!
        let target = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16_000,
                                   channels: 1, interleaved: true)!
        let pipeline = CapturePipeline(sourceFormat: input, destinationFormat: target)!
        let tap = pipeline.makeTap()
        pipeline.activate()
        await Task.detached {
            let format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1)!
            let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 12_345)!
            buffer.frameLength = 12_345
            buffer.floatChannelData![0].initialize(repeating: -0.25, count: 12_345)
            tap(buffer, AVAudioTime(sampleTime: 0, atRate: 48_000))
        }.value
        pipeline.stopAccepting()
        pipeline.seal()
        if let error = pipeline.failure { throw error }
        precondition(pipeline.drainChunks().map(\.count) == [3_200, 3_200, 1_830], "Short final tail lost")
        await Task.detached {
            let format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1)!
            let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 480)!
            buffer.frameLength = 480
            buffer.floatChannelData![0].initialize(repeating: 0, count: 480)
            tap(buffer, AVAudioTime(sampleTime: 0, atRate: 48_000))
        }.value
        precondition(pipeline.drainChunks().isEmpty, "Late callback added audio after stop")
        print("PASS short converted tail retained; late background callback ignored after stop")
    }
}
