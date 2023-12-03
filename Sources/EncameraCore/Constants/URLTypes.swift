//
//  URLTypes.swift
//  Encamera
//
//  Created by Alexander Freas on 08.09.22.
//

import Foundation

public enum URLType: Equatable {
    
    private static var keyDataQueryParam = "data"
    private static var featureToggleQueryParam = "feature"
    
    case media(encryptedMedia: EncryptedMedia)
    case key(key: PrivateKey)
    case featureToggle(feature: Feature)
    case camera

    public init?(url: URL) {
        if let key = URLType.extractKey(url: url) {
            self = .key(key: key)
        } else if let media = URLType.extractMediaSource(url: url) {
            self = .media(encryptedMedia: media)
        } else if let feature = URLType.extractFeatureToggle(url: url) {
            self = .featureToggle(feature: feature)
        } else if url.absoluteString.starts(with: "\(AppConstants.deeplinkSchema)://camera") {
            self = .camera
        } else {
            return nil
        }
    }
    
    public var url: URL? {
        switch self {
        case .media(let encryptedMedia):
            return encryptedMedia.source
        case .key(let key):
            return keyURL(key: key)
        case .featureToggle(feature: let feature):
            return featureToggleURL(feature: feature)
        case .camera:
            return cameraURL()
        }
    }

    private func cameraURL() -> URL? {
        var components = URLComponents()
        components.scheme = AppConstants.deeplinkSchema
        components.host = "camera"
        return components.url
    }

    private func featureToggleURL(feature: Feature) -> URL? {
        var components = URLComponents()
        components.scheme = AppConstants.deeplinkSchema
        components.host = "featureToggle"
        components.queryItems = [URLQueryItem(name: URLType.featureToggleQueryParam, value: feature.rawValue)]
        return components.url
    }
    
    private func keyURL(key: PrivateKey) -> URL? {
        guard let keyString = key.base64String else {
            return nil
        }
        var components = URLComponents()
        components.scheme = AppConstants.deeplinkSchema
        components.host = "key"
        components.queryItems = [URLQueryItem(name: URLType.keyDataQueryParam, value: keyString)]
        
        
        return components.url
    }
    
    
    private static func extractKey(url: URL) -> PrivateKey? {
        guard url.absoluteString.starts(with: "\(AppConstants.deeplinkSchema)") else {
            return nil
        }
        
        let urlParams = URLComponents(url: url, resolvingAgainstBaseURL: false)
        guard let keyParam = urlParams?.queryItems?.first(where: {$0.name == URLType.keyDataQueryParam})?.value,
              let extractedKey = try? PrivateKey(base64String: keyParam)
            else {
            return nil
        }
        
        return extractedKey
        
    }
    
    private static func extractMediaSource(url: URL) -> EncryptedMedia? {
        guard url.pathExtension == MediaType.photo.fileExtension || url.pathExtension == MediaType.video.fileExtension else {
            return nil
        }
        return EncryptedMedia(source: url)
    }
    
    private static func extractFeatureToggle(url: URL) -> Feature? {
        let urlParams = URLComponents(url: url, resolvingAgainstBaseURL: false)

        guard let featureParam = urlParams?.queryItems?.first(where: {$0.name == URLType.featureToggleQueryParam})?.value else {
            return nil
        }
            return Feature(rawValue: featureParam)
    }
    
}
