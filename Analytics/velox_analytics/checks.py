"""Незалежні перевірки калібрування і відстань поїздки.

gps_check  - чи збігається поздовжнє прискорення застосунку з dv/dt за GPS;
yaw_check  - наскільки точно метод «напрям за поворотами» відтворює напрям за GPS;
trip_distance_km - пробіг за швидкістю GPS (як TripCSVParser у застосунку).
"""

from dataclasses import dataclass
from typing import Optional

import numpy as np
import pandas as pd

from .config import (G_MS2, YAW_MAX_ACCELERATION, YAW_MIN_CONSISTENCY, YAW_MIN_RATE,
                     YAW_REQUIRED_ENERGY)


@dataclass
class GpsCheck:
    r: float            # кореляція прискорень; додатна - знак і напрям калібрування правильні
    slope: float        # нахил регресії «додаток від GPS»
    n: int              # кількість інтервалів у розрахунку
    t: np.ndarray
    a_gps: np.ndarray   # прискорення за GPS, м/с^2
    a_app: np.ndarray   # прискорення застосунку, м/с^2
    speed: np.ndarray   # швидкість GPS, м/с
    good: np.ndarray    # маска інтервалів без розривів і викидів


@dataclass
class YawCheck:
    angle: Optional[float]  # похибка напряму за поворотами відносно GPS, градуси
    energy: float
    consistency: float
    decided: bool           # чи прийняв би застосунок рішення з такими даними


def gps_check(trip, bin_s=1.0):
    """Звірка поздовжнього прискорення з прискоренням за швидкістю GPS.

    Швидкість GPS оновлюється приблизно раз на секунду, тому обидва сигнали
    усереднюються по інтервалах bin_s. Повертає None без колонки Speed_mps
    або якщо даних замало."""
    if trip.speed is None:
        return None
    ok = ~np.isnan(trip.speed)
    if ok.sum() < 20:
        return None
    t, speed, y = trip.t[ok], trip.speed[ok], trip.y[ok]

    edges = np.arange(t[0], t[-1] + bin_s, bin_s)
    idx = np.digitize(t, edges) - 1
    bt, bv, ba = [], [], []
    for b in np.unique(idx):
        sel = idx == b
        bt.append(t[sel].mean())
        bv.append(speed[sel][-1])          # остання відома швидкість в інтервалі
        ba.append(y[sel].mean() * G_MS2)   # прискорення застосунку, м/с^2
    bt, bv, ba = np.array(bt), np.array(bv), np.array(ba)

    a_gps = np.diff(bv) / np.diff(bt)
    a_app = ba[1:]
    good = (np.abs(a_gps) < 6.0) & (np.diff(bt) < 3 * bin_s)
    if good.sum() < 20 or np.std(a_gps[good]) < 1e-6 or np.std(a_app[good]) < 1e-6:
        return None
    r = float(np.corrcoef(a_gps[good], a_app[good])[0, 1])
    slope = float(np.polyfit(a_gps[good], a_app[good], 1)[0])
    return GpsCheck(r=r, slope=slope, n=int(good.sum()), t=bt[1:], a_gps=a_gps, a_app=a_app,
                    speed=bv[1:], good=good)


def yaw_forward(acc, gyro, up):
    """Порт YawForwardEstimator: напрям руху за кореляцією кутової швидкості
    повороту з горизонтальним прискоренням: forward = -(up x sum(yaw * a_h)).
    Повертає (forward або None, енергія, узгодженість)."""
    up = up / np.linalg.norm(up)
    yaw = gyro @ up
    horiz = acc - np.outer(acc @ up, up)
    hnorm = np.linalg.norm(horiz, axis=1)
    use = (np.abs(yaw) >= YAW_MIN_RATE) & (hnorm <= YAW_MAX_ACCELERATION)
    w = (horiz[use] * yaw[use][:, None]).sum(axis=0)
    energy = float(np.sum(yaw[use] ** 2))
    abs_sum = float(np.sum(np.abs(yaw[use]) * hnorm[use]))
    consistency = float(np.linalg.norm(w) / abs_sum) if abs_sum > 0 else 0.0
    f = -np.cross(up, w)
    n = np.linalg.norm(f)
    return (f / n if n > 0 else None), energy, consistency


def yaw_check(trip):
    """Перевірка методу «напрям за поворотами» на поїздці з GPS.

    У найдовшому GPS-калібруванні справжній напрям руху відновлюється точно
    з Raw_Y = a * forward (метод найменших квадратів), а вертикаль - як головна
    вісь обертання (авто крутиться переважно навколо вертикалі; її знак на метод
    не впливає). Повертає None без гіроскопа або GPS-калібрування."""
    imu = trip.imu
    if imu is None or imu.raw is None:
        return None
    gps_segments = [s for s, kind in trip.segment_kind.items() if kind == "gps"]
    if not gps_segments:
        return None
    seg = max(gps_segments, key=lambda s: int(np.sum(imu.segment == s)))
    sel = ((imu.segment == seg) & np.all(np.isfinite(imu.acc), axis=1)
           & np.all(np.isfinite(imu.gyro), axis=1))
    if sel.sum() < 300:
        return None
    acc, gyro, raw = imu.acc[sel], imu.gyro[sel], imu.raw[sel]

    forward, *_ = np.linalg.lstsq(acc, raw, rcond=None)
    if np.linalg.norm(forward) < 1e-6:
        return None
    forward /= np.linalg.norm(forward)
    smooth = pd.DataFrame(gyro).rolling(10, center=True).mean().dropna().to_numpy()
    up = np.linalg.eigh(np.cov(smooth.T))[1][:, -1]
    up = up - forward * np.dot(up, forward)
    up /= np.linalg.norm(up)

    estimate, energy, consistency = yaw_forward(acc, gyro, up)
    decided = estimate is not None and energy >= YAW_REQUIRED_ENERGY and consistency >= YAW_MIN_CONSISTENCY
    angle = None
    if estimate is not None:
        angle = float(np.degrees(np.arccos(np.clip(np.dot(estimate, forward), -1, 1))))
    return YawCheck(angle=angle, energy=energy, consistency=consistency, decided=decided)


def trip_distance_km(trip, max_gap=3.0):
    """Відстань за швидкістю GPS методом трапецій; проміжки довші за max_gap с
    (калібрування, фон) пропускаються. None без швидкості."""
    if trip.speed is None:
        return None
    ok = ~np.isnan(trip.speed)
    if ok.sum() < 2:
        return None
    t, v = trip.t[ok], trip.speed[ok]
    dt = np.diff(t)
    good = (dt > 0) & (dt <= max_gap)
    return float(np.sum(((v[1:] + v[:-1]) / 2 * dt)[good]) / 1000)
