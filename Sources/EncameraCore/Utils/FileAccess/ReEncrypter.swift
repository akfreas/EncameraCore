//
//  File.swift
//  
//
//  Created by Alexander Freas on 12.02.24.
//

import Foundation

public protocol ReEncrypting {


    init(sourceKey: PrivateKey, targetKey: PrivateKey)

    func reEncryptFiles(fileList: [EncryptedMedia]) async throws

}


public class ReEncrypter {

    private var sourceKey: PrivateKey
    private var targetKey: PrivateKey

    public required init(sourceKey: PrivateKey, targetKey: PrivateKey) {
        self.sourceKey = sourceKey
        self.targetKey = targetKey
    }

    public func reEncryptFiles(fileList: [EncryptedMedia]) async throws -> [EncryptedMedia] {
        let targetDirectoryDecrypted = URL.tempMediaDirectory
            .appending(path: "bulk_decrypted")

        let targetDirectoryEncrypted = URL.tempMediaDirectory
            .appending(path: "bulk_encrypted")
        var result: [EncryptedMedia] = []
        for file in fileList {


            let sourceFileHandler = SecretFileHandler(keyBytes: sourceKey.keyBytes, source: file, targetURL: targetDirectoryDecrypted.appendingPathComponent(file.id))
            let decrypted: CleartextMedia<URL> = try await sourceFileHandler.decrypt()

            let targetFileHandler = SecretFileHandler(keyBytes: targetKey.keyBytes, source: decrypted, targetURL: targetDirectoryEncrypted.appendingPathComponent(file.id))
            let reencrypted = try await targetFileHandler.encrypt()
            result.append(reencrypted)
        }
        return result
    }
}
