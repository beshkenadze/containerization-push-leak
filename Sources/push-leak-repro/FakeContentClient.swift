import ContainerizationExtras
import ContainerizationOCI
import Crypto
import Foundation
import NIOCore

enum Scenario: String, CaseIterable, Sendable {
    case stall
    case fail
    case complete
}

struct SimulatedPushFailure: Error, CustomStringConvertible {
    let digest: String
    var description: String { "simulated push failure for \(digest)" }
}

struct ContentMismatch: Error, CustomStringConvertible {
    let descriptor: Descriptor
    let size: Int64
    let digest: String
    var description: String {
        "pushed content mismatch for \(descriptor.digest): got \(size) bytes \(digest), want \(descriptor.size) bytes"
    }
}

struct Unsupported: Error, CustomStringConvertible {
    let method: String
    var description: String { "FakeContentClient does not implement \(method)" }
}

actor PushTracker {
    private(set) var firstChunk: [Descriptor] = []
    private(set) var verified: [Descriptor] = []
    private var gateOpen = false
    private var gateWaiters: [CheckedContinuation<Void, Never>] = []

    var firstChunkCount: Int { firstChunk.count }

    func sawFirstChunk(_ descriptor: Descriptor) {
        firstChunk.append(descriptor)
    }

    func sawVerified(_ descriptor: Descriptor) {
        verified.append(descriptor)
    }

    func waitAtGate() async {
        guard !gateOpen else { return }
        await withCheckedContinuation { gateWaiters.append($0) }
    }

    func openGate() {
        gateOpen = true
        for waiter in gateWaiters { waiter.resume() }
        gateWaiters.removeAll()
    }
}

final class FakeContentClient: ContentClient {
    let scenario: Scenario
    let tracker: PushTracker

    init(scenario: Scenario, tracker: PushTracker) {
        self.scenario = scenario
        self.tracker = tracker
    }

    func push<T: Sendable & AsyncSequence>(
        name: String,
        ref: String,
        descriptor: Descriptor,
        streamGenerator: () throws -> T,
        progress: ProgressHandler?
    ) async throws where T.Element == ByteBuffer {
        let stream = try streamGenerator()
        var iterator = stream.makeAsyncIterator()
        let first = try await iterator.next()
        await tracker.sawFirstChunk(descriptor)

        switch scenario {
        case .stall:
            await tracker.waitAtGate()
            withExtendedLifetime((stream, iterator, first)) {}
            throw SimulatedPushFailure(digest: descriptor.digest)

        case .fail:
            throw SimulatedPushFailure(digest: descriptor.digest)

        case .complete:
            var hasher = SHA256()
            var size: Int64 = 0
            var next = first
            while let buffer = next {
                size += Int64(buffer.readableBytes)
                buffer.withUnsafeReadableBytes { hasher.update(bufferPointer: $0) }
                next = try await iterator.next()
            }
            let digest = "sha256:" + hasher.finalize().hexString
            guard size == descriptor.size, digest == descriptor.digest else {
                throw ContentMismatch(descriptor: descriptor, size: size, digest: digest)
            }
            await tracker.sawVerified(descriptor)
        }
    }

    func fetch<T: Codable>(name: String, descriptor: Descriptor) async throws -> T {
        throw Unsupported(method: "fetch")
    }

    func fetchBlob(name: String, descriptor: Descriptor, into file: URL, progress: ProgressHandler?) async throws -> (Int64, SHA256Digest) {
        throw Unsupported(method: "fetchBlob")
    }

    func fetchData(name: String, descriptor: Descriptor) async throws -> Data {
        throw Unsupported(method: "fetchData")
    }
}

extension Sequence<UInt8> {
    var hexString: String { map { String(format: "%02x", $0) }.joined() }
}
