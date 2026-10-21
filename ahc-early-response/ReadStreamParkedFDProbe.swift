import Darwin
import Foundation
import Logging
import NIOConcurrencyHelpers
import NIOCore
import NIOHTTP1
import NIOPosix
import Synchronization
import XCTest

@testable import AsyncHTTPClient

extension BinaryInteger {
    private func toUnsignedMemoryAmount(_ amount: UInt64) -> UInt64 {
        guard self >= 0 else {
            fatalError("encountered negative number during conversion to memory amount")
        }
        let val = UInt64(self)
        let (newVal, overflow) = val.multipliedReportingOverflow(by: amount)
        guard !overflow else {
            fatalError("UInt64 overflow when converting to memory amount")
        }
        return newVal
    }

    public func mib() -> UInt64 {
        self.toUnsignedMemoryAmount(1 << 20)
    }
}

/// `ReadStream` is a utility type for streaming data from a `URL`
/// or `Data` blob.
@available(macOS 15.0, *)
public class ReadStream {
    public static let bufferSize = Int(1.mib())

    private var reader: Reader?
    private weak var issued: Reader?
    private let buffSize: Int
    private let data: Data?
    private let url: URL?

    public init() {
        reader = Reader(InputStream(data: .init()), bufferSize: Self.bufferSize)
        buffSize = Self.bufferSize
        self.data = Data()
        self.url = nil
    }

    public init(url: URL, bufferSize: Int = bufferSize) throws {
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw Error.noSuchFileOrDirectory(url)
        }
        guard let stream = InputStream(url: url) else {
            throw Error.failedToCreateStream
        }
        self.reader = Reader(stream, bufferSize: bufferSize)
        self.buffSize = bufferSize
        self.url = url
        self.data = nil
    }

    public init(data: Data, bufferSize: Int = bufferSize) {
        self.reader = Reader(InputStream(data: data), bufferSize: bufferSize)
        self.buffSize = bufferSize
        self.url = nil
        self.data = data
    }

    /// Resets the read stream. This either reassigns
    /// the data buffer or url to a new InputStream internally.
    public func reset() throws {
        issued?.close()
        if let url = self.url {
            guard let s = InputStream(url: url) else {
                throw Error.failedToCreateStream
            }
            self.reader = Reader(s, bufferSize: buffSize)
            return
        }
        let data = self.data ?? Data()
        self.reader = Reader(InputStream(data: data), bufferSize: buffSize)
    }

    /// Get access to an `AsyncStream` of `ByteBuffer`'s from the input source.
    public var stream: AsyncStream<ByteBuffer> {
        let reader = takeReader()
        return AsyncStream(unfolding: { reader?.next().map { ByteBuffer(bytes: $0) } })
    }

    /// Get access to an `AsyncStream` of `Data` objects from the input source.
    public var dataStream: AsyncStream<Data> {
        let reader = takeReader()
        return AsyncStream(unfolding: { reader?.next().map { Data($0) } })
    }

    private func takeReader() -> Reader? {
        guard let reader = self.reader.take() else {
            return nil
        }
        issued = reader
        return reader
    }
}

@available(macOS 15.0, *)
private final class Reader: Sendable {
    private let input: Mutex<InputStream?>
    private let bufferSize: Int

    init(_ input: sending InputStream, bufferSize: Int) {
        self.input = Mutex(input)
        self.bufferSize = bufferSize
    }

    deinit {
        close()
    }

    func close() {
        input.withLock { input in
            input?.close()
            input = nil
        }
    }

    func next() -> ArraySlice<UInt8>? {
        input.withLock { input in
            guard let stream = input else {
                return nil
            }
            if stream.streamStatus == .notOpen {
                stream.open()
            }
            var chunk = [UInt8](repeating: 0, count: bufferSize)
            let count = stream.read(&chunk, maxLength: bufferSize)
            guard count > 0 else {
                stream.close()
                input = nil
                return nil
            }
            return chunk[..<count]
        }
    }
}

@available(macOS 15.0, *)
extension ReadStream {
    /// Errors that can be encountered while using a `ReadStream`.
    public enum Error: Swift.Error, CustomStringConvertible {
        case failedToCreateStream
        case noSuchFileOrDirectory(_ p: URL)

        public var description: String {
            switch self {
            case .failedToCreateStream:
                return "failed to create stream"
            case .noSuchFileOrDirectory(let p):
                return "no such file or directory: \(p.path)"
            }
        }
    }
}

private final class Probe: @unchecked Sendable {
    let pulled = NIOLockedValueBox(0)
    let iteratorReleased = NIOLockedValueBox(false)
}

private final class IteratorBox: @unchecked Sendable {
    var base: AsyncStream<ByteBuffer>.Iterator
    let probe: Probe
    init(_ base: AsyncStream<ByteBuffer>.Iterator, _ probe: Probe) {
        self.base = base
        self.probe = probe
    }
    deinit { probe.iteratorReleased.withLockedValue { $0 = true } }
}

private struct TrackedSequence: AsyncSequence, Sendable {
    typealias Element = ByteBuffer
    let base: AsyncStream<ByteBuffer>
    let probe: Probe

    struct AsyncIterator: AsyncIteratorProtocol {
        let box: IteratorBox
        mutating func next() async -> ByteBuffer? {
            let value = await box.base.next()
            if value != nil { box.probe.pulled.withLockedValue { $0 += 1 } }
            return value
        }
    }

    func makeAsyncIterator() -> AsyncIterator { AsyncIterator(box: IteratorBox(base.makeAsyncIterator(), probe)) }
}

private func mallocInUse() -> Int {
    var stats = malloc_statistics_t()
    malloc_zone_statistics(nil, &stats)
    return stats.size_in_use
}

private func openFDs(_ url: URL) -> Int {
    var st = stat()
    guard stat(url.path, &st) == 0 else { return -1 }
    return (try! FileManager.default.contentsOfDirectory(atPath: "/dev/fd")).compactMap { Int32($0) }.filter { fd in
        var o = stat()
        return fstat(fd, &o) == 0 && o.st_dev == st.st_dev && o.st_ino == st.st_ino
    }.count
}

@available(macOS 15.0, *)
final class ReadStreamParkedFDProbe: XCTestCase {
    private static let size = 64 << 20

    private struct Outcome {
        var pulled = 0
        var fdsParked = 0
        var retainedParked = 0
        var fdsAfterRetryBody = 0
        var parkedAfterRetryBody = false
        var retainedAfterRetryBody = 0
        var fdsDuringRetry = -1
        var retryBytes = 0
        var fdsAfterRetryDrained = 0
        var parkedAfterRetryDrained = false
        var pulledAfterRetryDrained = 0
        var fdsAfterCancel = 0
        var releasedAfterCancel = false
    }

    private func run(reset: Bool, label: String) async throws -> Outcome {
        let size = Self.size
        let file = URL(fileURLWithPath: ProcessInfo.processInfo.environment["TMPDIR"]!)
            .appendingPathComponent("parked-blob-\(getpid())-\(label)")
        try Data(count: size).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }

        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        let loop = group.next()
        let readStream = try ReadStream(url: file, bufferSize: Int(1.mib()))
        let probe = Probe()
        var outcome = Outcome()
        let baseline = mallocInUse()

        let preparedBox = NIOLockedValueBox<HTTPClientRequest.Prepared?>(
            try {
                var request = HTTPClientRequest(url: "https://localhost/v2/x/blobs/uploads/u?digest=sha256:0")
                request.method = .PUT
                request.body = .stream(
                    TrackedSequence(base: readStream.stream, probe: probe),
                    length: .known(Int64(size))
                )
                return try HTTPClientRequest.Prepared(request)
            }()
        )

        let box = NIOLockedValueBox<Transaction?>(nil)
        let ready = ConditionLock(value: false)
        var responseTask: Task<HTTPClientResponse, Error>? = Task {
            try await withCheckedThrowingContinuation {
                (continuation: CheckedContinuation<HTTPClientResponse, Error>) in
                box.withLockedValue {
                    $0 = Transaction(
                        request: preparedBox.withLockedValue { $0! },
                        requestOptions: .forTests(),
                        logger: Logger(label: "test"),
                        connectionDeadline: .distantFuture,
                        preferredEventLoop: loop,
                        responseContinuation: continuation
                    )
                }
                ready.lock()
                ready.unlock(withValue: true)
            }
        }
        ready.lock(whenValue: true)
        ready.unlock()
        preparedBox.withLockedValue { $0 = nil }
        var transaction: Transaction! = box.withLockedValue { $0! }

        var executor: MockRequestExecutor! = MockRequestExecutor(
            pauseRequestBodyPartStreamAfterASingleWrite: true,
            eventLoop: loop
        )
        executor.runRequest(transaction)
        executor.resumeRequestBodyStream()
        try executor.receiveRequestBody { _ in }
        try executor.receiveRequestBody { _ in }

        try await loop.submit {
            transaction.receiveResponseHead(HTTPResponseHead(version: .http2, status: .unauthorized))
            transaction.receiveResponseEnd(nil, trailers: nil)
        }.get()
        var response: HTTPClientResponse? = try await responseTask!.value
        responseTask = nil
        XCTAssertEqual(response?.status, .unauthorized)
        response = nil
        box.withLockedValue { $0 = nil }

        try await Task.sleep(for: .milliseconds(1000))
        outcome.pulled = probe.pulled.withLockedValue { $0 }
        outcome.fdsParked = openFDs(file)
        outcome.retainedParked = mallocInUse() - baseline

        if reset { try readStream.reset() }
        let retryBody = readStream.stream
        try await Task.sleep(for: .milliseconds(500))
        outcome.fdsAfterRetryBody = openFDs(file)
        outcome.parkedAfterRetryBody = !probe.iteratorReleased.withLockedValue { $0 }
        outcome.retainedAfterRetryBody = mallocInUse() - baseline

        var iterator = retryBody.makeAsyncIterator()
        while let chunk = await iterator.next() {
            if outcome.retryBytes == 0 { outcome.fdsDuringRetry = openFDs(file) }
            outcome.retryBytes += chunk.readableBytes
        }
        outcome.fdsAfterRetryDrained = openFDs(file)
        outcome.parkedAfterRetryDrained = !probe.iteratorReleased.withLockedValue { $0 }
        outcome.pulledAfterRetryDrained = probe.pulled.withLockedValue { $0 }

        transaction.cancel()
        transaction = nil
        executor = nil
        try await Task.sleep(for: .milliseconds(500))
        outcome.fdsAfterCancel = openFDs(file)
        outcome.releasedAfterCancel = probe.iteratorReleased.withLockedValue { $0 }
        try await group.shutdownGracefully()

        print(
            """
            \(label): attempt1 pulled=\(outcome.pulled)/\(size >> 20) chunks; \
            PARKED: openFDs=\(outcome.fdsParked) retainedKiB=\(outcome.retainedParked >> 10)
            \(label): AFTER-RETRY-BODY (reset=\(reset)): openFDs=\(outcome.fdsAfterRetryBody) \
            pumpStillParked=\(outcome.parkedAfterRetryBody) retainedKiB=\(outcome.retainedAfterRetryBody >> 10)
            \(label): RETRY-READ: openFDsDuringRetry=\(outcome.fdsDuringRetry) retryBytes=\(outcome.retryBytes) \
            openFDsAfterRetry=\(outcome.fdsAfterRetryDrained) pumpStillParked=\(outcome.parkedAfterRetryDrained) \
            attempt1Pulled=\(outcome.pulledAfterRetryDrained)
            \(label): AFTER-CANCEL: openFDs=\(outcome.fdsAfterCancel) iteratorReleased=\(outcome.releasedAfterCancel)
            """
        )
        return outcome
    }

    func testA_ResetClosesParkedReader() async throws {
        let o = try await run(reset: true, label: "A")
        XCTAssertEqual(o.fdsParked, 1)
        XCTAssertEqual(o.fdsAfterRetryBody, 0, "reset() should close the parked attempt's file")
        XCTAssertTrue(o.parkedAfterRetryBody)
        XCTAssertEqual(o.retryBytes, Self.size)
        XCTAssertEqual(o.fdsAfterRetryDrained, 0)
        XCTAssertTrue(o.releasedAfterCancel)
    }

    func testB_NoResetKeepsParkedReaderOpen() async throws {
        let o = try await run(reset: false, label: "B")
        XCTAssertEqual(o.fdsParked, 1)
        XCTAssertEqual(o.fdsAfterRetryBody, 1, "without reset() the parked pump keeps the file open")
        XCTAssertTrue(o.parkedAfterRetryBody)
        XCTAssertEqual(o.fdsAfterCancel, 0)
        XCTAssertTrue(o.releasedAfterCancel)
    }
}
