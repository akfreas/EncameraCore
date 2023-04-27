import Foundation

public class TempFileAccess {
    
    public static func cleanupTemporaryFiles() {
        do {
            if FileManager.default.fileExists(atPath: URL.tempMediaDirectory.path) {
                try FileManager.default.removeItem(at: URL.tempMediaDirectory)
                debugPrint("Deleted files at \(URL.tempMediaDirectory)")
            } else {
                debugPrint("No temporary media directory, not deleting")
            }
        } catch let error {
            debugPrint("Could not delete files: \(error)")
        }
    }
    
}
