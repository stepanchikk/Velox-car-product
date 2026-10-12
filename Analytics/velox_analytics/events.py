"""Розбір колонки Event: калібрування, відволікання, дзвінки."""

# Службові рядки нових версій: повторюють останні значення, вимірами не є
SERVICE_EVENTS = ("DistractionEnd", "DistractionResume", "CallIncoming", "CallStart",
                  "CallStart_Handheld", "CallEnd")
CALL_START_EVENTS = ("CallIncoming", "CallStart", "CallStart_Handheld")

# Зрозумілі назви подій для звіту
EVENT_LABELS = {
    "CalibrationStart": "Початок калібрування",
    "CalibrationStart_Auto": "Перекалібрування: змінилось положення телефона",
    "CalibrationStart_Retry": "Повтор невдалого перекалібрування",
    "CalibrationForwardStart": "Калібрування: визначення напряму руху за GPS",
    "CalibrationDone": "Калібрування завершено (GPS)",
    "CalibrationDoneFallback": "Калібрування без GPS (припущення про кріплення)",
    "CalibrationFailed": "Калібрування не вдалося",
    "CalibrationDirectionFix": "Напрям руху виправлено за поворотами",
    "CalibrationDirectionConfirmed": "Напрям руху підтверджено за поворотами",
    "HardBraking": "Різке гальмування",
    "HardAcceleration": "Різкий розгін",
    "Distraction": "Відволікання: телефон у руках",
    "DistractionResume": "Відволікання продовжилось",
    "DistractionEnd": "Водій повернувся до застосунку",
    "CallIncoming": "Вхідний дзвінок",
    "CallStart": "Розмова без рук (гучний звʼязок, гарнітура, CarPlay)",
    "CallStart_Handheld": "Розмова з телефоном біля вуха",
    "CallEnd": "Дзвінок завершено",
}


def calibration_windows(timestamps, events):
    """Проміжки без запису: від CalibrationStart* до наступного CalibrationDone*.

    Невдале перекалібрування в русі (CalibrationFailed, потім CalibrationStart_Retry)
    входить в один проміжок, бо весь цей час виміри не записувались."""
    windows = []
    start = None
    for ts, ev in zip(timestamps, events):
        if ev.startswith("CalibrationStart") and start is None:
            start = ts
        elif ev.startswith("CalibrationDone") and start is not None:
            windows.append((float(start), float(ts)))
            start = None
    return windows


def distraction_episodes(events):
    """Відволікання з тривалістю.

    Distraction починає нове відволікання, DistractionResume продовжує попереднє
    (водій повернувся і знову вийшов за паузу), DistractionEnd закриває шматок.
    events - таблиця з колонками Timestamp і Event. Повертає список епізодів,
    кожен - список інтервалів (початок, кінець)."""
    episodes, opened = [], None
    for ts, ev in zip(events["Timestamp"], events["Event"]):
        if ev == "Distraction":
            episodes.append([])
            opened = float(ts)
        elif ev == "DistractionResume" and episodes:
            opened = float(ts)
        elif ev == "DistractionEnd" and opened is not None and episodes:
            episodes[-1].append((opened, float(ts)))
            opened = None
    return episodes


def episode_seconds(episodes):
    """Тривалість кожного епізоду, с."""
    return [sum(end - begin for begin, end in episode) for episode in episodes]


def distractions_at_call_start(events, grace):
    """Відволікання, що почались менше ніж через grace с після початку розмови
    без рук. Застосунок до виправлення 12.10.2026 штрафував так дзвінки через
    CarPlay: екран розмови відкривала система, а не водій. Повертає список
    (час відволікання, через скільки секунд після CallStart)."""
    found, call_started = [], None
    for ts, ev in zip(events["Timestamp"], events["Event"]):
        if ev == "CallStart":
            call_started = float(ts)
        elif ev == "CallEnd":
            call_started = None
        elif ev == "Distraction" and call_started is not None and float(ts) - call_started < grace:
            found.append((float(ts), float(ts) - call_started))
    return found


def count_calls(events):
    """Кількість дзвінків: від CallIncoming або CallStart* до CallEnd - один дзвінок."""
    count, open_call = 0, False
    for ev in events:
        if ev in CALL_START_EVENTS:
            if not open_call:
                count += 1
                open_call = True
        elif ev == "CallEnd":
            open_call = False
    return count
