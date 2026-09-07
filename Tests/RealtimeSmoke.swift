import Foundation

import Darwin

@MainActor
final class EventRecorder {
    var ready = false
    var partials: [String] = []
    var committed: [String] = []
    var errors: [String] = []
    var count = 0
    func record(_ event: RealtimeEvent) {
        count += 1
        switch event {
        case .ready: ready = true
        case .partial(let text): partials.append(text)
        case .committed(let text): committed.append(text)
        case .failed(let error): errors.append(error)
        }
    }
}

@main
@MainActor
struct NetworkSmoke {
    static func check(_ condition: Bool, _ message: String) {
        if !condition { print("FAIL \(message)"); exit(1) }
    }
    static func cpuTime() -> Double {
        var usage = rusage()
        getrusage(RUSAGE_SELF, &usage)
        return Double(usage.ru_utime.tv_sec + usage.ru_stime.tv_sec) + Double(usage.ru_utime.tv_usec + usage.ru_stime.tv_usec) / 1e6
    }
    static func main() async throws {
        let scenario = CommandLine.arguments[1]
        let recorder = EventRecorder()
        let client = RealtimeClient(endpoint: CommandLine.arguments[2], onEvent: recorder.record)
        if scenario == "invalidHints" {
            client.connect(apiKey: scenario, configuration: RealtimeConfiguration(keyterms: [String(repeating: "x", count: 21)]))
            do { _ = try await client.finish(); check(false, "invalid hints succeeded") }
            catch RealtimeClientError.invalidConfiguration { print("PASS hint limit rejected before opening socket") }
            return
        }
        let configuration = scenario == "vocabulary"
            ? RealtimeConfiguration(keyterms: ["Kinekt", "Oh My Pi", "één & twee + drie"])
            : RealtimeConfiguration()
        client.connect(apiKey: scenario, configuration: configuration)
        defer { client.cancel() }
        if scenario == "idle" {
            try await Task.sleep(for: .milliseconds(200))
            check(recorder.ready, "idle connection not ready")
            let before = cpuTime()
            try await Task.sleep(for: .milliseconds(500))
            let consumed = cpuTime() - before
            check(consumed < 0.10, "idle sender consumed \(consumed)s CPU in 0.5s wall time")
            print("PASS ready connection waits without busy spinning (\(consumed)s CPU)")
            return
        }
        if scenario == "overflow" {
            do {
                try client.enqueue(Data(repeating: 1, count: 320_002))
                check(false, "oversized buffer accepted")
            } catch RealtimeClientError.audioBufferFull { print("PASS bounded startup audio rejects overflow") }
            return
        }
        if scenario != "zero" { try client.enqueue(Data(repeating: 0x11, count: 3_200)) }
        if scenario == "long" || scenario == "exactCommit" {
            for _ in 1..<(scenario == "long" ? 490 : 240) {
                try await Task.sleep(for: .milliseconds(5))
                try client.enqueue(Data(repeating: 0x11, count: 3_200))
            }
        }
        let finishing = Task { try await client.finish() }
        if scenario == "cancelConnecting" || scenario == "cancelAck" {
            try await Task.sleep(for: .milliseconds(scenario == "cancelConnecting" ? 10 : 200))
            client.cancel()
            let callbacks = recorder.count
            do { _ = try await finishing.value; check(false, "canceled finish succeeded") }
            catch RealtimeClientError.cancelled { }
            try await Task.sleep(for: .milliseconds(650))
            check(recorder.count == callbacks, "callbacks after cancellation")
            print("PASS \(scenario): finish resumed and late events ignored")
            return
        }
        do {
            let result = try await finishing.value
            check(!["zero", "emptyText", "quota", "noAck", "connectTimeout", "http401", "http403", "http429", "disconnect", "errorClose", "policyClose"].contains(scenario), "\(scenario) unexpectedly succeeded")
            if scenario == "long" {
                check(result.text == "Repeat. Repeat. Tail.", "long segments truncated/duplicated")
                check(recorder.committed.count == 3, "duplicate timestamped commit included")
            } else {
                check(result.text == "Synthetic result.", "unexpected short result")
            }
            if scenario == "partial" {
                check(recorder.partials == ["Initial hypothesis.", "Revised hypothesis.", ""],
                      "partial hypotheses were not delivered as revisions")
                check(recorder.committed == ["Synthetic result."],
                      "partial hypotheses changed the finalized result")
            }
            print("PASS \(scenario): committed output with duplicate variants ignored")
        } catch let error as RealtimeClientError {
            let expected: Bool
            switch (scenario, error) {
            case ("zero", .noSpeech), ("emptyText", .noSpeech), ("quota", .quotaExceeded),
                 ("noAck", .acknowledgementTimedOut), ("connectTimeout", .connectionTimedOut),
                 ("http401", .authenticationFailed), ("http403", .authenticationFailed), ("http429", .rateLimited): expected = true
            case ("disconnect", .connectionClosed), ("disconnect", .networkFailed): expected = true
            case ("errorClose", .termsNotAccepted): expected = true
            case ("policyClose", .connectionClosed(code: 1008)): expected = true
            default: expected = false
            }
            check(expected, "\(scenario) wrong error \(error)")
            check(!recorder.errors.joined().contains("synthetic"), "provider details leaked")
            print("PASS \(scenario): sanitized \(error)")
        }
    }
}
