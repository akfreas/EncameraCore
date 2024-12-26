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

    public init(source: MediaSource, mediaType: MediaType, id: String) {
        self.init(source: source)
        self.mediaType = mediaType
        self.id = id
    }

    public init(source: URL) {
        self.init(source: .url(source))
    }

    public init(source: URL, mediaType: MediaType, id: String) {
        self.init(source: .url(source), mediaType: mediaType, id: id)
    }


    public init(source: Data) {
        self.init(source: .data(source))
    }

    public init(source: Data, mediaType: MediaType, id: String) {
        self.init(source: .data(source), mediaType: mediaType, id: id)
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


