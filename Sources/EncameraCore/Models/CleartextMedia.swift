//
//  CleartextMedia.swift
//  Encamera
//
//  Created by Alexander Freas on 19.05.22.
//

import Foundation

public struct CleartextMedia<T: MediaSourcing>: MediaDescribing, Codable {
    
    public typealias MediaSource = T
    
    public var source: T
    public var mediaType: MediaType = .unknown
    public var id: String
    public var needsDownload: Bool {
        false
    }
    
    public init(source: T, mediaType: MediaType, id: String) {
        self.init(source: source)
        self.mediaType = mediaType
        self.id = id
    }
    
    public init(source: T) {
        self.source = source
        if let source = source as? URL {
            self.id = source.deletingPathExtension().lastPathComponent
        } else if source is Data {
            self.id = NSUUID().uuidString
        } else {
            fatalError()
        }
        mediaType = MediaType.typeFromMedia(source: self)
    }
}


