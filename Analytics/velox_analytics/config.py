"""Параметри алгоритмів: читання VeloxConfig.swift і параметрів, записаних у CSV.

Застосунок і аналітика мають працювати з однаковими числами, тому джерело
параметрів одне - VeloxConfig.swift. Кожна поїздка нових версій ще й містить
рядки "# ключ=значення" з параметрами, з якими її записано: для перевірки
такої поїздки беруться саме вони.
"""

import glob
import os
import re
from dataclasses import dataclass, fields, replace

import numpy as np

CONFIG_FILE = "VeloxConfig.swift"

# імʼя в VeloxConfig.swift -> (поле AppConfig, тип)
SWIFT_KEYS = {
    "filterAlpha": ("alpha", float),
    "maneuverThreshold": ("threshold", float),
    "maneuverCooldown": ("cooldown", float),
    "maneuverPenalty": ("maneuver_penalty", int),
    "distractionPenalty": ("distraction_penalty", int),
    "distractionDurationStep": ("duration_step", float),
    "distractionDurationPenalty": ("duration_penalty", int),
    "distractionDurationPenaltyMax": ("duration_penalty_max", int),
    "safeScoreMin": ("safe_score_min", int),
    "mediumScoreMin": ("medium_score_min", int),
    "ratingDistanceKm": ("rating_distance_km", float),
    "ratingFallbackSpeedKmh": ("rating_fallback_speed_kmh", float),
    "callFocusLossGrace": ("call_focus_loss_grace", float),
}

# Напрям руху за поворотами: ті самі пороги, що в YawForwardEstimator
# (OrientationCalibrator.swift). У VeloxConfig.swift їх немає, бо це
# внутрішні константи алгоритму, а не налаштування.
YAW_MIN_RATE = 0.05          # рад/с
YAW_MAX_ACCELERATION = 1.0   # G
YAW_REQUIRED_ENERGY = 3.0
YAW_MIN_CONSISTENCY = 0.5

G_MS2 = 9.80665              # 1 G у м/с^2

# Параметри самого аналізу (у застосунку їх немає)
BASE_ALPHAS = (0.1, 0.2, 0.3, 0.5)                    # коефіцієнти фільтра для порівняння
THRESHOLDS = np.round(np.arange(0.20, 0.601, 0.05), 2)  # пороги для графіка чутливості


@dataclass(frozen=True)
class AppConfig:
    """Параметри застосунку. Значення за замовчуванням збігаються з VeloxConfig.swift
    на момент написання і використовуються, лише якщо файл не знайдено."""
    alpha: float = 0.2
    threshold: float = 0.4
    cooldown: float = 3.0
    maneuver_penalty: int = 2
    distraction_penalty: int = 5
    duration_step: float = 10.0          # штраф за тривалість: за кожні duration_step с
    duration_penalty: int = 1            # ... мінус duration_penalty балів
    duration_penalty_max: int = 5        # ... але не більше за одне відволікання
    safe_score_min: int = 90
    medium_score_min: int = 75
    rating_distance_km: float = 10.0     # оцінка водія: штрафи на стільки км
    rating_fallback_speed_kmh: float = 30.0  # поїздки без GPS: відстань за тривалістю
    call_focus_loss_grace: float = 2.0   # дзвінок, що почався раніше на стільки с, - причина втрати активності

    @property
    def alphas(self):
        """Коефіцієнти фільтра для порівняння разом із коефіцієнтом застосунку."""
        return sorted(set(BASE_ALPHAS) | {self.alpha})

    def for_trip(self, metadata):
        """Параметри для поїздки: з рядків "#" файлу, а яких там немає - поточні.
        Повертає (AppConfig поїздки, список параметрів, що відрізняються від поточних)."""
        updates, changed = {}, []
        for key, (name, cast) in SWIFT_KEYS.items():
            current = getattr(self, name)
            value = current
            if key in metadata:
                try:
                    value = cast(float(metadata[key]))
                except ValueError:
                    print(f"  Увага: некоректне значення {key}={metadata[key]!r} у файлі, взято поточне")
            if abs(float(value) - float(current)) > 1e-9:
                changed.append(f"{key}: {value} (зараз {current})")
            updates[name] = value
        return replace(self, **updates), changed

    def describe(self):
        return (f"alpha = {self.alpha}, поріг = {self.threshold} G, пауза = {self.cooldown} с, "
                f"штрафи = -{self.maneuver_penalty} / -{self.distraction_penalty}, "
                f"класи: від {self.safe_score_min} / від {self.medium_score_min}")


def find_config(script_dir):
    """Шукає VeloxConfig.swift поруч зі скриптом і в каталогах на два рівні вгору
    (структура проєкту: <проєкт>/Analytics/analyzer.py і <проєкт>/<ціль>/VeloxConfig.swift)."""
    bases = [script_dir, os.path.dirname(script_dir), os.path.dirname(os.path.dirname(script_dir))]
    for base in bases:
        for pattern in (CONFIG_FILE, os.path.join("*", CONFIG_FILE), os.path.join("*", "*", CONFIG_FILE)):
            found = sorted(glob.glob(os.path.join(base, pattern)))
            if found:
                return found[0]
    return None


def parse_config(text):
    """Значення з рядків `static let імʼя: Тип = число` (лише відомі ключі)."""
    values = {}
    pattern = r"static\s+let\s+(\w+)\s*(?::\s*\w+)?\s*=\s*([-+]?\d+(?:\.\d+)?)\b"
    for key, number in re.findall(pattern, text):
        if key in SWIFT_KEYS:
            values[key] = SWIFT_KEYS[key][1](float(number))
    return values


def load_config(path):
    """AppConfig з VeloxConfig.swift (або за замовчуванням, якщо path = None).
    Повертає (AppConfig, опис джерела)."""
    if not path:
        return AppConfig(), "значення за замовчуванням (VeloxConfig.swift не знайдено)"
    with open(path, encoding="utf-8") as f:
        values = parse_config(f.read())
    missing = [key for key in SWIFT_KEYS if key not in values]
    if missing:
        print(f"  Увага: у {path} не знайдено {', '.join(missing)}; для них взято значення за замовчуванням")
    config = AppConfig(**{SWIFT_KEYS[key][0]: value for key, value in values.items()})
    return config, path


# Перевірка під час імпорту: кожен ключ Swift має поле в AppConfig
assert {name for name, _ in SWIFT_KEYS.values()} == {f.name for f in fields(AppConfig)}
