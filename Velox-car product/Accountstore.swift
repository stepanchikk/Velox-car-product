import Foundation
import Combine
import CommonCrypto
import Security
import UIKit

// Локальний профіль водія. Серверної частини немає (див. ТЗ), тому акаунт
// живе лише на цьому телефоні:
// - дані профілю (імʼя, email, автомобіль) - у UserDefaults;
// - пароль не зберігається: у Keychain лежать лише сіль і хеш PBKDF2-SHA256;
// - фото профілю - файл у Application Support.
// Поїздки (CSV у Documents) від профілю не залежать і при виході не зникають.

// MARK: - Профіль

nonisolated struct UserProfile: Codable, Equatable, Sendable {
    var name: String
    var email: String
    var car: String
    var createdAt: Date
}

// MARK: - Перевірка введених даних

nonisolated struct PasswordRequirement: Identifiable, Equatable, Sendable {
    let text: String
    let met: Bool
    var id: String { text }
}

nonisolated enum CredentialsValidator {
    static let minPasswordLength = 8
    private static let specialCharacters = CharacterSet(charactersIn: "!@#$%^&*()-_=+[]{}|;:'\",.<>/?`~\\")

    static func isValidEmail(_ email: String) -> Bool {
        let pattern = "[A-Z0-9a-z._%+-]+@[A-Za-z0-9.-]+\\.[A-Za-z]{2,64}"
        return email.range(of: "^\(pattern)$", options: .regularExpression) != nil
    }

    /// Вимоги до пароля і чи виконано кожну (для живого списку під полем)
    static func passwordRequirements(_ password: String) -> [PasswordRequirement] {
        [
            PasswordRequirement(text: "Щонайменше \(minPasswordLength) символів",
                                met: password.count >= minPasswordLength),
            PasswordRequirement(text: "Велика і мала літери",
                                met: password.rangeOfCharacter(from: .uppercaseLetters) != nil
                                    && password.rangeOfCharacter(from: .lowercaseLetters) != nil),
            PasswordRequirement(text: "Цифра",
                                met: password.rangeOfCharacter(from: .decimalDigits) != nil),
            PasswordRequirement(text: "Спецсимвол, наприклад ! або #",
                                met: password.rangeOfCharacter(from: specialCharacters) != nil),
        ]
    }

    static func isStrongPassword(_ password: String) -> Bool {
        passwordRequirements(password).allSatisfy { $0.met }
    }

    static func normalizedEmail(_ email: String) -> String {
        email.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    static func normalizedName(_ name: String) -> String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

// MARK: - Хешування пароля

nonisolated enum PasswordHasher {
    static let saltLength = 16
    static let hashLength = 32
    static let rounds: UInt32 = 120_000

    static func makeSalt() -> Data {
        var bytes = [UInt8](repeating: 0, count: saltLength)
        if SecRandomCopyBytes(kSecRandomDefault, saltLength, &bytes) != errSecSuccess {
            // Запасний варіант, якщо системний генератор недоступний
            bytes = (0..<saltLength).map { _ in UInt8.random(in: 0...255) }
        }
        return Data(bytes)
    }

    /// PBKDF2-SHA256: повільний за задумом, щоб перебір паролів був дорогим
    /// Порожній результат означає помилку (тоді verify завжди повертає false)
    static func hash(_ password: String, salt: Data, rounds: UInt32 = rounds) -> Data {
        guard !password.isEmpty, !salt.isEmpty else { return Data() }
        let passwordBytes = Array(password.utf8)
        let saltBytes = [UInt8](salt)
        var derived = [UInt8](repeating: 0, count: hashLength)
        let status = passwordBytes.withUnsafeBufferPointer { pw in
            pw.withMemoryRebound(to: CChar.self) { pwChars in
                CCKeyDerivationPBKDF(CCPBKDFAlgorithm(kCCPBKDF2),
                                     pwChars.baseAddress, passwordBytes.count,
                                     saltBytes, saltBytes.count,
                                     CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256), rounds,
                                     &derived, hashLength)
            }
        }
        guard status == kCCSuccess else { return Data() }
        return Data(derived)
    }

    /// Запис для Keychain: сіль + хеш
    static func makeCredential(_ password: String) -> Data {
        let salt = makeSalt()
        return salt + hash(password, salt: salt)
    }

    static func verify(_ password: String, credential: Data) -> Bool {
        guard credential.count == saltLength + hashLength else { return false }
        let salt = credential.prefix(saltLength)
        let expected = [UInt8](credential.suffix(hashLength))
        let actual = [UInt8](hash(password, salt: Data(salt)))
        guard actual.count == hashLength else { return false }
        // Порівняння за сталий час: не виходимо на першій розбіжності
        var difference: UInt8 = 0
        for i in 0..<hashLength {
            difference |= expected[i] ^ actual[i]
        }
        return difference == 0
    }
}

// MARK: - Keychain

nonisolated enum KeychainStore {
    private static let service = "Velox.credentials"

    @discardableResult
    static func save(_ data: Data, account: String) -> Bool {
        delete(account: account)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]
        return SecItemAdd(query as CFDictionary, nil) == errSecSuccess
    }

    static func load(account: String) -> Data? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess else { return nil }
        return result as? Data
    }

    static func delete(account: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)
    }
}

// MARK: - Сховище акаунта

@MainActor
final class AccountStore: ObservableObject {
    private static let profileKey = "velox.profile"
    private static let loggedInKey = "isLoggedIn"   // ключ попередніх версій
    private static let avatarFileName = "avatar.jpg"

    @Published private(set) var profile: UserProfile?
    @Published private(set) var isLoggedIn = false
    @Published private(set) var avatar: UIImage?

    private let defaults = UserDefaults.standard

    var hasProfile: Bool { profile != nil }

    init() {
        if let data = defaults.data(forKey: Self.profileKey) {
            profile = try? JSONDecoder().decode(UserProfile.self, from: data)
        }
        // Попередні версії пускали без профілю: такий вхід більше не дійсний
        isLoggedIn = defaults.bool(forKey: Self.loggedInKey) && profile != nil
        avatar = loadAvatar()
    }

    // MARK: Реєстрація і вхід

    /// Створює профіль на цьому телефоні (наявний профіль замінюється).
    /// Повертає список помилок; порожній список - успіх.
    func register(name: String, email: String, password: String, car: String) -> [String] {
        var errors: [String] = []
        let cleanName = CredentialsValidator.normalizedName(name)
        let cleanEmail = CredentialsValidator.normalizedEmail(email)
        if cleanName.isEmpty {
            errors.append("Вкажіть імʼя")
        }
        if !CredentialsValidator.isValidEmail(cleanEmail) {
            errors.append("Перевірте email: він має виглядати як name@mail.com")
        }
        if !CredentialsValidator.isStrongPassword(password) {
            errors.append("Пароль не відповідає вимогам нижче")
        }
        guard errors.isEmpty else { return errors }

        if let old = profile {
            KeychainStore.delete(account: old.email)
            removeAvatar()
        }
        guard KeychainStore.save(PasswordHasher.makeCredential(password), account: cleanEmail) else {
            return ["Не вдалося зберегти пароль у Keychain. Спробуйте ще раз."]
        }
        let newProfile = UserProfile(name: cleanName,
                                     email: cleanEmail,
                                     car: car.trimmingCharacters(in: .whitespacesAndNewlines),
                                     createdAt: Date())
        save(newProfile)
        setLoggedIn(true)
        return []
    }

    /// Повертає текст помилки або nil при успішному вході
    func login(email: String, password: String) -> String? {
        let cleanEmail = CredentialsValidator.normalizedEmail(email)
        guard let profile = profile, profile.email == cleanEmail else {
            return "На цьому телефоні немає профілю з таким email. Створіть акаунт."
        }
        guard !password.isEmpty else { return "Введіть пароль" }
        guard let credential = KeychainStore.load(account: cleanEmail) else {
            return "Дані входу не знайдено. Створіть акаунт заново: поїздки збережуться."
        }
        guard PasswordHasher.verify(password, credential: credential) else {
            return "Неправильний пароль"
        }
        setLoggedIn(true)
        return nil
    }

    func logout() {
        setLoggedIn(false)
    }

    // MARK: Редагування

    func updateProfile(name: String, car: String) {
        guard var current = profile else { return }
        let cleanName = CredentialsValidator.normalizedName(name)
        if !cleanName.isEmpty {
            current.name = cleanName
        }
        current.car = car.trimmingCharacters(in: .whitespacesAndNewlines)
        save(current)
    }

    /// Видаляє профіль, пароль і фото. Поїздки залишаються.
    func deleteProfile() {
        if let email = profile?.email {
            KeychainStore.delete(account: email)
        }
        removeAvatar()
        defaults.removeObject(forKey: Self.profileKey)
        profile = nil
        setLoggedIn(false)
    }

    // MARK: Фото профілю

    func setAvatar(from data: Data) {
        guard let image = UIImage(data: data) else { return }
        let resized = Self.downscaled(image, maxSide: 512)
        guard let jpeg = resized.jpegData(compressionQuality: 0.85), let url = avatarURL() else { return }
        do {
            try jpeg.write(to: url, options: .atomic)
            avatar = resized
        } catch {
            avatar = resized   // хоча б до перезапуску
        }
    }

    func removeAvatar() {
        if let url = avatarURL() {
            try? FileManager.default.removeItem(at: url)
        }
        avatar = nil
    }

    // MARK: Внутрішнє

    private func save(_ newProfile: UserProfile) {
        if let data = try? JSONEncoder().encode(newProfile) {
            defaults.set(data, forKey: Self.profileKey)
        }
        profile = newProfile
    }

    private func setLoggedIn(_ value: Bool) {
        isLoggedIn = value
        defaults.set(value, forKey: Self.loggedInKey)
    }

    private func avatarURL() -> URL? {
        guard let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            return nil
        }
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent(Self.avatarFileName)
    }

    private func loadAvatar() -> UIImage? {
        guard let url = avatarURL(), let data = try? Data(contentsOf: url) else { return nil }
        return UIImage(data: data)
    }

    private static func downscaled(_ image: UIImage, maxSide: CGFloat) -> UIImage {
        let side = max(image.size.width, image.size.height)
        guard side > maxSide else { return image }
        let scale = maxSide / side
        let size = CGSize(width: image.size.width * scale, height: image.size.height * scale)
        return UIGraphicsImageRenderer(size: size).image { _ in
            image.draw(in: CGRect(origin: .zero, size: size))
        }
    }
}
