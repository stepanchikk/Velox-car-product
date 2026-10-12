"""Читання CSV поїздки (усі версії формату) у обʼєкт Trip.

Формат 3: рядки "# ключ=значення", далі колонки Timestamp, Filtered_Y, State,
Event, Raw_Y, Ax, Ay, Az, Gx, Gy, Gz, Tilt_deg, Score, Speed_mps, Lat, Lon.
Старіші файли мають лише частину колонок, і кожна перевірка, якій бракує
даних, просто пропускається.
"""

import os

import numpy as np
import pandas as pd

from .events import SERVICE_EVENTS, calibration_windows
from .filtering import reconstruct_raw
from .trip import Imu, Trip

IMU_COLUMNS = ["Ax", "Ay", "Az", "Gx", "Gy", "Gz"]


def read_metadata(path):
    """Рядки "# ключ=значення" на початку файлу. Повертає (словник, кількість рядків)."""
    metadata = {}
    count = 0
    with open(path, encoding="utf-8-sig") as f:
        for line in f:
            if not line.startswith("#"):
                break
            count += 1
            key, sep, value = line[1:].strip().partition("=")
            if sep and key.strip():
                metadata[key.strip()] = value.strip()
    return metadata, count


def load_trip(path, config):
    """Читає CSV поїздки. config - поточні параметри (AppConfig) на випадок,
    якщо у файлі немає власних. Повертає Trip або None, якщо файл не підходить."""
    name = os.path.basename(path)
    try:
        metadata, n_meta = read_metadata(path)
        df = pd.read_csv(path, skiprows=n_meta)
    except Exception as e:
        print(f"  Пропуск {name}: не вдалося прочитати ({e})")
        return None

    if not {"Timestamp", "Filtered_Y"}.issubset(df.columns):
        print(f"  Пропуск {name}: немає колонок Timestamp і Filtered_Y")
        return None

    has_event_column = "Event" in df.columns
    df = _clean(df, name)
    if len(df) < 3:
        print(f"  Пропуск {name}: замало даних ({len(df)} рядків)")
        return None

    # Службові рядки (події між вимірами) не є вимірами: без них сирий сигнал
    # відновлюється коректно, а графіки не мають зайвих точок
    is_extra = _extra_rows(df)
    motion = df[~is_extra].reset_index(drop=True)
    t = motion["Timestamp"].to_numpy(dtype=float)
    y = motion["Filtered_Y"].to_numpy(dtype=float)

    # Номер калібрування для кожного рядка = скільки подій CalibrationStart* було до нього
    segment = df["Event"].str.startswith("CalibrationStart").cumsum()

    params, changed = config.for_trip(metadata)
    if changed:
        print(f"  Увага: {name} записано з іншими параметрами: {'; '.join(changed)}. "
              f"Для перевірки подій цього файлу взято параметри з файлу.")

    if "Raw_Y" in motion.columns and motion["Raw_Y"].notna().all():
        raw = motion["Raw_Y"].to_numpy(dtype=float)
        raw_source = "записаний у CSV"
    else:
        raw = reconstruct_raw(y, params.alpha)
        raw_source = f"відновлений (alpha={params.alpha})"
    if np.nanmax(np.abs(raw)) > 5:
        print(f"  Увага: {name}: відновлений сирий сигнал перевищує 5 G. "
              f"Можливо, під час запису натискали 'Скинути' (стан фільтра обнулився).")

    score_series, final_score = _score_series(df)
    return Trip(
        name=name,
        t=t,
        y=y,
        raw=raw,
        raw_source=raw_source,
        events=df[df["Event"] != ""][["Timestamp", "Event", "Filtered_Y"]].copy(),
        calibration_windows=calibration_windows(df["Timestamp"], df["Event"]),
        score_series=score_series,
        final_score_logged=final_score,
        speed=motion["Speed_mps"].to_numpy(dtype=float) if "Speed_mps" in motion.columns else None,
        has_event_column=has_event_column,
        n_extra_rows=int(np.count_nonzero(is_extra)),
        metadata=metadata,
        params=params,
        params_changed=bool(changed),
        imu=_imu(df, is_extra, segment),
        segment_kind=_segment_kinds(df["Event"], segment),
        route=_route(df),
    )


def _clean(df, name):
    """Типи колонок і відкидання неповних рядків."""
    if "Event" not in df.columns:      # старі файли не мають колонки Event
        df["Event"] = ""
    df["Event"] = df["Event"].fillna("").astype(str)
    numeric = ["Timestamp", "Filtered_Y", "Raw_Y", "Score", "Speed_mps", "Lat", "Lon"] + IMU_COLUMNS
    for column in numeric:
        if column in df.columns:
            df[column] = pd.to_numeric(df[column], errors="coerce")

    n_before = len(df)
    essential = ["Timestamp", "Filtered_Y"] + (["Raw_Y"] if "Raw_Y" in df.columns else [])
    df = df.dropna(subset=essential).reset_index(drop=True)
    if len(df) < n_before:
        # Застосунок дописує файл частинами; при аварійному завершенні
        # останній рядок може бути обірваний
        print(f"  Увага: {name}: відкинуто неповних рядків: {n_before - len(df)} "
              f"(ймовірно, запис обірвався)")
    return df


def _extra_rows(df):
    """Рядки, що не є вимірами: калібрування, службові події і Distraction,
    записаний окремим рядком (він повторює Filtered_Y попереднього рядка)."""
    same_as_prev = df["Filtered_Y"].eq(df["Filtered_Y"].shift(1))
    is_calibration = df["Event"].str.startswith("Calibration")
    is_service = df["Event"].isin(SERVICE_EVENTS)
    return (df["Event"].eq("Distraction") & same_as_prev) | is_calibration | is_service


def _score_series(df):
    """Динаміка Safety Score і останнє записане значення (у старих файлах колонки немає)."""
    if "Score" not in df.columns:
        return None, None
    times = df["Timestamp"].to_numpy(dtype=float)
    scores = df["Score"].to_numpy(dtype=float)
    valid = ~np.isnan(scores)
    final = float(scores[valid][-1]) if valid.any() else None
    return (times[valid], scores[valid]), final


def _imu(df, is_extra, segment):
    """Акселерометр і гіроскоп вимірів (формат 3+) або None."""
    if not set(IMU_COLUMNS).issubset(df.columns):
        return None
    motion = df[~is_extra].reset_index(drop=True)
    return Imu(
        acc=motion[["Ax", "Ay", "Az"]].to_numpy(dtype=float),
        gyro=motion[["Gx", "Gy", "Gz"]].to_numpy(dtype=float),
        raw=motion["Raw_Y"].to_numpy(dtype=float) if "Raw_Y" in motion.columns else None,
        segment=segment[~is_extra].to_numpy(),
    )


def _segment_kinds(events, segment):
    """Чим завершилося кожне калібрування: "gps" або "fallback" (без GPS)."""
    kinds = {}
    for seg, ev in zip(segment, events):
        if ev == "CalibrationDone":
            kinds[int(seg)] = "gps"
        elif ev == "CalibrationDoneFallback":
            kinds[int(seg)] = "fallback"
    return kinds


def _route(df):
    """Маршрут (формат 3+ з увімкненим «Зберігати маршрут») або None.
    Подія без координат прив'язується до останньої відомої точки."""
    if not {"Lat", "Lon"}.issubset(df.columns):
        return None
    route = df[["Timestamp", "Lat", "Lon", "Event"]].copy()
    route[["Lat", "Lon"]] = route[["Lat", "Lon"]].ffill()
    route = route.dropna(subset=["Lat", "Lon"])
    return route if len(route) >= 2 else None
