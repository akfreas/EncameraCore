//
//  PreviewModel.swift
//  Encamera
//
//  Created by Alexander Freas on 22.08.22.
//

import Foundation
public struct PreviewModel: Codable {
    
    public var id: String
    
    public var thumbnailMedia: CleartextMedia
    public var gridID: String {
        "\(thumbnailMedia.mediaType.fileExtension)_\(thumbnailMedia.id)"
    }
    public var videoDuration: String?
    public var isLivePhoto: Bool = false

    init(source: CleartextMedia) throws {
        guard case .data(let data) = source.source else {
            throw FileAccessError.couldNotLoadMedia
        }
        let decoded = try JSONDecoder().decode(PreviewModel.self, from: data)
        self.id = decoded.id
        self.thumbnailMedia = decoded.thumbnailMedia
        self.isLivePhoto = decoded.isLivePhoto
        self.videoDuration = decoded.videoDuration
    }
    
    init(thumbnailMedia: CleartextMedia) {
        self.thumbnailMedia = thumbnailMedia
        self.id = thumbnailMedia.id
    }
    
}
