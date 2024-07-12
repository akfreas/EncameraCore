//
//  iCloudDirectoryModel.swift
//  Encamera
//
//  Created by Alexander Freas on 05.08.22.
//

import Foundation
import Combine

public enum iCloudDownloadStatus {
    case notDownloaded
    case downloading(progress: Double)
    case downloaded
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
    public var baseURL: URL {
        
        let destURL = iCloudStorageModel.rootURL.appendingPathComponent(album.name)
        return destURL
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
            if let downloaded = T(source: .url(source)) {
                return downloaded
            } else {
                throw DataStorageModelError.couldNotCreateMedia
            }
        } else {
            return nil
        }
    }
    
    
    func downloadFileFromiCloud<T: MediaDescribing>(media: T, progress: @escaping (Double) -> Void) async throws -> T  {
        guard media.needsDownload == true, case .url(let source) = media.source else {
            return media
        }
        try FileManager.default.startDownloadingUbiquitousItem(at: source)
        return try await withCheckedThrowingContinuation { [weak self] continuation in

            guard let self else {
                return
            }

            self.checkDownloadStatus(ofFile: media)
                .sink { status in
                    switch status {
                    case .notDownloaded:
                        progress(0)
                    case .downloading(let progressNumber):
                        debugPrint("Download Progress: \(progressNumber)")
                        progress(progressNumber)
                    case .downloaded:
                        progress(1)
                        do {
                            if let downloaded = try self.resolveDownloadedMedia(media: media) {
                                continuation.resume(returning: downloaded)
                            }
                        } catch {
                            debugPrint("Could not resolve downloaded media: \(error)")
                            continuation.resume(throwing: error)
                        }
                    }
                }.store(in: &localCancellables)
        }
    }

    private var downloadStatusSubjects = [URL: PassthroughSubject<iCloudDownloadStatus, Never>]()

    // Metadata query
    private var query = NSMetadataQuery()


    public func checkDownloadStatus<T: MediaDescribing>(ofFile file: T) -> AnyPublisher<iCloudDownloadStatus, Never>  {
        guard case .url(let source) = file.source else {
            return Empty().eraseToAnyPublisher()
        }
        if let subject = downloadStatusSubjects[source] {
            // If a subject already exists for this file, return it.
            return subject.eraseToAnyPublisher()
        } else {
            // Create a new subject for this file.
            let subject = PassthroughSubject<iCloudDownloadStatus, Never>()
              downloadStatusSubjects[source] = subject

              // Set up and start the query
              setupMetadataQuery(forFile: source)

              return subject.eraseToAnyPublisher()
          }
      }

      private func setupMetadataQuery(forFile fileURL: URL) {
          query.stop()
          query.searchScopes = [NSMetadataQueryUbiquitousDocumentsScope]
          query.predicate = NSPredicate(format: "%K == %@", NSMetadataItemURLKey, fileURL as CVarArg)
          NotificationCenter.default.addObserver(self, selector: #selector(queryDidUpdate), name: .NSMetadataQueryDidUpdate, object: query)
          NotificationCenter.default.addObserver(self, selector: #selector(queryDidUpdate), name: .NSMetadataQueryGatheringProgress, object: query)
          NotificationCenter.default.addObserver(self, selector: #selector(queryDidUpdate), name: .NSMetadataQueryDidStartGathering, object: query)
          NotificationCenter.default.addObserver(self, selector: #selector(queryDidFinishGathering), name: .NSMetadataQueryDidFinishGathering, object: query)
          query.start()
      }

      @objc private func queryDidUpdate(notification: Notification) {
          processQueryResults()
      }

      @objc private func queryDidFinishGathering(notification: Notification) {
          processQueryResults()
          query.stop()
      }

      private func processQueryResults() {
          for item in query.results as! [NSMetadataItem] {
              if let fileURL = item.value(forAttribute: NSMetadataItemURLKey) as? URL,
                 let subject = downloadStatusSubjects[fileURL] {

                  let downloadStatus = iCloudDownloadStatus(fromMetadataItem: item)
                  subject.send(downloadStatus)

                  if case .downloaded = downloadStatus {
                      subject.send(completion: .finished)
                      downloadStatusSubjects.removeValue(forKey: fileURL)
                  }
              }
          }
      }

      private func iCloudDownloadStatus(fromMetadataItem item: NSMetadataItem) -> iCloudDownloadStatus {
          guard let downloadingStatus = item.value(forAttribute: NSMetadataUbiquitousItemDownloadingStatusKey) as? String else {
              return .notDownloaded
          }

          switch downloadingStatus {
          case NSMetadataUbiquitousItemDownloadingStatusDownloaded:
              return .downloaded
          case NSMetadataUbiquitousItemIsDownloadingKey:
              let progress = (item.value(forAttribute: NSMetadataUbiquitousItemPercentDownloadedKey) as? Double) ?? 0.0
              return .downloading(progress: progress / 100.0)
          default:
              return .notDownloaded
          }
      }

}


