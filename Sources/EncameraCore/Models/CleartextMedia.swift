//
//  CleartextMedia.swift
//  Encamera
//
//  Created by Alexander Freas on 19.05.22.
//

import Foundation



public struct CleartextMedia: MediaDescribing, Codable {
    

    public var source: MediaSource
    public var mediaType: MediaType = .unknown
    public var id: String
    public var needsDownload: Bool {
        false
    }

    public var timestamp: Date?

    /// The source file's real filename, captured at the import entry point
    /// before any copy to a UUID-named temp file loses it.
    public var originalFilename: String?

    public init(source: MediaSource, mediaType: MediaType, id: String) {
        self.init(source: source)
        self.mediaType = mediaType
        self.id = id
    }

    public init(source: MediaSource, mediaType: MediaType, id: String, originalFilename: String?) {
        self.init(source: source, mediaType: mediaType, id: id)
        self.originalFilename = originalFilename
    }

    public init(source: URL) {
        self.init(source: .url(source))
    }

    public init(source: URL, mediaType: MediaType, id: String, originalFilename: String? = nil) {
        self.init(source: .url(source), mediaType: mediaType, id: id, originalFilename: originalFilename)
    }


    public init(source: Data) {
        self.init(source: .data(source))
    }

    public init(source: Data, mediaType: MediaType, id: String, originalFilename: String? = nil) {
        self.init(source: .data(source), mediaType: mediaType, id: id, originalFilename: originalFilename)
    }

    public init(source: MediaSource, generateID: Bool = false) {
        self.source = source
        switch source {
        case .data:
            self.id = NSUUID().uuidString
            self.timestamp = Date()
        case .url(let url):
            self.id = generateID ? NSUUID().uuidString : url.deletingPathExtension().lastPathComponent
        }
        mediaType = MediaType.typeFromMedia(source: self)
    }

}


