import Foundation

// Єдине джерело параметрів алгоритмів Velox.
//
// Цей файл читає і застосунок, і скрипт analyzer.py: скрипт знаходить його
// поруч із собою або в каталозі проєкту і бере значення звідси, тому змінювати
// параметри треба лише тут.
//
// Формат рядків для analyzer.py: `static let імʼя: Тип = число`
// (одне значення в рядку, без формул).
nonisolated enum VeloxConfig {

    // MARK: Збір даних

    // Інтервал оновлення CoreMotion, с (10 Гц)
    static let sampleInterval: TimeInterval = 0.1

    // MARK: Фільтрація

    // Коефіцієнт Low-Pass фільтра: y[n] = alpha * x[n] + (1 - alpha) * y[n-1]
    static let filterAlpha: Double = 0.2

    // MARK: Маневри

    // Поріг відфільтрованого поздовжнього прискорення, G
    static let maneuverThreshold: Double = 0.4
    // Пауза між двома маневрами одного типу, с
    static let maneuverCooldown: TimeInterval = 3.0

    // MARK: Anti-Fraud

    // Скільки секунд після старту ігнорувати втрату активності застосунку
    static let distractionGracePeriod: TimeInterval = 3.0
    // Мінімальний інтервал між двома штрафами за відволікання, с
    static let distractionCooldown: TimeInterval = 1.5
    // Тривале відволікання: додатковий штраф за кожні distractionDurationStep секунд
    // з телефоном у руках, але не більше distractionDurationPenaltyMax за одне відволікання
    static let distractionDurationStep: TimeInterval = 10.0
    static let distractionDurationPenalty: Int = 1
    static let distractionDurationPenaltyMax: Int = 5

    // MARK: Safety Score

    // Штраф за кожен маневр і кожне відволікання, бали
    static let maneuverPenalty: Int = 2
    static let distractionPenalty: Int = 5
    // Нижні межі класів: від safeScoreMin - безпечний, від mediumScoreMin - середній
    static let safeScoreMin: Int = 90
    static let mediumScoreMin: Int = 75

    // MARK: Оцінка водія (за останні поїздки)

    // Оцінка окремої поїздки - це 100 мінус штрафи, тому довга поїздка майже
    // завжди нижча за коротку. Оцінка водія порівнює чесніше: штрафи останніх
    // поїздок перераховуються на ratingDistanceKm кілометрів їзди.
    static let ratingDistanceKm: Double = 10.0
    // Поїздки без GPS: відстань оцінюється за тривалістю з цією швидкістю, км/год
    static let ratingFallbackSpeedKmh: Double = 30.0

    // MARK: Маршрут

    // Координати з точністю гірше за цю (м) у файл не пишуться
    static let routeMaxHorizontalAccuracy: Double = 50.0

    // MARK: Перекалібрування

    // Автоматичне: нахил телефона змінився більше ніж на кут і тримається довше за час
    static let recalibrationAngle: Double = 30.0
    static let recalibrationHold: TimeInterval = 2.0
    // Ручне: дозволене лише коли швидкість менша за цю, м/с (~7 км/год)
    static let manualRecalibrationMaxSpeed: Double = 2.0
    // Невдале перекалібрування під час поїздки повторюється через цей час, с
    static let recalibrationRetryDelay: TimeInterval = 5.0
}
