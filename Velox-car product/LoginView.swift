import SwiftUI

// Вхід і створення локального профілю (див. AccountStore)
struct LoginView: View {
    @EnvironmentObject private var account: AccountStore

    private enum Mode: String, CaseIterable, Identifiable {
        case login = "Вхід"
        case register = "Новий профіль"
        var id: String { rawValue }
    }

    private enum Field: Hashable {
        case name, email, password, car
    }

    @State private var mode: Mode = .login
    @State private var name = ""
    @State private var email = ""
    @State private var password = ""
    @State private var car = ""
    @State private var errors: [String] = []
    @State private var confirmReplace = false
    @FocusState private var focused: Field?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                header

                Picker("Режим", selection: $mode) {
                    ForEach(Mode.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)

                VStack(spacing: 12) {
                    if mode == .register {
                        VeloxField(icon: "person", placeholder: "Імʼя", text: $name,
                                   focus: $focused, field: .name)
                            .textContentType(.givenName)
                            .submitLabel(.next)
                    }
                    VeloxField(icon: "envelope", placeholder: "Email", text: $email,
                               focus: $focused, field: .email)
                        .textContentType(.emailAddress)
                        .keyboardType(.emailAddress)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .submitLabel(.next)
                    VeloxField(icon: "lock", placeholder: "Пароль", text: $password,
                               focus: $focused, field: .password, isSecure: true)
                        .textContentType(mode == .register ? .newPassword : .password)
                        .submitLabel(mode == .register ? .next : .go)
                    if mode == .register {
                        VeloxField(icon: "car", placeholder: "Автомобіль, наприклад Toyota RAV4 (необовʼязково)",
                                   text: $car, focus: $focused, field: .car)
                            .submitLabel(.go)
                    }
                }
                .onSubmit(advanceFocus)

                if mode == .register {
                    passwordChecklist
                }

                if !errors.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(errors, id: \.self) { error in
                            Label(error, systemImage: "exclamationmark.circle.fill")
                                .font(.footnote)
                                .foregroundStyle(VeloxColor.danger)
                        }
                    }
                }

                Button(mode == .login ? "Увійти" : "Створити профіль", action: submit)
                    .buttonStyle(VeloxPrimaryButtonStyle())

                Text(mode == .login
                     ? "Профіль зберігається лише на цьому телефоні."
                     : "Профіль зберігається лише на цьому телефоні. Пароль не зберігається у відкритому вигляді, а поїздки нікуди не надсилаються.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            .padding(24)
            .frame(maxWidth: 520)
            .frame(maxWidth: .infinity)
        }
        .scrollDismissesKeyboard(.interactively)
        .background(VeloxColor.background.ignoresSafeArea())
        .onAppear {
            mode = account.hasProfile ? .login : .register
            email = account.profile?.email ?? ""
        }
        .onChange(of: mode) {
            errors.removeAll()
        }
        .confirmationDialog("Замінити профіль на цьому телефоні?",
                            isPresented: $confirmReplace,
                            titleVisibility: .visible) {
            Button("Замінити профіль", role: .destructive, action: register)
            Button("Скасувати", role: .cancel) { }
        } message: {
            Text("Профіль \(account.profile?.email ?? "") буде видалено. Записані поїздки залишаться.")
        }
    }

    // MARK: Частини екрана

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Velox")
                .font(.system(size: 56, weight: .heavy, design: .rounded))
                .italic()
                .foregroundStyle(VeloxColor.accent)
            Text(mode == .login ? "З поверненням. Увійдіть, щоб продовжити." : "Тренер безпечного водіння у вашому телефоні.")
                .font(.title3)
                .foregroundStyle(.secondary)
        }
        .padding(.top, 40)
    }

    private var passwordChecklist: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(CredentialsValidator.passwordRequirements(password)) { item in
                Label(item.text, systemImage: item.met ? "checkmark.circle.fill" : "circle")
                    .font(.footnote)
                    .foregroundStyle(item.met ? VeloxColor.safe : .secondary)
            }
        }
        .animation(.easeOut(duration: 0.15), value: password)
    }

    // MARK: Дії

    private func advanceFocus() {
        switch focused {
        case .name: focused = .email
        case .email: focused = .password
        case .password: if mode == .register { focused = .car } else { submit() }
        case .car, .none: submit()
        }
    }

    private func submit() {
        errors.removeAll()
        switch mode {
        case .login:
            if let error = account.login(email: email, password: password) {
                errors = [error]
            }
        case .register:
            // Інший email: наявний профіль буде замінено, тож питаємо
            if let existing = account.profile?.email,
               existing != CredentialsValidator.normalizedEmail(email) {
                confirmReplace = true
            } else {
                register()
            }
        }
    }

    private func register() {
        errors = account.register(name: name, email: email, password: password, car: car)
        if errors.isEmpty {
            password = ""
        }
    }
}

// MARK: - Поле введення

struct VeloxField<Field: Hashable>: View {
    let icon: String
    let placeholder: String
    @Binding var text: String
    // Фокус задається на самому полі введення, а не на обгортці
    var focus: FocusState<Field?>.Binding
    let field: Field
    var isSecure = false

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .foregroundStyle(.secondary)
                .frame(width: 20)
            Group {
                if isSecure {
                    SecureField(placeholder, text: $text)
                        .focused(focus, equals: field)
                } else {
                    TextField(placeholder, text: $text)
                        .focused(focus, equals: field)
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 15)
        .background(VeloxColor.panel, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(VeloxColor.hairline, lineWidth: 1)
        )
    }
}
