import Foundation

class DiskBlockReader: FileLikeBlockReader {

    var source: URL
    private var fileHandle: FileHandle?
    private var mode: BlockIOMode

    var size: UInt64 {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: source.path) else {
            return 0
        }
        return attributes[FileAttributeKey.size] as? UInt64 ?? .zero
    }

    init(source: URL, mode: BlockIOMode) throws {
        self.source = source
        self.mode = mode
        switch mode {
        case .reading:
            fileHandle = try FileHandle(forReadingFrom: source)
        case .writing:
            fileHandle = try? FileHandle(forWritingTo: source)
        }
    }

    func read(upToCount count: Int) throws -> Data? {
        guard let fileHandle = fileHandle else {
            throw NSError(domain: "DiskBlockReader", code: 1, userInfo: [NSLocalizedDescriptionKey: "File handle is nil."])
        }

        let currentPosition = try fileHandle.offset()
        let remaining = size - currentPosition
        if remaining < 20000 {
            print("Nearing end")
        }
        if remaining == 0 {
            return nil // End of file reached.
        }

        let actualReadCount = min(Int(remaining), count)
        let data = try fileHandle.read(upToCount: actualReadCount)

        print("Source: \(source.lastPathComponent), position: \(currentPosition), chunk size: \(count), length: \(size), remaining: \(remaining - UInt64(actualReadCount)), read: \(data?.count)")

        return data
    }

    func closeReader() throws {
        try fileHandle?.close()
    }

    func prepareIfDoesNotExist() throws {
        guard mode == .writing else {
            return
        }

        // Create directory if it doesn't exist
        let directoryURL = source.deletingLastPathComponent()
        if !FileManager.default.fileExists(atPath: directoryURL.path) {
            try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true, attributes: nil)
        }

        // Create file if it doesn't exist
        if FileManager.default.fileExists(atPath: source.path) == false {
            FileManager.default.createFile(atPath: source.path, contents: nil)
        }
        fileHandle = try FileHandle(forWritingTo: source)
    }

    func write(contentsOf data: Data) throws {
        try fileHandle?.write(contentsOf: data)
    }
}
