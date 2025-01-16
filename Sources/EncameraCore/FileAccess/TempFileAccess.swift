import Foundation

public class TempFileAccess: DebugPrintable {

    public static func cleanupTemporaryFiles() {
        deleteDirectory(at: URL.tempMediaDirectory)
    }

    public static func cleanupRecordings() {
        deleteDirectory(at: URL.tempRecordingDirectory)
    }

    private static func deleteDirectory(at url: URL) {
        do {
            if FileManager.default.fileExists(atPath: url.path) {
                try FileManager.default.removeItem(at: url)
                printDebug("Deleted files at \(url)")
            } else {
                printDebug("No temporary media directory, not deleting")
            }
        } catch let error {
            printDebug("Could not delete files: \(error)")
        }
    }

}
