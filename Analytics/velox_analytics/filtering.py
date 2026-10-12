"""Обробка сигналу: Low-Pass фільтр, відновлення сирого сигналу, детектор маневрів.

Усі функції повторюють логіку застосунку (EventDetectors.swift), щоб
перерахунок подій з CSV давав ті самі результати, що й телефон.
"""

import numpy as np


def apply_filter(x, alpha):
    """Low-Pass фільтр, як у застосунку: y[n] = alpha*x[n] + (1-alpha)*y[n-1], y[-1] = 0."""
    out = np.empty_like(x, dtype=float)
    prev = 0.0
    for i, v in enumerate(x):
        prev = alpha * v + (1.0 - alpha) * prev
        out[i] = prev
    return out


def reconstruct_raw(y, alpha):
    """Точне відновлення сирого сигналу з відфільтрованого.

    Фільтр першого порядку зворотний: x[n] = (y[n] - (1-alpha)*y[n-1]) / alpha.
    Потрібно для старих файлів без колонки Raw_Y."""
    prev = np.concatenate(([0.0], y[:-1]))
    return (y - (1.0 - alpha) * prev) / alpha


def detect_maneuvers(t, y, threshold, cooldown):
    """Різкі гальмування і розгони, як ManeuverDetector: поріг строгий, а пауза
    окрема для кожного типу, щоб гальмування не «зʼїдало» паузу для розгону.
    Повертає список (час, "HardBraking" | "HardAcceleration")."""
    found = []
    last_brake = -np.inf
    last_accel = -np.inf
    for ti, yi in zip(t, y):
        if yi < -threshold and ti - last_brake >= cooldown:
            found.append((ti, "HardBraking"))
            last_brake = ti
        elif yi > threshold and ti - last_accel >= cooldown:
            found.append((ti, "HardAcceleration"))
            last_accel = ti
    return found


def count_maneuvers(found):
    """(гальмувань, розгонів) у результаті detect_maneuvers."""
    brakes = sum(1 for _, kind in found if kind == "HardBraking")
    return brakes, len(found) - brakes
