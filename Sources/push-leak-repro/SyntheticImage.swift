import ContainerizationOCI
import Crypto
import Foundation

struct SyntheticImage {
    let store: LocalContentStore
    let index: Descriptor
    let reused: Bool

    static func prepare(workDir: URL, layers: Int, layerMiB: Int) async throws -> SyntheticImage {
        let root = workDir.appendingPathComponent("\(layers)x\(layerMiB)MiB")
        let indexFile = root.appendingPathComponent("index-descriptor.json")
        let store = try LocalContentStore(path: root.appendingPathComponent("store"))

        if let data = try? Data(contentsOf: indexFile) {
            let index = try JSONDecoder().decode(Descriptor.self, from: data)
            if try await store.get(digest: index.digest) != nil {
                return SyntheticImage(store: store, index: index, reused: true)
            }
        }

        let (session, dir) = try await store.newIngestSession()
        do {
            var layerDescriptors: [Descriptor] = []
            for _ in 0..<layers {
                let (digest, size) = try writeRandomBlob(in: dir, bytes: layerMiB << 20)
                layerDescriptors.append(Descriptor(mediaType: MediaTypes.imageLayerGzip, digest: digest, size: size))
            }

            let config = Data(#"{"architecture":"arm64","os":"linux","rootfs":{"type":"layers","diff_ids":[]}}"#.utf8)
            let configDescriptor = try writeBlob(config, mediaType: MediaTypes.imageConfig, in: dir)

            let manifest = Manifest(config: configDescriptor, layers: layerDescriptors)
            var manifestDescriptor = try writeBlob(JSONEncoder().encode(manifest), mediaType: MediaTypes.imageManifest, in: dir)
            manifestDescriptor.platform = Platform(arch: "arm64", os: "linux")

            let index = try writeBlob(JSONEncoder().encode(Index(manifests: [manifestDescriptor])), mediaType: MediaTypes.index, in: dir)
            try await store.completeIngestSession(session)
            try JSONEncoder().encode(index).write(to: indexFile)
            return SyntheticImage(store: store, index: index, reused: false)
        } catch {
            try? await store.cancelIngestSession(session)
            throw error
        }
    }

    private static func writeRandomBlob(in dir: URL, bytes: Int) throws -> (digest: String, size: Int64) {
        let partial = dir.appendingPathComponent(UUID().uuidString)
        guard FileManager.default.createFile(atPath: partial.path, contents: nil) else {
            throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: partial.path])
        }
        let handle = try FileHandle(forWritingTo: partial)
        var hasher = SHA256()
        var chunk = Data(count: 1 << 20)
        var remaining = bytes
        while remaining > 0 {
            let count = min(remaining, chunk.count)
            if count < chunk.count { chunk = Data(count: count) }
            chunk.withUnsafeMutableBytes { arc4random_buf($0.baseAddress, count) }
            hasher.update(data: chunk)
            try handle.write(contentsOf: chunk)
            remaining -= count
        }
        try handle.close()

        let hex = hasher.finalize().hexString
        try FileManager.default.moveItem(at: partial, to: dir.appendingPathComponent(hex))
        return ("sha256:" + hex, Int64(bytes))
    }

    private static func writeBlob(_ data: Data, mediaType: String, in dir: URL) throws -> Descriptor {
        let hex = SHA256.hash(data: data).hexString
        try data.write(to: dir.appendingPathComponent(hex))
        return Descriptor(mediaType: mediaType, digest: "sha256:" + hex, size: Int64(data.count))
    }
}
