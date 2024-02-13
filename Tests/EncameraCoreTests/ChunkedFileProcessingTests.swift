// ChunkedTests.swift
// EncameraTests

import XCTest
import Combine
@testable import EncameraCore

class ChunkedTests: XCTestCase {

    private var cancellables: Set<AnyCancellable> = []

    // Dummy types conforming to MediaDescribing for testing purposes
    struct DummyMedia: MediaDescribing {
        var source: URL
        var mediaType: MediaType = .video
        var needsDownload: Bool = false
        var id: String = UUID().uuidString

        init?(source: URL) {
            self.source = source
        }

        init(source: URL, mediaType: MediaType, id: String) {
            self.source = source
            self.mediaType = mediaType
            self.id = id
        }
    }

    func testChunkedFilesProcessing() throws {
        let expectation = XCTestExpectation(description: "Chunked processing completes")

        // Prepare a dummy file
        let dummyData = Data(repeating: 0xFF, count: 1024) // 1KB of dummy data
        let tempFileURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try dummyData.write(to: tempFileURL)

        let media = DummyMedia(source: tempFileURL)!
        let fileHandler = try FileLikeHandler(media: media, mode: .reading)

        let publisher = ChunkedFileProcessingPublisher(sourceFileHandle: fileHandler, blockSize: 256)

        publisher
            .sink(receiveCompletion: { completion in
                switch completion {
                case .finished:
                    expectation.fulfill()
                case .failure(let error):
                    XCTFail("Failed with error: \(error)")
                }
            }, receiveValue: { (chunk, progress, isFinal) in
                // Add your assertions here to validate the chunks, progress, and final flag
                XCTAssertTrue(chunk.count <= 256, "Chunk size exceeds blockSize")
            })
            .store(in: &cancellables)

        wait(for: [expectation], timeout: 5.0)

        // Cleanup
        try FileManager.default.removeItem(at: tempFileURL)
    }
}
