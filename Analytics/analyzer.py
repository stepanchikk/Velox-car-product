import pandas as pd
import matplotlib.pyplot as plt
import glob
import os

csv_files = glob.glob("*.csv")

if not csv_files:
    print("CSV файли не знайдені. Переконайтеся, що вони лежать у тій самій папці, що й скрипт.")
else:
    plt.figure(figsize=(14, 7))

    colors = ['blue', 'green', 'orange', 'purple', 'red']

    print("--- Результати аналізу заїздів ---")

    for i, file_path in enumerate(csv_files):
        df = pd.read_csv(file_path)

        # Нормалізуємо час (щоб усі графіки починалися з 0 секунд)
        df['Time_Normalized'] = df['Timestamp'] - df['Timestamp'].iloc[0]

        color = colors[i % len(colors)]
        file_name = os.path.basename(file_path)

        # лінія для відфільтрованих даних
        plt.plot(df['Time_Normalized'], df['Filtered_Y'], label=f'{file_name}', color=color, linewidth=2)

        #максимальне і мінімальне значення
        max_accel = df['Filtered_Y'].max()
        max_brake = df['Filtered_Y'].min()
        print(f"Файл: {file_name}")
        print(f"  -> Макс. розгін: {max_accel:.3f} G")
        print(f"  -> Макс. гальмування (модуль): {abs(max_brake):.3f} G\n")

    plt.title('Порівняння тестових заїздів: Вісь Y (Відфільтровані дані)')
    plt.xlabel('Час від початку заїзду (секунди)')
    plt.ylabel('Перевантаження (G)')
    plt.legend()
    plt.grid(True)

    # орієнтовні червоні лінії на 0.4 та -0.4 для наочності
    plt.axhline(y=0.4, color='red', linestyle='--', alpha=0.5, label='Орієнтовний поріг')
    plt.axhline(y=-0.4, color='red', linestyle='--', alpha=0.5)

    plt.show()
