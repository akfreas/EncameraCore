//
//  ErasureProgress.swift
//  EncameraCore
//
//  The step catalog and per-step reporting for "Erase All Data".
//
//  `EraserUtils` runs the catalog in order and reports every step twice: once
//  as `.running` and once with its terminal outcome. A step's outcome is decided
//  by its own verification, which re-reads the surface the step claims to have
//  cleared — an erase call that threw nothing has never been evidence that the
//  data is gone. Failures never stop the run; every later step still executes.
//
//  Step ids are stable and are the contract the progress screen, the UI-test
//  page object and the device suite key on. Titles here are English and exist
//  for logs and the copyable report; the screen localizes by id.
//

import Foundation

// MARK: - Outcome

public enum ErasureStepOutcome: String, Equatable, Sendable {
    /// Declared but not yet started.
    case pending
    /// Erase or verification in progress.
    case running
    /// Verification re-read the surface and found it empty.
    case pass
    /// Verification found residue, or the erase failed and left the surface dirty.
    case fail
    /// Not applicable on this device (no iCloud account, container unavailable).
    /// Distinct from `fail` so a report never claims more broken things than it saw.
    case skipped
}

// MARK: - Sections

/// The groups the progress screen renders, in run order.
public enum ErasureStepSection: String, CaseIterable, Sendable {
    case activity = "Stopping activity"
    case cloud = "iCloud"
    case media = "Media & caches"
    case app = "App services"
    case keys = "Keys & settings"
    case finalCheck = "Final check"
}

// MARK: - Recovery hints

/// What the user can do about a failed step. The screen maps these to copy; the
/// options are deliberately few, because the user cannot edit the keychain or
/// defaults themselves — retrying, reconnecting, or reinstalling is all there is.
public enum ErasureRecoveryHint: String, Equatable, Sendable {
    /// iCloud could not be reached; the app retries the cloud wipe on launch.
    case cloudUnreachable
    /// Keychain items survived; retry, then reinstall.
    case keychain
    /// Files survived; deleting the app removes them.
    case files
    /// Defaults keys survived; retry, then reinstall.
    case settings
    /// Anything else; retry, then reinstall.
    case retry
}

// MARK: - Descriptor

/// The static description of a step, declared up front so the screen can render
/// the whole checklist before the run starts.
public struct ErasureStepDescriptor: Identifiable, Equatable, Sendable {
    public let id: String
    public let title: String
    public let section: ErasureStepSection

    public init(id: String, title: String, section: ErasureStepSection) {
        self.id = id
        self.title = title
        self.section = section
    }

    /// The steps `EraserUtils` itself performs for `.allData`, in run order.
    /// App-layer steps (`ErasureStep`) are inserted into the `.app` section by
    /// the caller that owns them.
    public static let allDataCatalog: [ErasureStepDescriptor] = [
        .init(id: "migration.state",      title: "Cancel migrations",                           section: .activity),
        .init(id: "sync.shutdown",        title: "Stop iCloud sync",                            section: .activity),

        .init(id: "cloud.zones",          title: "Delete iCloud data",                          section: .cloud),
        .init(id: "cloud.subscriptions",  title: "Remove iCloud notifications",                 section: .cloud),

        .init(id: "media.activeBackend",  title: "Delete current album media",                  section: .media),
        .init(id: "media.localAlbums",    title: "Delete local and iCloud Drive albums",        section: .media),
        .init(id: "media.indexes",        title: "Delete media indexes",                        section: .media),
        .init(id: "media.blobCache",      title: "Delete downloaded copies and pending uploads", section: .media),
        .init(id: "media.thumbnails",     title: "Delete thumbnails",                           section: .media),
        .init(id: "media.temp",           title: "Delete temporary files",                      section: .media),
        .init(id: "media.sharedImports",  title: "Delete shared imports",                       section: .media),

        .init(id: "sweep.residual",       title: "Remove remaining files",                      section: .keys),
        .init(id: "keys.keychain",        title: "Delete keys and passcode",                    section: .keys),
        .init(id: "settings.defaults",    title: "Reset settings",                              section: .keys),

        .init(id: "final.verify",         title: "Verify the device is empty",                  section: .finalCheck),
    ]
}

// MARK: - Verdict

/// What a step's verification concluded. Built by the verifier, never by the
/// erase call.
public struct ErasureVerdict: Equatable, Sendable {
    public let passed: Bool
    /// One line, safe to render in the checklist.
    public let summary: String
    /// Verbose evidence: surviving names, error text.
    public let detail: String
    public let hint: ErasureRecoveryHint?

    public init(passed: Bool, summary: String, detail: String = "", hint: ErasureRecoveryHint? = nil) {
        self.passed = passed
        self.summary = summary
        self.detail = detail
        self.hint = hint
    }

    public static func pass(_ summary: String = "", detail: String = "") -> ErasureVerdict {
        ErasureVerdict(passed: true, summary: summary, detail: detail)
    }

    public static func fail(_ summary: String, detail: String = "", hint: ErasureRecoveryHint) -> ErasureVerdict {
        ErasureVerdict(passed: false, summary: summary, detail: detail, hint: hint)
    }

    /// Names the survivors so the report is actionable; a count is not.
    public static func residue(_ label: String, names: [String], hint: ErasureRecoveryHint) -> ErasureVerdict {
        if names.isEmpty {
            return .pass("\(label) clear")
        }
        let shown = names.prefix(5).joined(separator: ", ")
        let more = names.count > 5 ? " (+\(names.count - 5) more)" : ""
        return .fail("\(names.count) \(label) remain",
                     detail: "\(label): \(shown)\(more)",
                     hint: hint)
    }
}

// MARK: - Step report

public struct ErasureStepReport: Equatable, Sendable {
    public let id: String
    public let outcome: ErasureStepOutcome
    public let summary: String
    public let detail: String
    public let hint: ErasureRecoveryHint?

    public init(id: String,
                outcome: ErasureStepOutcome,
                summary: String = "",
                detail: String = "",
                hint: ErasureRecoveryHint? = nil) {
        self.id = id
        self.outcome = outcome
        self.summary = summary
        self.detail = detail
        self.hint = hint
    }

    public static func running(_ id: String) -> ErasureStepReport {
        ErasureStepReport(id: id, outcome: .running)
    }

    public static func skipped(_ id: String, _ summary: String) -> ErasureStepReport {
        ErasureStepReport(id: id, outcome: .skipped, summary: summary)
    }

    /// Terminal report from a verdict. `eraseError` is folded into the detail so a
    /// step that threw but verified clean still shows what it threw.
    public static func terminal(_ id: String, verdict: ErasureVerdict, eraseError: Error? = nil) -> ErasureStepReport {
        var detail = verdict.detail
        if let eraseError {
            let errorLine = "erase error: \(eraseError)"
            detail = detail.isEmpty ? errorLine : detail + "\n" + errorLine
        }
        return ErasureStepReport(id: id,
                                 outcome: verdict.passed ? .pass : .fail,
                                 summary: verdict.summary,
                                 detail: detail,
                                 hint: verdict.passed ? nil : verdict.hint)
    }
}

// MARK: - Injected step

/// A step owned by a layer above EncameraCore (the app target's purchase SDK,
/// analytics, background tasks). Carries its own verification, like every
/// core step.
public struct ErasureStep: Sendable {
    public let descriptor: ErasureStepDescriptor
    public let erase: @Sendable () async throws -> Void
    public let verify: @Sendable () async -> ErasureVerdict

    public init(descriptor: ErasureStepDescriptor,
                erase: @escaping @Sendable () async throws -> Void,
                verify: @escaping @Sendable () async -> ErasureVerdict) {
        self.descriptor = descriptor
        self.erase = erase
        self.verify = verify
    }
}

// MARK: - Run report

/// The whole run. `cloudKitDeletionFailed` keeps the meaning it had before the
/// checklist existed: an `.allData` wipe could not remove the CloudKit data AND
/// the user could actually have data there.
public struct ErasureReport: Sendable {
    public let descriptors: [ErasureStepDescriptor]
    public let steps: [ErasureStepReport]
    public let cloudKitDeletionFailed: Bool

    public init(descriptors: [ErasureStepDescriptor],
                steps: [ErasureStepReport],
                cloudKitDeletionFailed: Bool) {
        self.descriptors = descriptors
        self.steps = steps
        self.cloudKitDeletionFailed = cloudKitDeletionFailed
    }

    public var failures: [ErasureStepReport] { steps.filter { $0.outcome == .fail } }
    public var isClean: Bool { failures.isEmpty }

    public func report(for id: String) -> ErasureStepReport? {
        steps.first { $0.id == id }
    }

    private func title(for id: String) -> String {
        descriptors.first { $0.id == id }?.title ?? id
    }

    /// Compact single-line form for the UI-test accessibility marker:
    /// `complete:ok=<n>/<total>:fail=<id|id>`
    public var markerText: String {
        let considered = steps.filter { $0.outcome != .running && $0.outcome != .pending }
        let ok = considered.filter { $0.outcome == .pass || $0.outcome == .skipped }.count
        let failedIDs = failures.map(\.id).joined(separator: "|")
        return "complete:ok=\(ok)/\(considered.count):fail=\(failedIDs)"
    }

    /// Full multi-line report for the copy button and the device suite's
    /// xcresult attachment.
    public var fullText: String {
        var lines: [String] = ["===== Erase All Data ====="]
        for section in ErasureStepSection.allCases {
            let ids = descriptors.filter { $0.section == section }.map(\.id)
            guard !ids.isEmpty else { continue }
            lines.append("")
            lines.append("## \(section.rawValue)")
            for id in ids {
                let step = report(for: id) ?? ErasureStepReport(id: id, outcome: .pending)
                lines.append("[\(step.outcome.reportMark)] \(id) — \(title(for: id))")
                if !step.summary.isEmpty {
                    lines.append("       \(step.summary)")
                }
                if let hint = step.hint {
                    lines.append("       hint: \(hint.rawValue)")
                }
                for detailLine in step.detail.split(separator: "\n", omittingEmptySubsequences: true) {
                    lines.append("       | \(detailLine)")
                }
            }
        }
        lines.append("")
        lines.append("--------------------------")
        lines.append("VERDICT: \(isClean ? "device is empty" : "\(failures.count) step(s) left residue")")
        if cloudKitDeletionFailed {
            lines.append("CLOUDKIT: deletion failed; retried on next launch")
        }
        lines.append("==========================")
        return lines.joined(separator: "\n")
    }
}

extension ErasureStepOutcome {
    var reportMark: String {
        switch self {
        case .pass:    return "PASS"
        case .fail:    return "FAIL"
        case .skipped: return "SKIP"
        case .running: return "RUN "
        case .pending: return "----"
        }
    }
}
