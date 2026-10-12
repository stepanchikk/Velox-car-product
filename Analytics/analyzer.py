"""
Velox: аналітика телеметрії поїздок.

Для кожного CSV з застосунку скрипт будує графіки (сирий і відфільтрований
сигнал, вплив коефіцієнта фільтра, динаміка Safety Score, перевірка
калібрування за GPS, маршрут), а для всіх файлів разом - чутливість детекції
до порога, розподіл прискорень і таблицю summary.csv. Події і Safety Score
кожного файлу перераховуються і звіряються із записаними застосунком.

Використання:
    python analyzer.py                   # CSV беруться з каталогу, де лежить скрипт
    python analyzer.py шлях/до/каталогу  # CSV з іншого каталогу
    python analyzer.py --show            # додатково показати вікна графіків
    python analyzer.py --config шлях/до/VeloxConfig.swift   # явно вказати параметри

Параметри алгоритмів скрипт бере з VeloxConfig.swift проєкту (поруч зі
скриптом або на два рівні вгору), а для поїздки з рядками "# ключ=значення" -
з самого файлу, тож старі поїздки перевіряються з тими параметрами, з якими
їх записано. Результати зберігаються в підкаталог figures/.

Код розбито на модулі пакета velox_analytics (опис - у velox_analytics/__init__.py).
Юніт-тести: python -m unittest discover tests

Залежності: pip install pandas matplotlib numpy
"""

import os

from velox_analytics.cli import main

if __name__ == "__main__":
    main(script_dir=os.path.dirname(os.path.abspath(__file__)))
