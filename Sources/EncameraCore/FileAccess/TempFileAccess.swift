import Foundation

public class TempFileAccess {
    
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
                debugPrint("Deleted files at \(url)")
            } else {
                debugPrint("No temporary media directory, not deleting")
            }
        } catch let error {
            debugPrint("Could not delete files: \(error)")
        }
    }

}
