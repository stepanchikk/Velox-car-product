"""Velox: аналітика телеметрії поїздок.

Модулі (від даних до звіту):
    config      параметри з VeloxConfig.swift і з рядків "#" CSV (AppConfig)
    loader      читання CSV усіх версій формату в обʼєкт Trip
    trip        Trip і Imu: дані поїздки в памʼяті
    events      розбір колонки Event: калібрування, відволікання, дзвінки
    filtering   Low-Pass фільтр, відновлення сирого сигналу, детектор маневрів
    scoring     Safety Score, клас безпеки, оцінка водія
    checks      перевірка калібрування за GPS і напряму за поворотами, відстань
    summary     таблиця summary.csv, узгодженість логів, чутливість до порога
    plots       графіки: trip_plots (окрема поїздка), overview (усі поїздки)
    cli         командний рядок

Модулі config, events, filtering і scoring не залежать від pandas-таблиць
і matplotlib, тому їх перевіряють юніт-тести (каталог tests).
"""

__version__ = "2.0"
