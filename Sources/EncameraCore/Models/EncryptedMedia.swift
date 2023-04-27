//
//  EncryptedMedia.swift
//  Encamera
//
//  Created by Alexander Freas on 19.05.22.
//

import Foundation

public class EncryptedMedia: MediaDescribing, ObservableObject, Codable, Identifiable {
    public typealias MediaSource = URL
    
    public var needsDownload: Bool {
        return source != downloadedSource
    }
    
    public var mediaType: MediaType = .unknown
    public var id: String
    public var source: URL
    public lazy var timestamp: Date? = {
        _ = source.startAccessingSecurityScopedResource()
        let date = try? FileManager.default.attributesOfItem(atPath: source.path)[FileAttributeKey.creationDate] as? Date
        source.stopAccessingSecurityScopedResource()
        return date
    }()
    
    public required init(source: URL, mediaType: MediaType, id: String) {
        self.source = source
        self.mediaType = mediaType
        self.id = id
    }
    
    convenience init?(source: URL, type: MediaType) {
        self.init(source: source)
        self.mediaType = type
    }
    
    public required init?(source: URL) {
        self.source = source
        guard let id = source.deletingPathExtension().lastPathComponent.split(separator: ".").first else {
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
