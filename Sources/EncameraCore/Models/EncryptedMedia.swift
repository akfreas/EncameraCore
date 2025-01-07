//
//  EncryptedMedia.swift
//  Encamera
//
//  Created by Alexander Freas on 19.05.22.
//

import Foundation

public class EncryptedMedia: MediaDescribing, ObservableObject, Codable, Identifiable {

    public var needsDownload: Bool {
        guard case .url(let source) = source else {
            return false
        }

        do {
            let resourceValues = try source.resourceValues(forKeys: [
                .isUbiquitousItemKey,
                .ubiquitousItemDownloadingStatusKey
            ])

            if resourceValues.isUbiquitousItem == true {
                if let downloadingStatus = resourceValues.ubiquitousItemDownloadingStatus {
                    return downloadingStatus != .current
                }
            }

            return false
        } catch {
            print("Error accessing file resource values: \(error)")
            return false
        }
    }

    public var mediaType: MediaType = .unknown
    public var id: String
    public var source: MediaSource
    
    
    public required init(source: MediaSource, mediaType: MediaType, id: String) {
        self.source = source
        self.mediaType = mediaType
        self.id = id
    }
    
    convenience init?(source: URL, type: MediaType) {
        self.init(source: .url(source))
        self.mediaType = type
    }

    convenience init?(source: URL) {
        self.init(source: .url(source))
    }

    public convenience init(source: URL, mediaType: MediaType, id: String) {
        self.init(source: .url(source), mediaType: mediaType, id: id)
    }

    public convenience init(source: Data, mediaType: MediaType, id: String) {
        self.init(source: .data(source), mediaType: mediaType, id: id)
    }

    public required init?(source: MediaSource, generateID: Bool = false) {
        self.source = source
        guard case .url(let source) = source, let id = source.deletingPathExtension().lastPathComponent.split(separator: ".").first else {
            return nil
        }
        self.id = String(id)
        self.mediaType = MediaType.typeFromMedia(source: self)
    }
}

extension EncryptedMedia: Hashable {
    public static func == (lhs: EncryptedMedia, rhs: EncryptedMedia) -> Bool {
        lhs.id == rhs.id
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }


}
