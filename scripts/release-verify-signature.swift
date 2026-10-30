#!/usr/bin/env swift
import CryptoKit
import Foundation

func verify(data: Data, signature: Data, publicKey: Data) throws -> Bool {
    try Curve25519.Signing.PublicKey(rawRepresentation: publicKey).isValidSignature(signature, for: data)
}

do {
    if CommandLine.arguments.dropFirst() == ["--self-test"] {
        // Ephemeral test data/key. No production keychain access, credentials, or app installation.
        let key = Curve25519.Signing.PrivateKey()
        let original = Data("MarkUp original release bytes".utf8)
        let signature = try key.signature(for: original)
        guard try verify(data: original, signature: signature, publicKey: key.publicKey.rawRepresentation),
              try !verify(data: Data("modified release bytes".utf8), signature: signature, publicKey: key.publicKey.rawRepresentation),
              try !verify(data: original, signature: signature, publicKey: Curve25519.Signing.PrivateKey().publicKey.rawRepresentation) else {
            throw CocoaError(.fileReadCorruptFile)
        }
        print("Ed25519 valid/tampered/wrong-key boundary checks passed; updater install/relaunch remains a separate gate.")
    } else {
        guard CommandLine.arguments.count == 4,
              let signature = Data(base64Encoded: CommandLine.arguments[2]), signature.count == 64,
              let publicKey = Data(base64Encoded: CommandLine.arguments[3]), publicKey.count == 32 else {
            throw CocoaError(.fileReadCorruptFile)
        }
        let url = URL(fileURLWithPath: CommandLine.arguments[1])
        let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard size <= 512 * 1024 * 1024 else { throw CocoaError(.fileReadTooLarge) }
        guard try verify(data: Data(contentsOf: url, options: .mappedIfSafe), signature: signature, publicKey: publicKey) else {
            throw CocoaError(.fileReadCorruptFile)
        }
        print("Final archive Ed25519 signature matches the application's configured public key.")
    }
} catch {
    FileHandle.standardError.write(Data("Release signature verification failed. Check the archive, signature, and embedded public key.\n".utf8))
    exit(1)
}
