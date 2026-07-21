//
//  ImportSkipReason.swift
//  EncameraCore
//
//  Low-cardinality classification of why a media item was skipped during import.
//  Used both to surface a human-readable reason to the user (ENC-65) and, later,
//  to report a privacy-safe reason string to analytics (ENC-66). Never carries a
//  filename or path.
//

import Foundation

public enum ImportSkipReason: String, Sendable, CaseIterable {
    /// The file's format is not something the pipeline can import even after transcoding.
    case unsupportedFormat = "unsupported_format"
    /// The file could not be decoded/converted to a native format.
    case transcodeFailed = "transcode_failed"
    /// The file could not be read or otherwise failed during save.
    case readError = "read_error"

    /// Classifies an error thrown during normalization or import into a coarse reason.
    public init(error: Error) {
        switch error {
        case let transcoderError as MediaTranscoderError:
            switch transcoderError {
            case .unsupportedType:
                self = .unsupportedFormat
            case .undecodable, .exportFailed:
                self = .transcodeFailed
            case .writeFailed:
                self = .readError
            }
        case InteractableMediaError.unknownMediaType:
            self = .unsupportedFormat
        default:
            self = .readError
        }
    }

    /// Human-readable reason shown to the user (localized).
    public var localizedDescription: String {
        switch self {
        case .unsupportedFormat:
            return L10n.AlbumDetailView.importReasonUnsupportedFormat
        case .transcodeFailed:
            return L10n.AlbumDetailView.importReasonTranscodeFailed
        case .readError:
            return L10n.AlbumDetailView.importReasonReadError
        }
    }
}
