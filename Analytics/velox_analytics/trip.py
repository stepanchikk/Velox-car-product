"""Поїздка в памʼяті: дані з CSV і результати перевірок."""

import os
from dataclasses import dataclass, field
from typing import Optional

import numpy as np
import pandas as pd

from .config import AppConfig
from .filtering import apply_filter


@dataclass
class Imu:
    """Сирі дані сенсорів (формат 3+) для перевірки напряму за поворотами."""
    acc: np.ndarray                # Ax, Ay, Az, G
    gyro: np.ndarray               # Gx, Gy, Gz, рад/с
    raw: Optional[np.ndarray]      # Raw_Y, G
    segment: np.ndarray            # номер калібрування, до якого належить вимір


@dataclass
class Trip:
    name: str
    t: np.ndarray                  # час виміру, с від «Старт»
    y: np.ndarray                  # Filtered_Y, G
    raw: np.ndarray                # сирий сигнал (з CSV або відновлений)
    raw_source: str
    events: pd.DataFrame           # рядки з подіями: Timestamp, Event, Filtered_Y
    calibration_windows: list
    score_series: Optional[tuple]  # (час, Score) або None у старих файлах
    final_score_logged: Optional[float]
    speed: Optional[np.ndarray]    # Speed_mps для кожного виміру
    has_event_column: bool
    n_extra_rows: int              # службові рядки, відкинуті з вимірів
    metadata: dict                 # рядки "# ключ=значення"
    params: AppConfig              # параметри, з якими записано поїздку
    params_changed: bool
    imu: Optional[Imu]
    segment_kind: dict             # номер калібрування -> "gps" | "fallback"
    route: Optional[pd.DataFrame]  # Timestamp, Lat, Lon, Event

    maneuvers_enabled: Optional[np.ndarray] = None
    penalty_total: Optional[float] = None
    session_end: Optional[float] = None
    processing_ms: Optional[np.ndarray] = None
    sample_gaps: Optional[np.ndarray] = None

    # Результати перевірок (заповнює cli.analyze_trip)
    gps: Optional[object] = None
    yaw: Optional[object] = None
    distance_km: Optional[float] = None

    _smoothed: dict = field(default_factory=dict, repr=False)

    @property
    def stem(self):
        return os.path.splitext(self.name)[0]

    @property
    def duration(self):
        return float(self.session_end if self.session_end is not None else self.t[-1])

    def smoothed(self, alpha, app_alpha):
        """Сигнал після фільтра з коефіцієнтом alpha.

        Для коефіцієнта застосунку це записаний Filtered_Y, для інших сирий сигнал
        фільтрується заново. Результат кешується: його використовують і графіки,
        і аналіз чутливості."""
        if alpha == app_alpha:
            return self.y
        if alpha not in self._smoothed:
            self._smoothed[alpha] = apply_filter(self.raw, alpha)
        return self._smoothed[alpha]
