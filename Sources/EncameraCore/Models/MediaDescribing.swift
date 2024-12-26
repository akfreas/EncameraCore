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

public enum MediaSource {
    case data(Data)
    case url(URL)
}

extension MediaSource: Codable {

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let data = try? container.decode(Data.self) {
            self = .data(data)
        } else if let url = try? container.decode(URL.self) {
            self = .url(url)
        } else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Could not decode MediaSource")
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .data(let data):
            try container.encode(data)
        case .url(let url):
            try container.encode(url)
        }
    }
}

extension MediaSource: Equatable {

    public static func == (lhs: MediaSource, rhs: MediaSource) -> Bool {
        switch (lhs, rhs) {
        case (.data(let data1), .data(let data2)):
            return data1 == data2
        case (.url(let url1), .url(let url2)):
            return url1 == url2
        default:
            return false
        }
    }
}

extension MediaSource: Hashable {

    public func hash(into hasher: inout Hasher) {
        switch self {
        case .data(let data):
            hasher.combine(data)
        case .url(let url):
            hasher.combine(url)
        }
    }
}



public protocol MediaDescribing: Hashable, Identifiable {


    var source: MediaSource { get }
    var mediaType: MediaType { get }
    var needsDownload: Bool { get }
    var id: String { get }
    var timestamp: Date? { get }

    init?(source: MediaSource, generateID: Bool)
    init(source: MediaSource, mediaType: MediaType, id: String)
}

public extension MediaDescribing {

    var data: Data? {
        switch source {
        case .data(let data):
            return data
        default:
            return nil
        }
    }

    var url: URL? {
        switch source {
        case .url(let url):
            return url
        default:
            return nil
        }
    }

    var downloadedSource: URL? {
        guard case .url(let source) = source else {
            return nil
        }
        var lastComponent = source
            .lastPathComponent

        if lastComponent.first == "." {
            lastComponent.removeFirst()
        }

        lastComponent = lastComponent.replacingOccurrences(of: ".icloud", with: "")
        return source.deletingLastPathComponent().appendingPathComponent(lastComponent)
    }


     var timestamp: Date? {
         guard case .url(let source) = source else {
            return nil
        }
         #warning("Potentially slow, improve this")
        _ = source.startAccessingSecurityScopedResource()
        let date = try? FileManager.default.attributesOfItem(atPath: source.path)[FileAttributeKey.creationDate] as? Date
        source.stopAccessingSecurityScopedResource()
        return date
    }
}
