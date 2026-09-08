//
//  ErasureProgressTests.swift
//  EncameraCoreTests
//
//  Pins the erase step catalog and the report text the progress screen, the
//  UI-test marker and the device suite read.
//

import XCTest
@testable import EncameraCore

final class ErasureProgressTests: XCTestCase {

    func testCatalogIdsAreUniqueAndOrderedBySection() {
        let catalog = ErasureStepDescriptor.allDataCatalog
        XCTAssertEqual(Set(catalog.map(\.id)).count, catalog.count, "every step id must be unique")

        let sectionOrder = ErasureStepSection.allCases
        let indices = catalog.map { sectionOrder.firstIndex(of: $0.section)! }
        XCTAssertEqual(indices, indices.sorted(), "steps must be declared in section order so the screen and the run agree")
    }

    func testCatalogRunsCloudBeforeLocalSweepAndKeychainLast() {
        let ids = ErasureStepDescriptor.allDataCatalog.map(\.id)
        let index = { (id: String) in ids.firstIndex(of: id)! }
        XCTAssertLessThan(index("migration.state"), index("sync.shutdown"))
        XCTAssertLessThan(index("sync.shutdown"), index("cloud.zones"))
        XCTAssertLessThan(index("cloud.subscriptions"), index("sweep.residual"),
                          "the residual sweep removes Library/Caches/CloudKit, after which CloudKit reads fail")
        XCTAssertLessThan(index("sweep.residual"), index("keys.keychain"))
        XCTAssertLessThan(index("keys.keychain"), index("settings.defaults"))
        XCTAssertEqual(ids.last, "final.verify")
    }

    func testTerminalReportFoldsEraseErrorIntoDetail() {
        let verdict = ErasureVerdict.pass("thumbnails clear")
        let report = ErasureStepReport.terminal("media.thumbnails",
                                                verdict: verdict,
                                                eraseError: NSError(domain: "t", code: 7))
        XCTAssertEqual(report.outcome, .pass, "a step that threw but verified clean is a pass")
        XCTAssertTrue(report.detail.contains("erase error"))
        XCTAssertNil(report.hint)
    }

    func testFailedVerdictCarriesHint() {
        let report = ErasureStepReport.terminal("keys.keychain",
                                                verdict: .residue("keychain items", names: ["GenericPassword|encamera"], hint: .keychain))
        XCTAssertEqual(report.outcome, .fail)
        XCTAssertEqual(report.hint, .keychain)
        XCTAssertTrue(report.detail.contains("encamera"))
    }

    func testResidueVerdictNamesSurvivorsAndCapsTheList() {
        let names = (1...8).map { "file\($0)" }
        let verdict = ErasureVerdict.residue("files", names: names, hint: .files)
        XCTAssertFalse(verdict.passed)
        XCTAssertTrue(verdict.summary.hasPrefix("8 files"))
        XCTAssertTrue(verdict.detail.contains("file1"))
        XCTAssertTrue(verdict.detail.contains("+3 more"))
        XCTAssertTrue(ErasureVerdict.residue("files", names: [], hint: .files).passed)
    }

    func testMarkerTextCountsPassesAndNamesFailures() {
        let descriptors = ErasureStepDescriptor.allDataCatalog
        var steps = descriptors.map { ErasureStepReport(id: $0.id, outcome: .pass) }
        steps[2] = ErasureStepReport(id: "cloud.zones", outcome: .fail, summary: "offline", hint: .cloudUnreachable)
        steps[3] = .skipped("cloud.subscriptions", "no account")
        let report = ErasureReport(descriptors: descriptors, steps: steps, cloudKitDeletionFailed: true)

        XCTAssertFalse(report.isClean)
        XCTAssertEqual(report.markerText, "complete:ok=\(descriptors.count - 1)/\(descriptors.count):fail=cloud.zones")
    }

    func testFullTextListsEverySectionAndTheVerdict() {
        let descriptors = ErasureStepDescriptor.allDataCatalog
        let steps = descriptors.map { ErasureStepReport(id: $0.id, outcome: .pass, summary: "ok") }
        let text = ErasureReport(descriptors: descriptors, steps: steps, cloudKitDeletionFailed: false).fullText

        for section in ErasureStepSection.allCases where descriptors.contains(where: { $0.section == section }) {
            XCTAssertTrue(text.contains("## \(section.rawValue)"), "missing section \(section.rawValue)")
        }
        XCTAssertTrue(text.contains("[PASS] final.verify"))
        XCTAssertTrue(text.contains("VERDICT: device is empty"))
    }

    func testFullTextRendersUndeclaredStepsAsPending() {
        let descriptors = ErasureStepDescriptor.allDataCatalog
        let text = ErasureReport(descriptors: descriptors, steps: [], cloudKitDeletionFailed: false).fullText
        XCTAssertTrue(text.contains("[----] migration.state"))
    }
}
