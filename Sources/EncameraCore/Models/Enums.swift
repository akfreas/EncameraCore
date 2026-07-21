//
//  Enums.swift
//  Encamera
//
//  Created by Alexander Freas on 13.05.22.
//

import Foundation
import UniformTypeIdentifiers

public enum MediaType: Int, CaseIterable, Codable {
    
    
    case photo
    case video
    case unknown
    case preview
    
    /// Classifies a file URL as `.photo`, `.video`, or `.unknown` by the file
    /// type's UTType conformance rather than a hardcoded extension whitelist, so
    /// any image/video format the OS understands is recognized. This is the
    /// single source of truth for cleartext type detection and mirrors the type
    /// decision in `MediaTranscoder.normalizeForImport`.
    public static func from(url: URL) -> MediaType {
        guard let utType = UTType(filenameExtension: url.pathExtension.lowercased()) else {
            return .unknown
        }
        if utType.conforms(to: .image) {
            return .photo
        }
        if utType.conforms(to: .movie) || utType.conforms(to: .video) {
            return .video
        }
        return .unknown
    }

    public static func typeFromMedia<T: MediaDescribing>(source: T) -> MediaType {



        switch source {
        case let media as CleartextMedia:
            return typeFrom(media: media)
        case let media as EncryptedMedia:
            return typeFrom(media: media)
        
        default:
            return .unknown
        }
        
    }
    
    private static func typeFrom(media: EncryptedMedia) -> MediaType {
        guard case .url(let url) = media.source else {
            return .unknown
        }
        return typeFromURL(url)
    }
    
    private static func typeFromURL(_ url: URL) -> MediaType {
        
        guard let fileExtension = url.lastPathComponent.split(separator: ".")[safe: 1],
              let type = self.allCases.filter({$0.encryptedFileExtension == fileExtension }).first
        else {
            return .unknown
        }
        return type
    }
    
    private static func typeFrom(media: CleartextMedia) -> MediaType {
        if case .url(let url) = media.source {
            return from(url: url)
        }
        return .photo
    }
    
    public var encryptedFileExtension: String {
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

    public var decryptedFileExtension: String {
        switch self {
        case .video:
            return "mov"
        case .photo:
            return "jpg"
        case .unknown:
            return "unknown"
        case .preview:
            return "jpg"
        }
    }
}

public enum CameraMode: Int {
    case photo
    case video

    public var title: String {
        switch self {
        case .photo:
            return "Photo"
        case .video:
            return "Video"
        }
    }
}
