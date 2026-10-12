"""Підсумкова таблиця поїздок, перевірка узгодженості логів і чутливість до порога."""

import numpy as np
import pandas as pd

from .config import THRESHOLDS
from .events import count_calls, distraction_episodes, episode_seconds
from .filtering import count_maneuvers, detect_maneuvers
from .scoring import classify_score, duration_penalty, safety_score

NA = "н/д"   # у старих файлах немає колонки Event чи Score


def trip_row(trip):
    """Рядок summary.csv для однієї поїздки.

    Події з лога порівнюються з перерахунком за тими параметрами, з якими
    застосунок працював під час запису (trip.params), а не поточними."""
    t, y, ev = trip.t, trip.y, trip.events["Event"]
    p = trip.params
    logged_brake = int(ev.eq("HardBraking").sum())
    logged_accel = int(ev.eq("HardAcceleration").sum())
    logged_distract = int(ev.eq("Distraction").sum())
    sim_brake, sim_accel = count_maneuvers(detect_maneuvers(t, y, p.threshold, p.cooldown))

    seconds = episode_seconds(distraction_episodes(trip.events))
    extra = sum(duration_penalty(sec, p) for sec in seconds)
    has_durations = bool(ev.eq("DistractionEnd").any()) or "distractionDurationStep" in trip.metadata
    if trip.has_event_column:
        score = safety_score(logged_brake + logged_accel, logged_distract, p, extra)
        score_computed = f"{score} ({classify_score(score, p)})"
    else:
        logged_brake = logged_accel = logged_distract = NA
        score_computed = NA

    logged = trip.final_score_logged
    score_logged = f"{int(logged)} ({classify_score(int(logged), p)})" if logged is not None else NA

    if trip.params_changed:
        params_note = "з файлу, відрізняються від поточних"
    else:
        params_note = "з файлу" if trip.metadata else "поточні (у файлі немає)"

    return {
        "Файл": trip.name,
        "Тривалість, с": round(trip.duration, 1),
        "Вимірів": len(t),
        "Макс. розгін, G": round(float(np.max(y)), 3),
        "Макс. гальмування, G": round(float(abs(np.min(y))), 3),
        "Гальмувань (лог)": logged_brake,
        "Розгонів (лог)": logged_accel,
        "Відволікань (лог)": logged_distract,
        "Телефон у руках, с": round(sum(seconds), 1) if has_durations else NA,
        "Штраф за тривалість": extra if has_durations else NA,
        "Дзвінків": count_calls(ev),
        "Гальмувань (перерахунок)": sim_brake,
        "Розгонів (перерахунок)": sim_accel,
        "Час вище порога, %": round(100.0 * float(np.mean(np.abs(y) > p.threshold)), 2),
        "Safety Score (лог)": score_logged,
        "Safety Score (розрахунок)": score_computed,
        "Кореляція з GPS (r)": round(trip.gps.r, 2) if trip.gps else NA,
        "Напрям за поворотами, похибка °": (round(trip.yaw.angle, 1)
                                           if trip.yaw and trip.yaw.angle is not None else NA),
        "Відстань, км": round(trip.distance_km, 2) if trip.distance_km is not None else NA,
        "Сирий сигнал": trip.raw_source,
        "Поріг запису, G": p.threshold,
        "Параметри": params_note,
        "Версія застосунку": trip.metadata.get("app", NA),
    }


def summarize(trips):
    return pd.DataFrame([trip_row(trip) for trip in trips])


def check_consistency(summary):
    """Порівнює події і Safety Score, записані застосунком, з перерахунком. Друкує висновок."""
    comparable = summary[summary["Гальмувань (лог)"] != NA]
    if comparable.empty:
        print("Перевірка пропущена: у файлах немає колонки Event.")
        return
    bad = comparable[(comparable["Гальмувань (лог)"] != comparable["Гальмувань (перерахунок)"]) |
                     (comparable["Розгонів (лог)"] != comparable["Розгонів (перерахунок)"])]
    if bad.empty:
        print("Перевірка: події в CSV збігаються з перерахунком (поріг, пауза).")
    else:
        print("Перевірка: є розбіжності між подіями в CSV і перерахунком "
              "(для файлів без рядків параметрів можливо, що змінювався поріг у додатку, "
              "або файл записаний до виправлення роздільної паузи гальмування/розгону):")
        print(bad[["Файл", "Гальмувань (лог)", "Гальмувань (перерахунок)",
                   "Розгонів (лог)", "Розгонів (перерахунок)"]].to_string(index=False))

    has_score = comparable[comparable["Safety Score (лог)"] != NA]
    if not has_score.empty:
        score_bad = has_score[has_score["Safety Score (лог)"] != has_score["Safety Score (розрахунок)"]]
        if score_bad.empty:
            print("Перевірка: Safety Score у CSV збігається з розрахунком за формулою.")
        else:
            print("Перевірка: Safety Score у CSV відрізняється від розрахунку за формулою:")
            print(score_bad[["Файл", "Safety Score (лог)", "Safety Score (розрахунок)"]].to_string(index=False))


def sensitivity_counts(trips, config):
    """Кількість маневрів для кожного порога з THRESHOLDS.

    Повертає (по файлах з фільтром застосунку, сума по файлах для кожного alpha,
    по файлах без фільтра). Пауза між маневрами - поточна."""
    per_file, raw_per_file = {}, {}
    total = {a: np.zeros(len(THRESHOLDS), dtype=int) for a in config.alphas}

    def counts(t, signal):
        return np.array([len(detect_maneuvers(t, signal, th, config.cooldown)) for th in THRESHOLDS])

    for trip in trips:
        raw_per_file[trip.name] = counts(trip.t, trip.raw)
        for a in config.alphas:
            row = counts(trip.t, trip.smoothed(a, config.alpha))
            total[a] += row
            if a == config.alpha:
                per_file[trip.name] = row
    return per_file, total, raw_per_file
