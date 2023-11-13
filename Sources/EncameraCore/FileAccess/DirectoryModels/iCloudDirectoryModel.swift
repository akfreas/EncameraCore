//
//  iCloudDirectoryModel.swift
//  Encamera
//
//  Created by Alexander Freas on 05.08.22.
//

import Foundation
import Combine

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
    
    public func resolveDownloadedMedia<T: MediaDescribing>(media: T) throws -> T? where T.MediaSource == URL {
        if FileManager.default.fileExists(atPath: media.downloadedSource.path) {
            if let downloaded = T(source: media.downloadedSource) {
                return downloaded
            } else {
                throw DataStorageModelError.couldNotCreateMedia
            }
        } else {
            return nil
        }
    }
    
    
    func downloadFileFromiCloud<T: MediaDescribing>(media: T, progress: (Double) -> Void) async throws -> T where T.MediaSource == URL {
        guard media.needsDownload == true else {
            return media
        }
        try FileManager.default.startDownloadingUbiquitousItem(at: media.source)        

        return try await withCheckedThrowingContinuation { [weak self] continuation in
            
            guard let `self` = self else {
                return
            }
            let timer = Timer.publish(every: 1, on: .main, in: .default)
                .autoconnect()
            var attempts = 0
            
                timer
                .receive(on: DispatchQueue.main)
                .sink { out in
                    attempts += 1
                    do {
                        if let downloaded = try self.resolveDownloadedMedia(media: media) {

                            continuation.resume(returning: downloaded)
                            timer.upstream.connect().cancel()
                        }
                    } catch {
                        continuation.resume(throwing: error)
                    }
                    if attempts > 20 {
                        timer.upstream.connect().cancel()
                    }
                }.store(in: &self.localCancellables)
        }

        
    }
}
