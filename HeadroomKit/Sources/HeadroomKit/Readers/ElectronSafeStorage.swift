import CommonCrypto
import Foundation
import Security

/// Decrypts Electron `safeStorage` blobs ("v10" + AES-128-CBC) on macOS. Claude
/// desktop and Cursor both keep their OAuth tokens this way, keyed by a password
/// in the "<App> Safe Storage" keychain item. Reading that item shows a one-time
/// macOS prompt ("Always Allow").
public enum ElectronSafeStorage {
    private static let lock = NSLock()
    private nonisolated(unsafe) static var keys: [String: Data] = [:]

    public static func decrypt(_ blob: Data, keychainService: String) -> Data? {
        guard blob.starts(with: Data("v10".utf8)), let key = key(for: keychainService) else { return nil }
        return aes128CBCDecrypt(blob.dropFirst(3), key: key)
    }

    static func aes128CBCDecrypt(_ ciphertext: Data, key: Data) -> Data? {
        let iv = Data(repeating: 0x20, count: kCCBlockSizeAES128) // 16 spaces
        var out = Data(count: ciphertext.count + kCCBlockSizeAES128)
        var outLength = 0
        let outCapacity = out.count
        let status = out.withUnsafeMutableBytes { o in
            ciphertext.withUnsafeBytes { c in
                key.withUnsafeBytes { k in
                    iv.withUnsafeBytes { i in
                        CCCrypt(CCOperation(kCCDecrypt), CCAlgorithm(kCCAlgorithmAES), CCOptions(kCCOptionPKCS7Padding),
                                k.baseAddress, key.count, i.baseAddress,
                                c.baseAddress, ciphertext.count,
                                o.baseAddress, outCapacity, &outLength)
                    }
                }
            }
        }
        guard status == kCCSuccess else { return nil }
        return out.prefix(outLength)
    }

    static func deriveKey(password: Data) -> Data? {
        let salt = Data("saltysalt".utf8)
        var key = Data(count: kCCKeySizeAES128)
        let status = key.withUnsafeMutableBytes { k in
            password.withUnsafeBytes { p in
                salt.withUnsafeBytes { s in
                    CCKeyDerivationPBKDF(CCPBKDFAlgorithm(kCCPBKDF2),
                                         p.baseAddress?.assumingMemoryBound(to: Int8.self), password.count,
                                         s.baseAddress?.assumingMemoryBound(to: UInt8.self), salt.count,
                                         CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA1), 1003,
                                         k.baseAddress?.assumingMemoryBound(to: UInt8.self), kCCKeySizeAES128)
                }
            }
        }
        return status == kCCSuccess ? key : nil
    }

    /// Derived key, cached for the process lifetime so the keychain is read once.
    private static func key(for service: String) -> Data? {
        lock.lock()
        defer { lock.unlock() }
        if let cached = keys[service] { return cached.isEmpty ? nil : cached }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecUserCanceled || status == errSecAuthFailed {
            keys[service] = Data() // denied: don't re-prompt until relaunch
            return nil
        }
        guard status == errSecSuccess,
              let password = result as? Data,
              let key = deriveKey(password: password)
        else { return nil }
        keys[service] = key
        return key
    }
}
