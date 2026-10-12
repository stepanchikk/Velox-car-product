"""Розбір колонки Event: калібрування, відволікання, дзвінки."""

# Службові рядки нових версій: повторюють останні значення, вимірами не є
SERVICE_EVENTS = ("DistractionEnd", "DistractionResume", "CallIncoming", "CallStart",
                  "CallStart_Handheld", "CallEnd")
CALL_START_EVENTS = ("CallIncoming", "CallStart", "CallStart_Handheld")


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
