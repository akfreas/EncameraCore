//
//  UploadStubs.swift
//  EncameraCoreTests
//
//  Test-only conveniences for the CloudKit value types.
//
//  `keyFingerprint` is required on the real initializers, so production callers cannot
//  forget it — that is the point, and the compiler is what enforces it. Most tests are
//  about something else entirely (queueing, retries, tokens, deletes) and would be
//  noisier for restating a fingerprint they never assert on, so these overloads supply a
//  recognisable stub. A test that cares about the key passes one explicitly and gets the
//  real initializer.
//

import Foundation
@testable import EncameraCore

/// Obviously synthetic, so it can never be mistaken for a real fingerprint in a failure
/// message or a recorded upload.
let stubKeyFingerprint = "00000000000000000000000000000000"

extension CloudKitMediaUpload {
    init(albumID: String,
         mediaID: String,
         mediaType: MediaType,
         createdAt: Date,
         sizeBytes: Int64,
         encryptedFileURL: URL,
         encryptedThumbURL: URL?,
         recordName: String? = nil,
         schemaVersion: Int64 = CloudKitSchema.currentSchemaVersion) {
        self.init(albumID: albumID,
                  mediaID: mediaID,
                  mediaType: mediaType,
                  createdAt: createdAt,
                  sizeBytes: sizeBytes,
                  encryptedFileURL: encryptedFileURL,
                  encryptedThumbURL: encryptedThumbURL,
                  recordName: recordName,
                  keyFingerprint: stubKeyFingerprint,
                  schemaVersion: schemaVersion)
    }
}

extension CloudKitAlbumUpload {
    init(albumID: String,
         encName: String,
         createdAt: Date,
         isHidden: Bool,
         schemaVersion: Int64 = CloudKitSchema.currentSchemaVersion) {
        self.init(albumID: albumID,
                  encName: encName,
                  createdAt: createdAt,
                  isHidden: isHidden,
                  keyFingerprint: stubKeyFingerprint,
                  schemaVersion: schemaVersion)
    }
}

extension CloudKitMediaMetadata {
    init(recordName: String,
         albumID: String,
         mediaID: String,
         mediaType: MediaType,
         createdAt: Date,
         sizeBytes: Int64,
         creationDeviceID: String,
         schemaVersion: Int64,
         recordChangeTag: String?) {
        self.init(recordName: recordName,
                  albumID: albumID,
                  mediaID: mediaID,
                  mediaType: mediaType,
                  createdAt: createdAt,
                  sizeBytes: sizeBytes,
                  creationDeviceID: creationDeviceID,
                  schemaVersion: schemaVersion,
                  keyFingerprint: stubKeyFingerprint,
                  recordChangeTag: recordChangeTag)
    }
}
