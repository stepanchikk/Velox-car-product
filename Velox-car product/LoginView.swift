import SwiftUI

struct LoginView: View {
    @AppStorage("isLoggedIn") var isLoggedIn: Bool = false
    
    @State private var isRegistrationMode = false
    @State private var email = ""
    @State private var password = ""
    
    // масив, який може зберігати декілька помилок одночасно
    @State private var errorMessages: [String] = []
    
    var body: some View {
        VStack(spacing: 20) {
            Text("Velox")
                .font(.system(size: 48, weight: .bold, design: .rounded))
                .foregroundColor(.blue)
                .padding(.bottom, 10)
            
            Text(isRegistrationMode ? "Створення акаунту" : "Вхід у систему")
                .font(.title2)
                .bold()
                .padding(.bottom, 10)
            
            TextField("Email", text: $email)
                .textFieldStyle(RoundedBorderTextFieldStyle())
                .keyboardType(.emailAddress)
                .autocapitalization(.none)
                .onChange(of: email) { errorMessages.removeAll() }
            
            SecureField("Пароль", text: $password)
                .textFieldStyle(RoundedBorderTextFieldStyle())
                .onChange(of: password) { errorMessages.removeAll() }
            
            // Якщо є помилки, виводимо їх списком
            if !errorMessages.isEmpty {
                VStack(alignment: .leading, spacing: 5) {
                    ForEach(errorMessages, id: \.self) { error in
                        Text("• \(error)")
                            .foregroundColor(.red)
                            .font(.footnote)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 10)
            }
            
            Button(action: handleAction) {
                Text(isRegistrationMode ? "Зареєструватися" : "Увійти")
                    .font(.headline)
                    .foregroundColor(.white)
                    .frame(maxWidth: .infinity)
                    .padding()
                    .background(Color.blue)
                    .cornerRadius(12)
            }
            .padding(.top, 10)
            
            Button(action: {
                withAnimation {
                    isRegistrationMode.toggle()
                    errorMessages.removeAll() // Очищаємо екран при зміні режиму
                }
            }) {
                Text(isRegistrationMode ? "Вже є акаунт? Увійти" : "Немає акаунту? Створити")
                    .foregroundColor(.blue)
                    .font(.callout)
            }
            
            Spacer()
        }
        .padding(30)
    }
    
    private func handleAction() {
        // Очищаємо старі помилки перед новою перевіркою
        errorMessages.removeAll()
        
        // 1. Валідація пошти
        if !isValidEmail(email) {
            errorMessages.append("Некоректний формат email (name@mail.com)")
        }
        
        // 2. Валідація пароля
        if isRegistrationMode {
            // Додаємо всі знайдені помилки пароля до загального списку
            let passwordErrors = validatePassword(password)
            errorMessages.append(contentsOf: passwordErrors)
        } else {
            if password.isEmpty {
                errorMessages.append("Будь ласка, введіть пароль")
            }
        }
        
        // 3. Якщо масив помилок порожній, значить усе ідеально
        if errorMessages.isEmpty {
            withAnimation {
                isLoggedIn = true
            }
        }
    }
    
    private func isValidEmail(_ email: String) -> Bool {
        let emailFormat = "[A-Z0-9a-z._%+-]+@[A-Za-z0-9.-]+\\.[A-Za-z]{2,64}"
        let emailPredicate = NSPredicate(format:"SELF MATCHES %@", emailFormat)
        return emailPredicate.evaluate(with: email)
    }
    
    // Аналізатор повертає список усіх знайдених недоліків
    private func validatePassword(_ pass: String) -> [String] {
        var errors: [String] = []
        
        if pass.count < 8 {
            errors.append("Мінімум 8 символів")
        }
        if pass.rangeOfCharacter(from: .uppercaseLetters) == nil {
            errors.append("Хоча б одна велика літера (A-Z)")
        }
        if pass.rangeOfCharacter(from: .lowercaseLetters) == nil {
            errors.append("Хоча б одна мала літера (a-z)")
        }
        if pass.rangeOfCharacter(from: .decimalDigits) == nil {
            errors.append("Хоча б одна цифра (0-9)")
        }
        if pass.rangeOfCharacter(from: CharacterSet(charactersIn: "!@#$%^&*()-_=+[]{}|;:'\",.<>/?`~")) == nil {
            errors.append("Хоча б один спецсимвол (!@#$тощо)")
        }
        
        return errors
    }
}
