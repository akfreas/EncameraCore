//
//  EraserUtils.swift
//  Encamera
//
//  Created by Alexander Freas on 19.09.22.
//

import Foundation

public enum ErasureScope {
    case appData
    case allData
}

public struct EraserUtils {
    
    public var keyManager: KeyManager
    public var fileAccess: FileAccess
    public var erasureScope: ErasureScope
    
    public init(keyManager: KeyManager, fileAccess: FileAccess, erasureScope: ErasureScope) {
        self.keyManager = keyManager
        self.fileAccess = fileAccess
        self.erasureScope = erasureScope
    }
    
    public func erase() async throws {
        switch erasureScope {
        case .appData:
            await eraseAppData()
        case .allData:
            await eraseAllData()
        }
    }
    
    private func eraseAllData() async {
        try? await fileAccess.deleteAllMedia()
        keyManager.clearKeychainData()
        eraseUserDefaults()
    }
    
    private func eraseAppData() async {
        keyManager.clearKeychainData()
        eraseUserDefaults()
    }
    
    private func eraseUserDefaults() {
        UserDefaultUtils.removeAll()
    }
    
}
