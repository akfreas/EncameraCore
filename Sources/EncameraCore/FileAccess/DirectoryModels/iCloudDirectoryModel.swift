import Foundation
import Combine

public enum iCloudDownloadStatus {
    case notDownloaded
    case downloading(progress: Double)
    case downloaded
    case cancelled
}

public class iCloudStorageModel: DataStorageModel {
    public static var rootURL: URL {
        guard let driveURL = FileManager.default
            .url(forUbiquityContainerIdentifier: nil)?.appendingPathComponent("Documents") else {
            fatalError("Could not get drive url")
        }
        return driveURL
    }

    public var storageType: StorageType {
        .icloud
    }

    public let album: Album

    required public init(album: Album) {
        self.album = album
    }

    private var localCancellables = Set<AnyCancellable>()
    private var downloadStatusSubjects = [URL: PassthroughSubject<iCloudDownloadStatus, Never>]()
    private var downloadTasks = [URL: AnyCancellable]()

    public var baseURL: URL {
        return iCloudStorageModel.rootURL.appendingPathComponent(album.encryptedPathComponent)
    }

    public func triggerDownloadOfAllFilesFromiCloud() {
        enumeratorForStorageDirectory().forEach({
            try? FileManager.default.startDownloadingUbiquitousItem(at: $0)
        })
    }

    public func triggerDownload(ofFile file: EncryptedMedia) {
        guard case .url(let source) = file.source else {
            return
        }
        try? FileManager.default.startDownloadingUbiquitousItem(at: source)
    }

    public func resolveDownloadedMedia<T: MediaDescribing>(media: T) throws -> T?  {
        guard let source = media.downloadedSource else {
            return nil
        }
        if FileManager.default.fileExists(atPath: source.path) {
            return T(source: .url(source), generateID: false)
        } else {
            throw DataStorageModelError.couldNotCreateMedia
        }
    }

    public func checkDownloadStatus<T: MediaDescribing>(ofFile file: T) -> AnyPublisher<iCloudDownloadStatus, Never> {
        guard case .url(let source) = file.source else {
            return Empty().eraseToAnyPublisher()
        }

        if let subject = downloadStatusSubjects[source] {
            return subject.eraseToAnyPublisher()
        } else {
            let subject = PassthroughSubject<iCloudDownloadStatus, Never>()
            downloadStatusSubjects[source] = subject
            Task { @MainActor in
                monitorDownloadProgress(for: source, subject: subject)
            }
            return subject.eraseToAnyPublisher()
        }
    }

    @MainActor
    private func monitorDownloadProgress(for fileURL: URL, subject: PassthroughSubject<iCloudDownloadStatus, Never>) {
        let query = NSMetadataQuery()
        query.predicate = NSPredicate(format: "%K == %@", NSMetadataItemURLKey, fileURL as CVarArg)
        query.searchScopes = [NSMetadataQueryUbiquitousDocumentsScope]
        query.valueListAttributes = [
            NSMetadataUbiquitousItemPercentDownloadedKey,
            NSMetadataUbiquitousItemDownloadingStatusKey
        ]

        var observer: NSObjectProtocol?
        observer = NotificationCenter.default.addObserver(forName: .NSMetadataQueryDidUpdate, object: query, queue: .main) { [weak self] notification in
            guard let items = notification.userInfo?[NSMetadataQueryUpdateChangedItemsKey] as? NSArray,
                  let item = items.firstObject as? NSMetadataItem else {
                return
            }

            func terminateObserver() {
                query.stop()
                if let observer = observer {
                    NotificationCenter.default.removeObserver(observer)
                }
                self?.downloadStatusSubjects.removeValue(forKey: fileURL)
            }

            if let downloadingStatus = item.value(forAttribute: NSMetadataUbiquitousItemDownloadingStatusKey) as? String {
                switch downloadingStatus {
                case NSMetadataUbiquitousItemDownloadingStatusDownloaded:
                    subject.send(.downloaded)
                    subject.send(completion: .finished)
                    terminateObserver()
                default:
                    if let progress = item.value(forAttribute: NSMetadataUbiquitousItemPercentDownloadedKey) as? Double {
                        let percent = progress / 100.0
                        if percent < 1 {
                            subject.send(.downloading(progress: percent))
                        } else if percent == 1 {
                            subject.send(.downloaded)
                        }
                    } else {
                        subject.send(.notDownloaded)
                    }
                }
            }
        }

        query.start()
    }

    public func downloadFileFromiCloud<T: MediaDescribing>(media: T, progress: @escaping (Double) -> Void) async throws -> T {
        guard media.needsDownload, case .url(let source) = media.source else {
            return media
        }

        try FileManager.default.startDownloadingUbiquitousItem(at: source)

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                self.checkDownloadStatus(ofFile: media)
                    .sink { status in
                        switch status {
                        case .notDownloaded:
                            progress(0)
                        case .downloading(let progressValue):
                            progress(progressValue)
                        case .downloaded:
                            progress(1)
                            do {
                                if let resolved = try self.resolveDownloadedMedia(media: media) {
                                    continuation.resume(returning: resolved)
                                    self.localCancellables.forEach({ $0.cancel() })
                                    self.localCancellables.removeAll()
                                }
                            } catch {
                                continuation.resume(throwing: error)
                            }
                        case .cancelled:
                            break
                        }
                    }
                    .store(in: &self.localCancellables)
            }
        } onCancel: {
            self.localCancellables.forEach({ $0.cancel() })
            self.localCancellables.removeAll()
        }
    }


    public func cancelDownload(for url: URL) {
        downloadTasks[url]?.cancel()
        downloadTasks.removeValue(forKey: url)
        downloadStatusSubjects[url]?.send(.cancelled)
        downloadStatusSubjects[url]?.send(completion: .finished)
    }
}
