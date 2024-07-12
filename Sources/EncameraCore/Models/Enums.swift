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
    
    public static var supportedMediaFileExtensions: [String] {
        supportedMovieFileExtensions + supportedPhotoFileExtensions
    }
    
    public static var supportedMovieFileExtensions: [String] {
        supportedMovieFileTypes.map({$0.preferredFilenameExtension}).compactMap({$0})
    }
    
    public static var supportedPhotoFileExtensions: [String] {
        supportedPhotoFileTypes.map({$0.preferredFilenameExtension}).compactMap({$0}) + ["jpg"]
    }
    public static var supportedPhotoFileTypes: [UTType] {
        [
            UTType.image,
            UTType.jpeg,
            UTType.png,
            UTType.heic
        ]
    }
    
    
    
    public static var supportedMovieFileTypes: [UTType] {
        [
            UTType.quickTimeMovie,
            UTType.mpeg4Movie,
            UTType.mpeg2Video
        ]
    }
    
    public static var mediaTypeMappings: [String: MediaType] {
        var mapping: [String: MediaType] = [:]
        
        for extensionString in supportedPhotoFileExtensions {
            mapping[extensionString] = .photo
        }
        
        for extensionString in supportedMovieFileExtensions {
            mapping[extensionString] = .video
        }
        
        
        return mapping
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
              let type = self.allCases.filter({$0.fileExtension == fileExtension }).first
        else {
            return .unknown
        }
        return type
    }
    
    private static func typeFrom(media: CleartextMedia) -> MediaType {
        if case .url(let url) = media.source {
            let pathExtension = url.pathExtension.lowercased()

            guard let mapped = MediaType.mediaTypeMappings[pathExtension] else {
                return .unknown
            }

            return mapped
        }
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

    public var title: String {
        switch self {
        case .photo:
            return "Photo"
        case .video:
            return "Video"
        }
    }
}
