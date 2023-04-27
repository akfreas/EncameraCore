//
//  Enums.swift
//  Encamera
//
//  Created by Alexander Freas on 13.05.22.
//

import Foundation
public enum MediaType: Int, CaseIterable, Codable {
    
    case photo
    case video
    case unknown
    case preview
    
    public static func typeFromMedia<T: MediaDescribing>(source: T) -> MediaType {
        
        switch source {
        case let media as CleartextMedia<Data>:
            return typeFrom(media: media)
        case let media as CleartextMedia<URL>:
            return typeFrom(media: media)
        case let media as EncryptedMedia:
            return typeFrom(media: media)
        
        default:
            return .unknown
        }
        
    }
    
    private static func typeFrom(media: EncryptedMedia) -> MediaType {
        return typeFromURL(media.source)
    }
    
    private static func typeFrom(media: CleartextMedia<URL>) -> MediaType {
        // We only support one type of media that we decrypt
        // to a URL, and that is video
        return .video
    }
    
    private static func typeFromURL(_ url: URL) -> MediaType {
        
        guard let fileExtension = url.lastPathComponent.split(separator: ".")[safe: 1],
              let type = self.allCases.filter({$0.fileExtension == fileExtension }).first
        else {
            return .unknown
        }
        return type
    }
    
    private static func typeFrom(media: CleartextMedia<Data>) -> MediaType {
        return .photo
    }
    
    public var fileExtension: String {
        switch self {
        case .video:
            return "encvideo"
        case .photo:
            return "encimage"
        case .unknown:
            return "unknown"
        case .preview:
            return "encpreview"
        }
    }
}

public enum CameraMode: Int {
    case photo
    case video
}
