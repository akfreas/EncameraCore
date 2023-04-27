//
//  MediaMetadata.swift
//  Encamera
//
//  Created by Alexander Freas on 19.05.22.
//

import Foundation

public protocol MediaReference {
    
}

public protocol MediaSourcing: Hashable, Codable {
    
}

extension Data: MediaSourcing {
    
}

extension URL: MediaSourcing {
    
}

public protocol MediaDescribing: Hashable {
    
    associatedtype MediaSource: MediaSourcing
        
    var source: MediaSource { get }
    var mediaType: MediaType { get }
    var needsDownload: Bool { get }
    var id: String { get }
    
    init?(source: MediaSource)
    init(source: MediaSource, mediaType: MediaType, id: String)
}

public extension MediaDescribing where MediaSource == URL {
    
    var downloadedSource: URL {
        var lastComponent = source
            .lastPathComponent
        
        if lastComponent.first == "." {
            lastComponent.removeFirst()
        }
        
        lastComponent = lastComponent.replacingOccurrences(of: ".icloud", with: "")
        return source.deletingLastPathComponent().appendingPathComponent(lastComponent)
    }
    
    var gridID: String {
        "\(mediaType.fileExtension)_\(id)"
    }
}
