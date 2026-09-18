import pandas as pd
import matplotlib.pyplot as plt

# Вкажи точну назву свого файлу
file_name = 'Velox_2026-09-14_11-44-48.csv'

try:
    df = pd.read_csv(file_name)
    df['Timestamp'] = df['Timestamp'] - df['Timestamp'].iloc[0]

    # МАТЕМАТИЧНА ФІЛЬТРАЦІЯ
    # Створюємо вікно розміром 10 значень (це рівно 1 секунда реального часу)
    window_size = 20

    # Створюємо нову колонку зі згладженими даними
    df['Y_smooth'] = df['Y'].rolling(window=window_size).mean()

    plt.figure(figsize=(14, 7))

    # Сирі дані (малюємо блідо-червоним, щоб вони були на фоні)
    plt.plot(df['Timestamp'], df['Y'], label='Сирі дані Y (Шум і вібрації)', color='red', alpha=0.3)

    # Згладжені дані (малюємо жирним синім, це наш чистий рух)
    plt.plot(df['Timestamp'], df['Y_smooth'], label='Відфільтрована вісь Y (Реальне гальмування)', color='blue',
             linewidth=3)

    plt.title('Аналіз фільтрації шумів: Ковзне середнє (1 секунда)', fontsize=16)
    plt.xlabel('Час (секунди)', fontsize=12)
    plt.ylabel('Перевантаження (G-force)', fontsize=12)
    plt.grid(True, linestyle='--', alpha=0.6)
    plt.legend(loc='upper right')

    plt.tight_layout()
    plt.show()

except FileNotFoundError:
    print(f"Помилка: Файл '{file_name}' не знайдено.")