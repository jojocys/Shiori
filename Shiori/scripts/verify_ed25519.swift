import CryptoKit
import Foundation

// Public-key-only verification: never consults the publishing machine's Keychain.
do {
    guard CommandLine.arguments.count == 4,
          let key = Data(base64Encoded: CommandLine.arguments[1]), key.count == 32,
          let signature = Data(base64Encoded: CommandLine.arguments[2]), signature.count == 64 else {
        throw NSError(domain: "ShioriRelease", code: 1, userInfo: [NSLocalizedDescriptionKey: "Invalid Ed25519 key/signature encoding"])
    }
    let publicKey = try Curve25519.Signing.PublicKey(rawRepresentation: key)
    let archive = try Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[3]), options: .mappedIfSafe)
    guard publicKey.isValidSignature(signature, for: archive) else {
        throw NSError(domain: "ShioriRelease", code: 2, userInfo: [NSLocalizedDescriptionKey: "Ed25519 signature does not match the embedded public key and archive bytes"])
    }
    print("Ed25519 verification passed")
} catch {
    fputs("\(error.localizedDescription)\n", stderr)
    exit(1)
}
