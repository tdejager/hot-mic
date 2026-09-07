import Foundation

struct RealtimeConfiguration: Sendable {
    var language: String? = nil
    var keyterms: [String] = []
    var zeroRetention: Bool = false
}

enum RealtimeEvent: Sendable {
    case ready
    case partial(String)
    case committed(String)
    case failed(String)
}

struct RealtimeResult: Sendable {
    let text: String
    let language: String?
}

enum RealtimeClientError: LocalizedError, Sendable {
    case noActiveSession
    case sessionFinalizing
    case invalidConfiguration
    case invalidAudio
    case audioBufferFull
    case cancelled
    case noSpeech
    case connectionTimedOut
    case connectionClosed(code: Int)
    case networkFailed
    case sendTimedOut
    case acknowledgementTimedOut
    case authenticationFailed
    case quotaExceeded
    case commitThrottled
    case termsNotAccepted
    case rateLimited
    case providerQueueFull
    case providerUnavailable
    case sessionLimitExceeded
    case invalidRequest
    case insufficientAudio
    case transcriptionFailed
    case protocolViolation

    var errorDescription: String? {
        switch self {
        case .noActiveSession:
            return "No active transcription session."
        case .sessionFinalizing:
            return "The transcription is already finishing."
        case .invalidConfiguration:
            return "The transcription configuration is invalid."
        case .invalidAudio:
            return "The captured audio is not valid 16 kHz PCM."
        case .audioBufferFull:
            return "Audio could not be streamed quickly enough. Stop and try again."
        case .cancelled:
            return "The transcription was canceled."
        case .noSpeech:
            return "No speech was captured."
        case .connectionTimedOut:
            return "ElevenLabs did not connect in time."
        case .connectionClosed(let code):
            if code == 1008 {
                return "ElevenLabs rejected the session (WebSocket 1008: policy violation). Check the selected language, vocabulary limits and zero-retention eligibility."
            }
            return "ElevenLabs closed the session (WebSocket \(code)) before transcription finished."
        case .networkFailed:
            return "The network connection to ElevenLabs failed."
        case .sendTimedOut:
            return "Audio could not be sent to ElevenLabs in time."
        case .acknowledgementTimedOut:
            return "ElevenLabs did not finalize the transcript in time."
        case .authenticationFailed:
            return "ElevenLabs rejected the API key."
        case .quotaExceeded:
            return "The ElevenLabs transcription quota is exhausted."
        case .commitThrottled:
            return "ElevenLabs is not ready for another transcript segment."
        case .termsNotAccepted:
            return "ElevenLabs requires account terms to be accepted."
        case .rateLimited:
            return "ElevenLabs is rate limiting transcription requests."
        case .providerQueueFull:
            return "ElevenLabs is temporarily too busy to accept audio."
        case .providerUnavailable:
            return "ElevenLabs is temporarily unavailable."
        case .sessionLimitExceeded:
            return "The ElevenLabs transcription session reached its time limit."
        case .invalidRequest:
            return "ElevenLabs rejected the transcription request."
        case .insufficientAudio:
            return "ElevenLabs did not detect enough speech."
        case .transcriptionFailed:
            return "ElevenLabs could not transcribe this audio."
        case .protocolViolation:
            return "ElevenLabs returned an unexpected transcription response."
        }
    }
}

private final class RealtimeTimeoutBox<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var result: Result<Value, Error>?
    private var continuation: CheckedContinuation<Value, Error>?
    private var operationTask: Task<Void, Never>?
    private var timeoutTask: Task<Void, Never>?

    func install(_ continuation: CheckedContinuation<Value, Error>) {
        lock.lock()
        let result = self.result
        if result == nil {
            self.continuation = continuation
        }
        lock.unlock()

        if let result {
            continuation.resume(with: result)
        }
    }

    func setTasks(operation: Task<Void, Never>, timeout: Task<Void, Never>) {
        lock.lock()
        let alreadyResolved = result != nil
        if !alreadyResolved {
            operationTask = operation
            timeoutTask = timeout
        }
        lock.unlock()

        if alreadyResolved {
            operation.cancel()
            timeout.cancel()
        }
    }

    func resolve(
        _ result: Result<Value, Error>,
        cancellingOperation: Bool,
        cancellingTimeout: Bool
    ) {
        lock.lock()
        guard self.result == nil else {
            lock.unlock()
            return
        }

        self.result = result
        let continuation = self.continuation
        self.continuation = nil
        let operationTask = self.operationTask
        self.operationTask = nil
        let timeoutTask = self.timeoutTask
        self.timeoutTask = nil
        lock.unlock()

        if cancellingOperation {
            operationTask?.cancel()
        }
        if cancellingTimeout {
            timeoutTask?.cancel()
        }
        continuation?.resume(with: result)
    }
}

@MainActor
final class RealtimeClient {
    private enum Phase {
        case idle
        case connecting
        case streaming
        case finishing
        case completed
        case failed
        case cancelled
    }

    private struct InputAudioChunk: Encodable {
        let audioBase64: String
        let commit: Bool

        enum CodingKeys: String, CodingKey {
            case messageType = "message_type"
            case audioBase64 = "audio_base_64"
            case commit
            case sampleRate = "sample_rate"
        }

        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode("input_audio_chunk", forKey: .messageType)
            try container.encode(audioBase64, forKey: .audioBase64)
            try container.encode(commit, forKey: .commit)
            try container.encode(Self.sampleRate, forKey: .sampleRate)
        }

        private static let sampleRate = 16_000
    }

    // URLSession's default delegate queue is serial; responseStatus never leaves that queue.
    private final class WebSocketDelegate: NSObject, URLSessionWebSocketDelegate, @unchecked Sendable {
        private let didComplete: @Sendable (Error?, Int?) -> Void
        private let didClose: @Sendable (Int) -> Void
        private var responseStatus: Int?

        init(
            didComplete: @escaping @Sendable (Error?, Int?) -> Void,
            didClose: @escaping @Sendable (Int) -> Void
        ) {
            self.didComplete = didComplete
            self.didClose = didClose
        }

        func urlSession(
            _ session: URLSession,
            task: URLSessionTask,
            didFinishCollecting metrics: URLSessionTaskMetrics
        ) {
            responseStatus = (metrics.transactionMetrics.last?.response as? HTTPURLResponse)?.statusCode
        }

        func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
            didComplete(error, responseStatus ?? (task.response as? HTTPURLResponse)?.statusCode)
        }

        func urlSession(
            _ session: URLSession,
            webSocketTask: URLSessionWebSocketTask,
            didCloseWith closeCode: URLSessionWebSocketTask.CloseCode,
            reason: Data?
        ) {
            didClose(closeCode.rawValue)
        }
    }

    private let endpoint: String
    private static let sampleRate = 16_000
    private static let bytesPerSecond = sampleRate * MemoryLayout<Int16>.size
    private static let maximumBufferedAudioBytes = bytesPerSecond * 10
    private static let maximumWireChunkBytes = bytesPerSecond
    private static let commitSegmentBytes = bytesPerSecond * 24
    private static let minimumProcessableSegmentBytes = bytesPerSecond * 2
    private static let connectionTimeout: Duration = .seconds(15)
    private static let sendTimeout: Duration = .seconds(15)
    private static let acknowledgementTimeout: Duration = .seconds(15)

    private let onEvent: @MainActor (RealtimeEvent) -> Void

    private var phase: Phase = .idle
    private var generation: UInt64 = 0
    private var session: URLSession?
    private var transportDelegate: WebSocketDelegate?
    private var socket: URLSessionWebSocketTask?
    private var receiveTask: Task<Void, Never>?
    private var sendLoopTask: Task<Void, Never>?
    private var connectionTimeoutTask: Task<Void, Never>?
    private var acknowledgementTimeoutTask: Task<Void, Never>?

    // These bytes have been captured but not yet acknowledged by URLSession's send call.
    private var pendingChunks: [Data] = []
    private var nextPendingChunkIndex = 0
    private var outboundRemainder: Data?
    private var bufferedAudioByteCount = 0
    private var capturedAudioByteCount = 0
    private var sentSegmentByteCount = 0

    private var finishRequested = false
    private var awaitingCommit = false
    private var commitSendInFlight = false
    private var pendingCommitAcknowledgement = false
    private var awaitedCommitIsFinal = false
    private var stableSegments: [String] = []
    private var detectedLanguage: String?
    private var requestedLanguage: String?
    private var outcome: Result<RealtimeResult, Error>?
    private var finishContinuations: [CheckedContinuation<RealtimeResult, Error>] = []

    init(
        endpoint: String = "wss://api.elevenlabs.io/v1/speech-to-text/realtime",
        onEvent: @escaping @MainActor (RealtimeEvent) -> Void
    ) {
        self.endpoint = endpoint
        self.onEvent = onEvent
    }

    func connect(apiKey: String, configuration: RealtimeConfiguration) {
        prepareForNewConnection()

        generation &+= 1
        let sessionGeneration = generation
        phase = .connecting

        let normalizedKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedKey.isEmpty else {
            fail(.authenticationFailed)
            return
        }

        do {
            try Self.validate(configuration: configuration)
            let endpoint = try makeEndpoint(configuration: configuration)
            requestedLanguage = Self.normalizedLanguage(configuration.language)

            let delegate = WebSocketDelegate(
                didComplete: { [weak self] error, status in
                    Task { @MainActor [weak self] in
                        self?.transportCompleted(error: error, httpStatus: status, generation: sessionGeneration)
                    }
                },
                didClose: { [weak self] code in
                    Task { @MainActor [weak self] in
                        self?.transportClosed(code: code, generation: sessionGeneration)
                    }
                }
            )

            let sessionConfiguration = URLSessionConfiguration.ephemeral
            sessionConfiguration.requestCachePolicy = .reloadIgnoringLocalCacheData
            sessionConfiguration.urlCache = nil
            sessionConfiguration.urlCredentialStorage = nil
            sessionConfiguration.httpCookieStorage = nil
            sessionConfiguration.httpShouldSetCookies = false
            sessionConfiguration.httpMaximumConnectionsPerHost = 1

            let session = URLSession(configuration: sessionConfiguration, delegate: delegate, delegateQueue: nil)
            var request = URLRequest(url: endpoint)
            request.timeoutInterval = Self.connectionTimeout.secondsAsTimeInterval
            request.setValue(normalizedKey, forHTTPHeaderField: "xi-api-key")

            let socket = session.webSocketTask(with: request)
            self.session = session
            transportDelegate = delegate
            self.socket = socket
            startConnectionTimeout(generation: sessionGeneration)
            startReceiveLoop(generation: sessionGeneration)
            socket.resume()
        } catch let error as RealtimeClientError {
            fail(error)
        } catch {
            fail(.invalidConfiguration)
        }
    }

    func enqueue(_ pcm: Data) throws {
        guard isActive else { throw RealtimeClientError.noActiveSession }
        guard !finishRequested else { throw RealtimeClientError.sessionFinalizing }
        guard pcm.count.isMultiple(of: MemoryLayout<Int16>.size) else {
            throw RealtimeClientError.invalidAudio
        }
        guard !pcm.isEmpty else { return }
        guard bufferedAudioByteCount <= Self.maximumBufferedAudioBytes - pcm.count else {
            throw RealtimeClientError.audioBufferFull
        }

        pendingChunks.append(pcm)
        bufferedAudioByteCount += pcm.count
        capturedAudioByteCount += pcm.count
        startSendLoopIfPossible(generation: generation)
    }

    func finish() async throws -> RealtimeResult {
        try await withTaskCancellationHandler(operation: {
            if let outcome {
                return try outcome.get()
            }
            guard isActive else { throw RealtimeClientError.noActiveSession }

            return try await withCheckedThrowingContinuation { continuation in
                if let outcome {
                    continuation.resume(with: outcome)
                    return
                }
                finishContinuations.append(continuation)
                requestFinalization(generation: generation)
            }
        }, onCancel: { [weak self] in
            Task { @MainActor [weak self] in
                self?.cancel()
            }
        })
    }

    func cancel() {
        guard isActive else { return }

        generation &+= 1
        phase = .cancelled
        closeTransport(closeCode: .goingAway)
        clearAudioBuffers()
        stableSegments.removeAll(keepingCapacity: false)
        detectedLanguage = nil
        requestedLanguage = nil
        finishRequested = false
        awaitingCommit = false
        commitSendInFlight = false
        pendingCommitAcknowledgement = false
        awaitedCommitIsFinal = false
        resolveFinishContinuations(with: .failure(RealtimeClientError.cancelled))
    }

    private var isActive: Bool {
        switch phase {
        case .connecting, .streaming, .finishing:
            return true
        case .idle, .completed, .failed, .cancelled:
            return false
        }
    }

    private func prepareForNewConnection() {
        if isActive {
            cancel()
        } else {
            closeTransport(closeCode: .goingAway)
        }

        phase = .idle
        outcome = nil
        finishRequested = false
        awaitingCommit = false
        commitSendInFlight = false
        pendingCommitAcknowledgement = false
        awaitedCommitIsFinal = false
        stableSegments.removeAll(keepingCapacity: false)
        detectedLanguage = nil
        requestedLanguage = nil
        clearAudioBuffers()
    }

    private func requestFinalization(generation: UInt64) {
        guard isCurrent(generation) else { return }
        guard capturedAudioByteCount > 0 else {
            fail(.noSpeech)
            return
        }

        finishRequested = true
        if phase == .streaming {
            phase = .finishing
        }
        startSendLoopIfPossible(generation: generation)
    }

    private func startReceiveLoop(generation: UInt64) {
        receiveTask?.cancel()
        receiveTask = Task { @MainActor [weak self] in
            await self?.receiveLoop(generation: generation)
        }
    }

    private func receiveLoop(generation: UInt64) async {
        guard let socket else { return }

        while isCurrent(generation) {
            do {
                let message = try await socket.receive()
                guard isCurrent(generation) else { return }
                handle(message: message, generation: generation)
            } catch is CancellationError {
                return
            } catch {
                // Task completion carries upgrade HTTP status. Failing here races it and
                // mislabels rejected credentials/rate limits as generic network errors.
                return
            }
        }
    }

    private func handle(message: URLSessionWebSocketTask.Message, generation: UInt64) {
        let data: Data
        switch message {
        case .string(let string):
            data = Data(string.utf8)
        case .data(let messageData):
            data = messageData
        @unknown default:
            fail(.protocolViolation)
            return
        }

        do {
            guard let payload = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let messageType = payload["message_type"] as? String else {
                fail(.protocolViolation)
                return
            }

            switch messageType {
            case "session_started":
                handleSessionStarted(payload: payload, generation: generation)
            case "partial_transcript":
                guard let text = payload["text"] as? String else {
                    fail(.protocolViolation)
                    return
                }
                handlePartialTranscript(text, generation: generation)
            case "warning", "committed_transcript_with_timestamps", "committed_transcript_entities":
                // Timestamps are disabled. Ignore that variant rather than counting a duplicate transcript.
                break
            case "committed_transcript":
                guard let text = payload["text"] as? String else {
                    fail(.protocolViolation)
                    return
                }
                if let language = payload["language_code"] as? String, !language.isEmpty {
                    detectedLanguage = language
                }
                handleCommittedTranscript(text, generation: generation)
            case "auth_error":
                fail(.authenticationFailed)
            case "quota_exceeded":
                fail(.quotaExceeded)
            case "commit_throttled":
                fail(.commitThrottled)
            case "unaccepted_terms":
                fail(.termsNotAccepted)
            case "rate_limited":
                fail(.rateLimited)
            case "queue_overflow":
                fail(.providerQueueFull)
            case "resource_exhausted":
                fail(.providerUnavailable)
            case "session_time_limit_exceeded":
                fail(.sessionLimitExceeded)
            case "input_error", "invalid_request", "chunk_size_exceeded":
                fail(.invalidRequest)
            case "insufficient_audio_activity":
                fail(.insufficientAudio)
            case "transcriber_error":
                fail(.transcriptionFailed)
            case "error":
                fail(.transcriptionFailed)
            default:
                fail(.protocolViolation)
            }
        } catch {
            fail(.protocolViolation)
        }
    }

    private func handleSessionStarted(payload: [String: Any], generation: UInt64) {
        guard isCurrent(generation), phase == .connecting else { return }
        if let configuration = payload["config"] as? [String: Any],
           let language = configuration["language_code"] as? String,
           !language.isEmpty {
            detectedLanguage = language
        }

        connectionTimeoutTask?.cancel()
        connectionTimeoutTask = nil
        phase = finishRequested ? .finishing : .streaming
        onEvent(.ready)
        guard isCurrent(generation) else { return }
        startSendLoopIfPossible(generation: generation)
    }

    private func handlePartialTranscript(_ text: String, generation: UInt64) {
        guard isCurrent(generation) else { return }
        onEvent(.partial(text))
    }

    private func handleCommittedTranscript(_ text: String, generation: UInt64) {
        guard isCurrent(generation) else { return }
        stableSegments.append(text)
        onEvent(.committed(text))
        guard isCurrent(generation), awaitingCommit else { return }

        if commitSendInFlight {
            pendingCommitAcknowledgement = true
            return
        }
        acknowledgeCommit(generation: generation)
    }

    private func acknowledgeCommit(generation: UInt64) {
        guard isCurrent(generation), awaitingCommit, !commitSendInFlight else { return }

        acknowledgementTimeoutTask?.cancel()
        acknowledgementTimeoutTask = nil
        awaitingCommit = false
        pendingCommitAcknowledgement = false
        sentSegmentByteCount = 0
        let wasFinalCommit = awaitedCommitIsFinal
        awaitedCommitIsFinal = false

        if wasFinalCommit {
            completeSuccessfully()
        } else {
            startSendLoopIfPossible(generation: generation)
        }
    }

    private func startSendLoopIfPossible(generation: UInt64) {
        guard isCurrent(generation), !awaitingCommit, sendLoopTask == nil else { return }
        guard phase == .streaming || phase == .finishing else { return }
        guard finishRequested || outboundRemainder != nil || nextPendingChunkIndex < pendingChunks.count else { return }

        sendLoopTask = Task { @MainActor [weak self] in
            await self?.runSendLoop(generation: generation)
        }
    }

    private func runSendLoop(generation: UInt64) async {
        defer {
            if isCurrent(generation) {
                sendLoopTask = nil
                startSendLoopIfPossible(generation: generation)
            }
        }

        while isCurrent(generation), !awaitingCommit {
            guard let audio = nextAudioPacket(maximumByteCount: min(
                Self.maximumWireChunkBytes,
                Self.commitSegmentBytes - sentSegmentByteCount
            )) else {
                break
            }

            do {
                try await send(audio: audio, commit: false)
            } catch let error as RealtimeClientError {
                guard isCurrent(generation) else { return }
                fail(error)
                return
            } catch {
                guard isCurrent(generation) else { return }
                fail(.networkFailed)
                return
            }

            guard isCurrent(generation) else { return }
            bufferedAudioByteCount -= audio.count
            sentSegmentByteCount += audio.count

            if sentSegmentByteCount == Self.commitSegmentBytes {
                await sendCommit(generation: generation, isFinal: false)
                return
            }
        }

        guard isCurrent(generation), phase == .finishing, !awaitingCommit else { return }

        if sentSegmentByteCount == 0 {
            completeSuccessfully()
            return
        }

        if sentSegmentByteCount < Self.minimumProcessableSegmentBytes {
            let requiredPadding = Self.minimumProcessableSegmentBytes - sentSegmentByteCount
            guard await sendFinalSilence(byteCount: requiredPadding, generation: generation) else { return }
        }

        guard isCurrent(generation) else { return }
        await sendCommit(generation: generation, isFinal: true)
    }

    private func sendFinalSilence(byteCount: Int, generation: UInt64) async -> Bool {
        var remaining = byteCount
        let fullSilenceChunk = Data(repeating: 0, count: min(remaining, Self.maximumWireChunkBytes))

        while remaining > 0 {
            let chunk: Data
            if remaining >= fullSilenceChunk.count {
                chunk = fullSilenceChunk
            } else {
                chunk = Data(fullSilenceChunk.prefix(remaining))
            }

            do {
                try await send(audio: chunk, commit: false)
            } catch let error as RealtimeClientError {
                guard isCurrent(generation) else { return false }
                fail(error)
                return false
            } catch {
                guard isCurrent(generation) else { return false }
                fail(.networkFailed)
                return false
            }

            guard isCurrent(generation) else { return false }
            sentSegmentByteCount += chunk.count
            remaining -= chunk.count
        }
        return true
    }

    private func sendCommit(generation: UInt64, isFinal: Bool) async {
        guard isCurrent(generation), !awaitingCommit else { return }

        awaitingCommit = true
        awaitedCommitIsFinal = isFinal
        commitSendInFlight = true
        pendingCommitAcknowledgement = false

        do {
            try await send(audio: Data(), commit: true)
        } catch let error as RealtimeClientError {
            guard isCurrent(generation) else { return }
            fail(error)
            return
        } catch {
            guard isCurrent(generation) else { return }
            fail(.networkFailed)
            return
        }

        guard isCurrent(generation) else { return }
        commitSendInFlight = false
        if pendingCommitAcknowledgement {
            acknowledgeCommit(generation: generation)
        } else if awaitingCommit {
            startAcknowledgementTimeout(generation: generation)
        }
    }

    private func nextAudioPacket(maximumByteCount: Int) -> Data? {
        guard maximumByteCount > 0 else { return nil }
        guard let chunk = nextUnsentChunk() else { return nil }

        if chunk.count <= maximumByteCount {
            outboundRemainder = nil
            return chunk
        }

        let packet = Data(chunk.prefix(maximumByteCount))
        outboundRemainder = Data(chunk.dropFirst(maximumByteCount))
        return packet
    }

    private func nextUnsentChunk() -> Data? {
        if let outboundRemainder {
            return outboundRemainder
        }
        guard nextPendingChunkIndex < pendingChunks.count else { return nil }

        let chunk = pendingChunks[nextPendingChunkIndex]
        pendingChunks[nextPendingChunkIndex] = Data()
        nextPendingChunkIndex += 1
        if nextPendingChunkIndex == pendingChunks.count {
            pendingChunks.removeAll(keepingCapacity: true)
            nextPendingChunkIndex = 0
        }
        outboundRemainder = chunk
        return chunk
    }

    private func send(audio: Data, commit: Bool) async throws {
        guard let socket, isActive else { throw RealtimeClientError.cancelled }
        let payload = try Self.makePayload(audio: audio, commit: commit)

        do {
            try await Self.withTimeout(Self.sendTimeout, timeoutError: .sendTimedOut) {
                try await socket.send(.string(payload))
            }
        } catch let error as RealtimeClientError {
            throw error
        } catch is CancellationError {
            throw RealtimeClientError.cancelled
        } catch {
            throw RealtimeClientError.networkFailed
        }
    }

    private func startConnectionTimeout(generation: UInt64) {
        connectionTimeoutTask?.cancel()
        connectionTimeoutTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(for: Self.connectionTimeout)
            } catch {
                return
            }
            guard let self, self.isCurrent(generation), self.phase == .connecting else { return }
            self.fail(.connectionTimedOut)
        }
    }

    private func startAcknowledgementTimeout(generation: UInt64) {
        acknowledgementTimeoutTask?.cancel()
        acknowledgementTimeoutTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(for: Self.acknowledgementTimeout)
            } catch {
                return
            }
            guard let self,
                  self.isCurrent(generation),
                  self.awaitingCommit,
                  !self.commitSendInFlight else { return }
            self.fail(.acknowledgementTimedOut)
        }
    }

    private func transportCompleted(error: Error?, httpStatus: Int?, generation: UInt64) {
        guard isCurrent(generation), isActive else { return }
        guard error != nil || httpStatus != nil else { return }
        fail(Self.transportError(httpStatus: httpStatus))
    }

    private func transportClosed(code: Int, generation: UInt64) {
        guard isCurrent(generation), isActive else { return }
        fail(.connectionClosed(code: code))
    }

    private func completeSuccessfully() {
        guard isActive else { return }
        let text = Self.assemble(stableSegments)
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            fail(.noSpeech)
            return
        }

        phase = .completed
        let result = RealtimeResult(
            text: text,
            language: detectedLanguage ?? requestedLanguage
        )
        outcome = .success(result)
        closeTransport(closeCode: .normalClosure)
        clearAudioBuffers()
        resolveFinishContinuations(with: .success(result))
    }

    private func fail(_ error: RealtimeClientError) {
        guard isActive else { return }

        phase = .failed
        outcome = .failure(error)
        closeTransport(closeCode: .goingAway)
        clearAudioBuffers()
        finishRequested = false
        awaitingCommit = false
        commitSendInFlight = false
        pendingCommitAcknowledgement = false
        awaitedCommitIsFinal = false
        resolveFinishContinuations(with: .failure(error))
        onEvent(.failed(error.localizedDescription))
    }

    private func closeTransport(closeCode: URLSessionWebSocketTask.CloseCode) {
        connectionTimeoutTask?.cancel()
        connectionTimeoutTask = nil
        acknowledgementTimeoutTask?.cancel()
        acknowledgementTimeoutTask = nil
        receiveTask?.cancel()
        receiveTask = nil
        sendLoopTask?.cancel()
        sendLoopTask = nil
        socket?.cancel(with: closeCode, reason: nil)
        socket = nil
        session?.invalidateAndCancel()
        session = nil
        transportDelegate = nil
    }

    private func clearAudioBuffers() {
        pendingChunks.removeAll(keepingCapacity: false)
        nextPendingChunkIndex = 0
        outboundRemainder = nil
        bufferedAudioByteCount = 0
        capturedAudioByteCount = 0
        sentSegmentByteCount = 0
    }

    private func resolveFinishContinuations(with outcome: Result<RealtimeResult, Error>) {
        let continuations = finishContinuations
        finishContinuations.removeAll(keepingCapacity: false)
        for continuation in continuations {
            continuation.resume(with: outcome)
        }
    }

    private func isCurrent(_ generation: UInt64) -> Bool {
        generation == self.generation && isActive
    }

    private static func validate(configuration: RealtimeConfiguration) throws {
        guard configuration.keyterms.count <= 50,
              configuration.keyterms.allSatisfy({ $0.count <= 20 }) else {
            throw RealtimeClientError.invalidConfiguration
        }
    }

    private func makeEndpoint(configuration: RealtimeConfiguration) throws -> URL {
        guard var components = URLComponents(string: endpoint) else {
            throw RealtimeClientError.invalidConfiguration
        }

        var queryItems = [
            URLQueryItem(name: "model_id", value: "scribe_v2_realtime"),
            URLQueryItem(name: "audio_format", value: "pcm_16000"),
            URLQueryItem(name: "commit_strategy", value: "manual"),
            URLQueryItem(name: "include_timestamps", value: "false"),
            URLQueryItem(name: "no_verbatim", value: "false"),
            URLQueryItem(name: "enable_logging", value: configuration.zeroRetention ? "false" : "true")
        ]

        if let language = Self.normalizedLanguage(configuration.language) {
            queryItems.append(URLQueryItem(name: "language_code", value: language))
        }
        for term in configuration.keyterms {
            queryItems.append(URLQueryItem(name: "keyterms", value: term))
        }

        components.queryItems = queryItems
        // Query parsers treat "+" as a space; URLComponents otherwise leaves it literal.
        components.percentEncodedQuery = components.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")
        guard let url = components.url else {
            throw RealtimeClientError.invalidConfiguration
        }
        return url
    }

    private static func normalizedLanguage(_ language: String?) -> String? {
        guard let language else { return nil }
        let normalized = language.trimmingCharacters(in: .whitespacesAndNewlines)
        return normalized.isEmpty ? nil : normalized
    }

    private static func makePayload(audio: Data, commit: Bool) throws -> String {
        let payload = InputAudioChunk(audioBase64: audio.base64EncodedString(), commit: commit)
        let encoded = try JSONEncoder().encode(payload)
        guard let string = String(data: encoded, encoding: .utf8) else {
            throw RealtimeClientError.protocolViolation
        }
        return string
    }

    private static func transportError(httpStatus: Int?) -> RealtimeClientError {
        switch httpStatus ?? 0 {
        case 401, 403:
            return .authenticationFailed
        case 429:
            return .rateLimited
        case 500...599:
            return .providerUnavailable
        default:
            return .networkFailed
        }
    }

    private static func assemble(_ segments: [String]) -> String {
        segments.joined(separator: " ")
    }

    private nonisolated static func withTimeout<T: Sendable>(
        _ timeout: Duration,
        timeoutError: RealtimeClientError,
        operation: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        let box = RealtimeTimeoutBox<T>()
        return try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { continuation in
                box.install(continuation)

                let operationTask = Task {
                    do {
                        box.resolve(
                            .success(try await operation()),
                            cancellingOperation: false,
                            cancellingTimeout: true
                        )
                    } catch {
                        box.resolve(
                            .failure(error),
                            cancellingOperation: false,
                            cancellingTimeout: true
                        )
                    }
                }
                let timeoutTask = Task {
                    do {
                        try await Task.sleep(for: timeout)
                    } catch {
                        return
                    }
                    box.resolve(
                        .failure(timeoutError),
                        cancellingOperation: true,
                        cancellingTimeout: false
                    )
                }
                box.setTasks(operation: operationTask, timeout: timeoutTask)
            }
        }, onCancel: {
            box.resolve(
                .failure(CancellationError()),
                cancellingOperation: true,
                cancellingTimeout: true
            )
        })
    }
}

private extension Duration {
    var secondsAsTimeInterval: TimeInterval {
        let components = self.components
        return Double(components.seconds) + Double(components.attoseconds) / 1e18
    }
}
