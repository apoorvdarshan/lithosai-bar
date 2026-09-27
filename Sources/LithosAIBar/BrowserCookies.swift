import Foundation
import SQLite3
import CommonCrypto
import Security

/// Reads Chromium-family cookies for the LithosAI console out of the on-disk
/// cookie store. This intentionally does no network work and never writes to
/// the browser profile: it copies the SQLite file first because the browser
/// holds a lock on the live database.
///
/// Chromium derives the AES key from a Keychain-held password via PBKDF2, then
/// encrypts each value with AES-128-CBC. Modern builds prefix the plaintext with
/// a SHA-256 host hash, which we strip before decoding the cookie value.
enum Browser {
    struct Profile {
        let name: String
        let appSupportDir: String
        let safeStorageService: String
        let safeStorageAccount: String
    }

    /// Browsers in the order we try them. Brave first because that is the one in
    /// active use here; Chrome and the rest follow.
    static let profiles: [Profile] = [
        Profile(
            name: "Brave",
            appSupportDir: "BraveSoftware/Brave-Browser",
            safeStorageService: "Brave Safe Storage",
            safeStorageAccount: "Brave"
        ),
        Profile(
            name: "Chrome",
            appSupportDir: "Google/Chrome",
            safeStorageService: "Chrome Safe Storage",
            safeStorageAccount: "Chrome"
        ),
        Profile(
            name: "Edge",
            appSupportDir: "Microsoft Edge",
            safeStorageService: "Microsoft Edge Safe Storage",
            safeStorageAccount: "Microsoft Edge"
        ),
        Profile(
            name: "Chromium",
            appSupportDir: "Chromium",
            safeStorageService: "Chromium Safe Storage",
            safeStorageAccount: "Chromium"
        ),
        Profile(
            name: "Vivaldi",
            appSupportDir: "Vivaldi",
            safeStorageService: "Vivaldi Safe Storage",
            safeStorageAccount: "Vivaldi"
        ),
    ]

    struct CookieJar {
        let csrf: String
        let session: String
        let browserName: String
    }

    enum CookieError: LocalizedError {
        case noDatabase(String)
        case keychainFailed(String, OSStatus)
        case noCookies(String)
        case decryptFailed
        case allBrowsersFailed([String])

        var errorDescription: String? {
            switch self {
            case .noDatabase(let b):
                return "No \(b) cookie database found."
            case .keychainFailed(let b, let s):
                return "Could not read the \(b) Safe Storage key from Keychain (status \(s))."
            case .noCookies(let b):
                return "No LithosAI console session in \(b)."
            case .decryptFailed:
                return "Could not decrypt the browser session cookie."
            case .allBrowsersFailed(let failures):
                return "No LithosAI console session found. "
                    + failures.joined(separator: " | ")
            }
        }
    }

    /// Loads the console cookies from the first browser that has them.
    static func loadConsoleCookies() throws -> CookieJar {
        var failures: [String] = []
        for profile in profiles {
            do {
                return try loadConsoleCookies(from: profile)
            } catch {
                failures.append("\(profile.name): \(error.localizedDescription)")
                continue
            }
        }
        throw CookieError.allBrowsersFailed(failures)
    }

    static func loadConsoleCookies(from profile: Profile) throws -> CookieJar {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let base = home
            .appendingPathComponent("Library/Application Support", isDirectory: true)
            .appendingPathComponent(profile.appSupportDir, isDirectory: true)

        // Chromium can have several profiles; "Default" is the common one.
        let candidates = ["Default", "Profile 1", "Profile 2", "Profile 3"]
        guard let dbURL = candidates
            .map({ base.appendingPathComponent($0, isDirectory: true).appendingPathComponent("Cookies") })
            .first(where: { FileManager.default.fileExists(atPath: $0.path) })
        else {
            throw CookieError.noDatabase(profile.name)
        }

        let key = try safeStorageKey(for: profile)
        return try readCookies(from: dbURL, key: key, browserName: profile.name)
    }

    // MARK: - Keychain

    private static func safeStorageKey(for profile: Profile) throws -> Data {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: profile.safeStorageService,
            kSecAttrAccount as String: profile.safeStorageAccount,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess, let password = item as? Data else {
            throw CookieError.keychainFailed(profile.name, status)
        }
        return deriveKey(from: password)
    }

    /// Chromium: PBKDF2-HMAC-SHA1, salt "saltysalt", 1003 iterations, 16-byte key.
    private static func deriveKey(from password: Data) -> Data {
        var derived = [UInt8](repeating: 0, count: 16)
        let salt = [UInt8]("saltysalt".utf8)
        password.withUnsafeBytes { pwBytes in
            salt.withUnsafeBytes { saltBytes in
                _ = CCKeyDerivationPBKDF(
                    CCPBKDFAlgorithm(kCCPBKDF2),
                    pwBytes.bindMemory(to: Int8.self).baseAddress, password.count,
                    saltBytes.bindMemory(to: UInt8.self).baseAddress, salt.count,
                    CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA1),
                    1003,
                    &derived, derived.count
                )
            }
        }
        return Data(derived)
    }

    // MARK: - Decryption

    /// AES-128-CBC with a fixed 16-space IV, as Chromium uses.
    private static func decrypt(_ encrypted: Data, key: Data) -> Data? {
        var payload = encrypted
        if payload.count > 3, payload.prefix(3) == Data("v10".utf8) || payload.prefix(3) == Data("v11".utf8) {
            payload = payload.dropFirst(3)
        }
        guard !payload.isEmpty, payload.count % 16 == 0 else { return nil }

        let iv = [UInt8](repeating: 0x20, count: 16)
        var out = [UInt8](repeating: 0, count: payload.count + kCCBlockSizeAES128)
        var moved = 0

        let status = key.withUnsafeBytes { keyBytes in
            iv.withUnsafeBytes { ivBytes in
                payload.withUnsafeBytes { dataBytes in
                    CCCrypt(
                        CCOperation(kCCDecrypt),
                        CCAlgorithm(kCCAlgorithmAES),
                        CCOptions(kCCOptionPKCS7Padding),
                        keyBytes.baseAddress, key.count,
                        ivBytes.baseAddress,
                        dataBytes.baseAddress, payload.count,
                        &out, out.count,
                        &moved
                    )
                }
            }
        }
        guard status == kCCSuccess else { return nil }
        var plain = Data(out.prefix(moved))

        // Modern Chromium prefixes a 32-byte SHA-256 hash of the host key.
        if plain.count > 32, looksLikeHostHash(plain.prefix(32)) {
            plain = plain.dropFirst(32)
        }
        return plain
    }

    /// A host hash is opaque bytes; real cookie values are printable ASCII.
    /// Treat a 32-byte prefix as a host hash only when the remainder is clean.
    private static func looksLikeHostHash(_ prefix: Data) -> Bool {
        // Any non-printable byte in the prefix suggests it is a hash rather than text.
        for byte in prefix where byte < 0x20 || byte > 0x7E {
            return true
        }
        return false
    }

    // MARK: - Reading rows

    private static let sessionNames = ["__Host-console_session", "console_session"]
    private static let csrfNames = ["__Host-console_csrf", "console_csrf"]

    private static func readCookies(
        from database: URL,
        key: Data,
        browserName: String
    ) throws -> CookieJar {
        // The browser may hold a write lock, and the app process may not be
        // permitted to copy the file. SQLite can read it in place if we open it
        // immutable + read-only, which skips locking entirely.
        var db: OpaquePointer?
        let uri = "file:\(database.path)?immutable=1"
        let flags = SQLITE_OPEN_READONLY | SQLITE_OPEN_URI
        guard sqlite3_open_v2(uri, &db, flags, nil) == SQLITE_OK else {
            let message = String(cString: sqlite3_errmsg(db))
            sqlite3_close(db)
            Log.write("\(browserName): sqlite open failed: \(message)")
            throw CookieError.noCookies(browserName)
        }
        defer { sqlite3_close(db) }

        let sql = """
        SELECT host_key, name, encrypted_value, value
        FROM cookies
        WHERE host_key IN ('console.lithosai.cloud', '.console.lithosai.cloud', 'lithosai.cloud', '.lithosai.cloud')
        """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            throw CookieError.noCookies(browserName)
        }
        defer { sqlite3_finalize(statement) }

        var session: String?
        var csrf: String?

        let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

        while sqlite3_step(statement) == SQLITE_ROW {
            guard let nameC = sqlite3_column_text(statement, 1) else { continue }
            let name = String(cString: nameC)

            var value: String?
            if sqlite3_column_type(statement, 2) == SQLITE_BLOB,
               let blob = sqlite3_column_blob(statement, 2)
            {
                let length = Int(sqlite3_column_bytes(statement, 2))
                let encrypted = Data(bytes: blob, count: length)
                if let plain = decrypt(encrypted, key: key) {
                    value = String(data: plain, encoding: .utf8)
                }
            }
            if value == nil, let textC = sqlite3_column_text(statement, 3) {
                let text = String(cString: textC)
                if !text.isEmpty { value = text }
            }
            guard let resolved = value, !resolved.isEmpty else { continue }

            if sessionNames.contains(name) { session = resolved }
            if csrfNames.contains(name) { csrf = resolved }
        }

        _ = SQLITE_TRANSIENT

        guard let sessionValue = session else { throw CookieError.noCookies(browserName) }
        return CookieJar(
            csrf: csrf ?? "",
            session: sessionValue,
            browserName: browserName
        )
    }
}