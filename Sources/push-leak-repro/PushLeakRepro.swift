import Containerization
import ContainerizationOCI
import Foundation

struct Options {
    static let usage = "usage: push-leak-repro <stall|fail|complete> [--layers N] [--layer-mib S] [--settle-ms MS] [--work-dir DIR]"

    var scenario: Scenario
    var layers = 8
    var layerMiB = 64
    var settleMs = 1000
    var workDir = FileManager.default.temporaryDirectory.appendingPathComponent("push-leak-repro")

    init(_ arguments: [String]) throws {
        guard let first = arguments.first, let scenario = Scenario(rawValue: first) else {
            throw UsageError()
        }
        self.scenario = scenario
        var rest = arguments.dropFirst()
        while let flag = rest.popFirst() {
            guard let value = rest.popFirst() else { throw UsageError() }
            switch flag {
            case "--layers": layers = try Self.positive(value)
            case "--layer-mib": layerMiB = try Self.positive(value)
            case "--settle-ms": settleMs = try Self.positive(value)
            case "--work-dir": workDir = URL(fileURLWithPath: value)
            default: throw UsageError()
            }
        }
    }

    private static func positive(_ value: String) throws -> Int {
        guard let number = Int(value), number > 0 else { throw UsageError() }
        return number
    }
}

struct UsageError: Error, CustomStringConvertible {
    var description: String { Options.usage }
}

struct Measurement: Encodable {
    let event = "measure"
    let scenario: String
    let phase: String
    let physFootprintMiB: Double
    let mallocInUseMiB: Double
    var heldPushes: Int?
    var heldBlobMiB: Double?
    var releasedMiB: Double?

    init(_ scenario: Scenario, _ phase: String, _ sample: MemorySample) {
        self.scenario = scenario.rawValue
        self.phase = phase
        self.physFootprintMiB = mib(sample.physFootprint)
        self.mallocInUseMiB = mib(sample.mallocInUse)
    }
}

struct Summary: Encodable {
    let event = "summary"
    let scenario: String
    let layers: Int
    let layerMiB: Int
    let imageReused: Bool
    let baselineMiB: Double
    let peakMiB: Double
    let afterMiB: Double
    let afterReliefMiB: Double
    let peakDeltaMiB: Double
    let afterDeltaMiB: Double
    let lifetimePeakMiB: Double
    let mallocInUseBaselineMiB: Double
    let mallocInUseAfterMiB: Double
    let firstChunkPushes: Int
    let firstChunkBlobMiB: Double
    let verifiedBlobs: Int
    let exportOutcome: String
}

func emit(_ value: some Encodable) {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    let line = (try? encoder.encode(value)).map { String(decoding: $0, as: UTF8.self) } ?? #"{"event":"error","message":"encode failed"}"#
    print(line)
    fflush(stdout)
}

func startPeakSampler() -> Task<UInt64, Never> {
    Task {
        var peak: UInt64 = 0
        while !Task.isCancelled {
            peak = max(peak, MemorySample.now().physFootprint)
            try? await Task.sleep(for: .milliseconds(2))
        }
        return max(peak, MemorySample.now().physFootprint)
    }
}

@main
struct PushLeakRepro {
    static let exportConcurrency = 8

    static func main() async {
        do {
            try await run(Options(Array(CommandLine.arguments.dropFirst())))
        } catch {
            FileHandle.standardError.write(Data("error: \(error)\n".utf8))
            exit(error is UsageError ? 64 : 1)
        }
    }

    static func run(_ options: Options) async throws {
        let scenario = options.scenario
        let image = try await SyntheticImage.prepare(workDir: options.workDir, layers: options.layers, layerMiB: options.layerMiB)

        let baseline = MemorySample.now()
        emit(Measurement(scenario, "baseline", baseline))

        let tracker = PushTracker()
        let operation = ImageStore.ExportOperation(
            name: "repro/push-leak",
            tag: "latest",
            contentStore: image.store,
            client: FakeContentClient(scenario: scenario, tracker: tracker)
        )

        let sampler = startPeakSampler()
        let index = image.index
        let export = Task { try await operation.export(index: index, platforms: { _ in true }) }

        var stalledFootprint: UInt64 = 0
        if scenario == .stall {
            let expected = min(options.layers + 1, exportConcurrency)
            let deadline = ContinuousClock.now + .seconds(30)
            while await tracker.firstChunkCount < expected, ContinuousClock.now < deadline {
                try await Task.sleep(for: .milliseconds(5))
            }
            let stalled = MemorySample.now()
            stalledFootprint = stalled.physFootprint
            let held = await tracker.firstChunk
            var measurement = Measurement(scenario, "stalled", stalled)
            measurement.heldPushes = held.count
            measurement.heldBlobMiB = mib(held.reduce(0) { $0 + $1.size })
            emit(measurement)
            await tracker.openGate()
        }

        let result = await export.result
        let outcome: String
        switch result {
        case .success(let descriptor): outcome = "ok \(descriptor.digest)"
        case .failure(let error): outcome = "threw: \(error)"
        }
        sampler.cancel()
        let peak = max(await sampler.value, stalledFootprint)

        try await Task.sleep(for: .milliseconds(options.settleMs))
        let after = MemorySample.now()
        emit(Measurement(scenario, "after", after))

        let released = relieveMallocPressure()
        let afterRelief = MemorySample.now()
        var reliefMeasurement = Measurement(scenario, "afterRelief", afterRelief)
        reliefMeasurement.releasedMiB = mib(released)
        emit(reliefMeasurement)

        let firstChunk = await tracker.firstChunk
        emit(
            Summary(
                scenario: scenario.rawValue,
                layers: options.layers,
                layerMiB: options.layerMiB,
                imageReused: image.reused,
                baselineMiB: mib(baseline.physFootprint),
                peakMiB: mib(peak),
                afterMiB: mib(after.physFootprint),
                afterReliefMiB: mib(afterRelief.physFootprint),
                peakDeltaMiB: mibDelta(peak, from: baseline.physFootprint),
                afterDeltaMiB: mibDelta(after.physFootprint, from: baseline.physFootprint),
                lifetimePeakMiB: mib(after.lifetimePeak),
                mallocInUseBaselineMiB: mib(baseline.mallocInUse),
                mallocInUseAfterMiB: mib(after.mallocInUse),
                firstChunkPushes: firstChunk.count,
                firstChunkBlobMiB: mib(firstChunk.reduce(0) { $0 + $1.size }),
                verifiedBlobs: await tracker.verified.count,
                exportOutcome: outcome
            )
        )

        if scenario == .complete, case .failure = result {
            exit(1)
        }
    }
}
