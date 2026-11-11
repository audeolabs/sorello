// Signs one file with the update key and prints the signature in base64, as an appcast carries it
// (ARCHITECTURE.md, section 6, "Updates"). scripts/write-appcast.sh runs it.
//   swift sign-update.swift <key file> <public key> <file>
// <key file> holds the private half of the key: its 32-byte seed in base64. <public key> is the half an app
// carries, in base64. Nothing is signed with a key whose public half is not that one: an update signed with any
// other key is an update no installed app accepts.
import CryptoKit
import Foundation

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("sign-update: \(message)\n".utf8))
    exit(1)
}

let arguments = CommandLine.arguments
guard arguments.count == 4 else { fail("usage: sign-update.swift <key file> <public key> <file>") }
guard let text = try? String(contentsOfFile: arguments[1], encoding: .utf8),
      let seed = Data(base64Encoded: text.trimmingCharacters(in: .whitespacesAndNewlines)), seed.count == 32,
      let key = try? Curve25519.Signing.PrivateKey(rawRepresentation: seed) else {
    fail("the key file does not hold a 32-byte seed in base64")
}
guard key.publicKey.rawRepresentation.base64EncodedString() == arguments[2] else {
    fail("the key is not the one the app checks its updates against")
}
guard let file = try? Data(contentsOf: URL(fileURLWithPath: arguments[3]), options: .mappedIfSafe) else {
    fail("cannot read \(arguments[3])")
}
guard let signature = try? key.signature(for: file), key.publicKey.isValidSignature(signature, for: file) else {
    fail("the file could not be signed")
}
print(signature.base64EncodedString())
