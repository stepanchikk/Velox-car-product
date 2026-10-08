"""
Velox: аналітика телеметрії поїздок.

Що робить скрипт для кожного CSV з додатка:
  1. графік "сира vs відфільтрована" з порогом і позначеними подіями;
  2. порівняння коефіцієнтів фільтра alpha на одному сигналі;
а також для всіх файлів разом:
  3. чутливість детекції до порога (обґрунтування 0.4 G);
  4. розподіл значень відфільтрованого сигналу;
  5. таблицю summary.csv з підсумками по кожній поїздці.

Використання:
    python analyzer.py                 # CSV беруться з каталогу, де лежить скрипт
    python analyzer.py шлях/до/каталогу  # CSV з іншого каталогу
    python analyzer.py --show          # додатково показати вікна графіків
    python analyzer.py --config шлях/до/VeloxConfig.swift   # явно вказати параметри

Параметри алгоритмів (alpha, поріг, паузи, штрафи, межі класів) скрипт бере
з файлу VeloxConfig.swift проєкту, того самого, що використовує застосунок.
Файл шукається поруч зі скриптом і в каталогах проєкту на два рівні вгору;
якщо його не знайдено, використовуються значення за замовчуванням із попередженням.

Нові версії застосунку пишуть на початку CSV рядки "# ключ=значення" з
параметрами, з якими записано поїздку. Для перевірки подій і Safety Score
такого файлу беруться саме вони, а не поточні з VeloxConfig.swift: так
старі поїздки перевіряються коректно навіть після зміни порога.

Результати (PNG і summary.csv) зберігаються в підкаталог figures/.

Залежності: pip install pandas matplotlib numpy

Про сирий сигнал. У додатку фільтр такий: y[n] = alpha*x[n] + (1-alpha)*y[n-1].
Він зворотний, тому з колонки Filtered_Y сирий сигнал відновлюється точно:
x[n] = (y[n] - (1-alpha)*y[n-1]) / alpha. Якщо в CSV є колонка Raw_Y
(нова версія додатка), використовується вона.
"""

import argparse
import glob
import os
import re
import sys

import numpy as np
import pandas as pd
import matplotlib.pyplot as plt
from matplotlib.ticker import MaxNLocator

# ---------- Параметри застосунку (джерело: VeloxConfig.swift) ----------
CONFIG_FILE = "VeloxConfig.swift"
# імʼя в VeloxConfig.swift -> (глобальна змінна скрипта, тип, значення за замовчуванням)
CONFIG_KEYS = {
    "filterAlpha": ("ALPHA", float, 0.2),
    "maneuverThreshold": ("THRESHOLD", float, 0.4),
    "maneuverCooldown": ("COOLDOWN", float, 3.0),
    "maneuverPenalty": ("MANEUVER_PENALTY", int, 2),
    "distractionPenalty": ("DISTRACTION_PENALTY", int, 5),
    "distractionDurationStep": ("DURATION_STEP", float, 10.0),
    "distractionDurationPenalty": ("DURATION_PENALTY", int, 1),
    "distractionDurationPenaltyMax": ("DURATION_PENALTY_MAX", int, 5),
    "safeScoreMin": ("SAFE_SCORE_MIN", int, 90),
    "mediumScoreMin": ("MEDIUM_SCORE_MIN", int, 75),
}
# Значення за замовчуванням; main() замінює їх значеннями з VeloxConfig.swift
ALPHA = 0.2
THRESHOLD = 0.4
COOLDOWN = 3.0
MANEUVER_PENALTY = 2
DISTRACTION_PENALTY = 5
DURATION_STEP = 10.0          # штраф за тривалість: за кожні DURATION_STEP с
DURATION_PENALTY = 1          # ... мінус DURATION_PENALTY балів
DURATION_PENALTY_MAX = 5      # ... але не більше за одне відволікання
SAFE_SCORE_MIN = 90
MEDIUM_SCORE_MIN = 75

G_MS2 = 9.80665             # 1 G у м/с^2

# ---------- Параметри аналізу ----------
BASE_ALPHAS = [0.1, 0.2, 0.3, 0.5]
ALPHAS = list(BASE_ALPHAS)   # доповнюється значенням ALPHA із конфігурації
THRESHOLDS = np.round(np.arange(0.20, 0.601, 0.05), 2)

EVENT_STYLE = {
    "HardBraking": ("v", "red", "Різке гальмування"),
    "HardAcceleration": ("^", "darkorange", "Агресивний розгін"),
}
DISTRACTION_COLOR = "purple"
CALL_COLOR = "teal"
# Службові рядки нових версій: повторюють останні значення, вимірами не є
SERVICE_EVENTS = ("DistractionEnd", "DistractionResume", "CallIncoming", "CallStart", "CallStart_Handheld", "CallEnd")


# ======================================================================
# Завантаження та підготовка даних
# ======================================================================

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


def parse_config(path):
    """Читає рядки `static let імʼя: Тип = число` з VeloxConfig.swift."""
    text = open(path, encoding="utf-8").read()
    values = {}
    pattern = r"static\s+let\s+(\w+)\s*(?::\s*\w+)?\s*=\s*([-+]?\d+(?:\.\d+)?)\b"
    for name, number in re.findall(pattern, text):
        if name in CONFIG_KEYS:
            values[name] = CONFIG_KEYS[name][1](float(number))
    return values


def apply_config(path):
    """Заповнює глобальні параметри з VeloxConfig.swift. Повертає опис джерела."""
    global ALPHAS
    values = parse_config(path) if path else {}
    missing = [k for k in CONFIG_KEYS if k not in values]
    for key, (var, _cast, default) in CONFIG_KEYS.items():
        globals()[var] = values.get(key, default)
    ALPHAS = sorted(set(BASE_ALPHAS) | {ALPHA})
    if not path:
        return "значення за замовчуванням (VeloxConfig.swift не знайдено)"
    if missing:
        print(f"  Увага: у {path} не знайдено {', '.join(missing)}; для них взято значення за замовчуванням")
    return path


def read_metadata(path):
    """Рядки "# ключ=значення" на початку файлу. Повертає (словник, кількість рядків)."""
    metadata = {}
    count = 0
    with open(path, encoding="utf-8-sig") as f:
        for line in f:
            if not line.startswith("#"):
                break
            count += 1
            body = line[1:].strip()
            key, sep, value = body.partition("=")
            if sep and key.strip():
                metadata[key.strip()] = value.strip()
    return metadata, count


def trip_params(metadata):
    """Параметри алгоритмів для поїздки: з рядків "#" файлу, а яких там немає -
    поточні (з VeloxConfig.swift). Повертає (словник за іменами VeloxConfig,
    список параметрів, що відрізняються від поточних)."""
    params, changed = {}, []
    for key, (var, cast, _default) in CONFIG_KEYS.items():
        current = globals()[var]
        value = current
        if key in metadata:
            try:
                value = cast(float(metadata[key]))
            except ValueError:
                print(f"  Увага: некоректне значення {key}={metadata[key]!r} у файлі, взято поточне")
        if abs(float(value) - float(current)) > 1e-9:
            changed.append(f"{key}: {value} (зараз {current})")
        params[key] = value
    return params, changed


def load_trip(path):
    """Читає CSV поїздки. Повертає словник з даними або None, якщо файл не підходить."""
    try:
        metadata, n_meta = read_metadata(path)
        df = pd.read_csv(path, skiprows=n_meta)
    except Exception as e:
        print(f"  Пропуск {os.path.basename(path)}: не вдалося прочитати ({e})")
        return None

    if not {"Timestamp", "Filtered_Y"}.issubset(df.columns):
        print(f"  Пропуск {os.path.basename(path)}: немає колонок Timestamp і Filtered_Y")
        return None

    # Старі файли не мають колонки Event
    has_event_column = "Event" in df.columns
    if not has_event_column:
        df["Event"] = ""
    df["Event"] = df["Event"].fillna("").astype(str)

    df["Timestamp"] = pd.to_numeric(df["Timestamp"], errors="coerce")
    df["Filtered_Y"] = pd.to_numeric(df["Filtered_Y"], errors="coerce")
    has_raw = "Raw_Y" in df.columns
    if has_raw:
        df["Raw_Y"] = pd.to_numeric(df["Raw_Y"], errors="coerce")
    has_score = "Score" in df.columns
    if has_score:
        df["Score"] = pd.to_numeric(df["Score"], errors="coerce")
    has_speed = "Speed_mps" in df.columns
    if has_speed:
        df["Speed_mps"] = pd.to_numeric(df["Speed_mps"], errors="coerce")
    n_before = len(df)
    essential = ["Timestamp", "Filtered_Y"] + (["Raw_Y"] if has_raw else [])
    df = df.dropna(subset=essential).reset_index(drop=True)
    if len(df) < n_before:
        # Поточна версія дописує файл частинами; при аварійному завершенні
        # останній рядок може бути обірваний
        print(f"  Увага: {os.path.basename(path)}: відкинуто неповних рядків: {n_before - len(df)} "
              f"(ймовірно, запис обірвався)")

    if len(df) < 3:
        print(f"  Пропуск {os.path.basename(path)}: замало даних ({len(df)} рядків)")
        return None

    # Події (для позначок на графіку) беремо з усіх рядків
    events = df[df["Event"] != ""][["Timestamp", "Event", "Filtered_Y"]].copy()
    calibration_windows = find_calibration_windows(df)

    # Динаміка Safety Score (нова колонка; у старих файлах відсутня)
    if has_score:
        score_t = df["Timestamp"].to_numpy(dtype=float)
        score_v = df["Score"].to_numpy(dtype=float)
        valid = ~np.isnan(score_v)
        score_series = (score_t[valid], score_v[valid])
        final_score_logged = float(score_v[valid][-1]) if valid.any() else None
    else:
        score_series = None
        final_score_logged = None

    # Нова версія додатка пише подію Distraction окремим рядком між вимірами.
    # Такий рядок повторює Filtered_Y попереднього рядка, тому його можна відсіяти,
    # щоб не псувати відновлення сирого сигналу.
    same_as_prev = df["Filtered_Y"].eq(df["Filtered_Y"].shift(1))
    is_calibration = df["Event"].str.startswith("Calibration")
    is_service = df["Event"].isin(SERVICE_EVENTS)
    is_extra = (df["Event"].eq("Distraction") & same_as_prev) | is_calibration | is_service
    motion = df[~is_extra].reset_index(drop=True)

    t = motion["Timestamp"].to_numpy(dtype=float)
    y = motion["Filtered_Y"].to_numpy(dtype=float)

    speed = motion["Speed_mps"].to_numpy(dtype=float) if has_speed else None

    params, changed = trip_params(metadata)
    if changed:
        print(f"  Увага: {os.path.basename(path)} записано з іншими параметрами: {'; '.join(changed)}. "
              f"Для перевірки подій цього файлу взято параметри з файлу.")

    if has_raw and motion["Raw_Y"].notna().all():
        raw = motion["Raw_Y"].to_numpy(dtype=float)
        raw_source = "записаний у CSV"
    else:
        raw = reconstruct_raw(y, params["filterAlpha"])
        raw_source = f"відновлений (alpha={params['filterAlpha']})"

    if np.nanmax(np.abs(raw)) > 5:
        print(f"  Увага: {os.path.basename(path)}: відновлений сирий сигнал перевищує 5 G. "
              f"Можливо, під час запису натискали 'Скинути' (стан фільтра обнулився).")

    return {
        "name": os.path.basename(path),
        "t": t,
        "y": y,
        "raw": raw,
        "raw_source": raw_source,
        "events": events,
        "calibration_windows": calibration_windows,
        "score_series": score_series,
        "final_score_logged": final_score_logged,
        "speed": speed,
        "has_event_column": has_event_column,
        "n_extra_rows": int(np.count_nonzero(is_extra)),
        "metadata": metadata,
        "params": params,
        "params_changed": bool(changed),
    }


def gps_check(trip, bin_s=1.0):
    """Звірка поздовжнього прискорення з додатка з прискоренням, отриманим
    диференціюванням швидкості GPS. Повертає None, якщо колонки Speed_mps немає.

    Швидкість GPS оновлюється приблизно раз на секунду, тому обидва сигнали
    усереднюються по інтервалах bin_s. Додатний r означає, що знак і напрям
    калібрування правильні (розгін = додатне значення)."""
    if trip["speed"] is None:
        return None
    t, speed, y = trip["t"], trip["speed"], trip["y"]
    ok = ~np.isnan(speed)
    if ok.sum() < 20:
        return None
    t, speed, y = t[ok], speed[ok], y[ok]

    edges = np.arange(t[0], t[-1] + bin_s, bin_s)
    idx = np.digitize(t, edges) - 1
    bins = np.unique(idx)
    bt, bv, ba = [], [], []
    for b in bins:
        sel = idx == b
        bt.append(t[sel].mean())
        bv.append(speed[sel][-1])          # остання відома швидкість в інтервалі
        ba.append(y[sel].mean() * G_MS2)   # прискорення додатка, м/с^2
    bt, bv, ba = np.array(bt), np.array(bv), np.array(ba)

    a_gps = np.diff(bv) / np.diff(bt)
    a_app = ba[1:]
    good = (np.abs(a_gps) < 6.0) & (np.diff(bt) < 3 * bin_s)
    if good.sum() < 20 or np.std(a_gps[good]) < 1e-6 or np.std(a_app[good]) < 1e-6:
        return None
    r = float(np.corrcoef(a_gps[good], a_app[good])[0, 1])
    slope = float(np.polyfit(a_gps[good], a_app[good], 1)[0])
    return {"r": r, "slope": slope, "n": int(good.sum()),
            "t": bt[1:], "a_gps": a_gps, "a_app": a_app, "speed": bv[1:], "good": good}


def find_calibration_windows(df):
    """Проміжки без калібрування: від CalibrationStart* до наступного CalibrationDone*.
    Невдале перекалібрування в русі (CalibrationFailed, потім CalibrationStart_Retry)
    входить в один проміжок, бо весь цей час виміри не записувались."""
    windows = []
    start = None
    for ts, ev in zip(df["Timestamp"], df["Event"]):
        if ev.startswith("CalibrationStart") and start is None:
            start = ts
        elif ev.startswith("CalibrationDone") and start is not None:
            windows.append((float(start), float(ts)))
            start = None
    return windows


def reconstruct_raw(y, alpha):
    """Точне відновлення сирого сигналу з відфільтрованого (фільтр першого порядку)."""
    prev = np.concatenate(([0.0], y[:-1]))
    return (y - (1.0 - alpha) * prev) / alpha


def apply_filter(x, alpha):
    """Low-Pass фільтр, як у SensorManager: y[n] = alpha*x[n] + (1-alpha)*y[n-1]."""
    out = np.empty_like(x, dtype=float)
    prev = 0.0
    for i, v in enumerate(x):
        prev = alpha * v + (1.0 - alpha) * prev
        out[i] = prev
    return out


def detect_maneuvers(t, y, threshold, cooldown=None):
    """Повторює логіку detectManeuvers з додатка: окрема пауза для гальмування
    і розгону, щоб один не 'з'їдав' паузу для іншого (виправлено разом із
    впровадженням Safety Score - раніше пауза була спільна)."""
    if cooldown is None:
        cooldown = COOLDOWN
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


def distraction_episodes(events):
    """Відволікання з тривалістю: Distraction починає нове, DistractionResume
    продовжує попереднє, DistractionEnd закриває шматок. Повертає список
    епізодів, кожен - список інтервалів (початок, кінець)."""
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


def count_calls(events):
    """Кількість дзвінків: від CallIncoming або CallStart* до CallEnd - один дзвінок."""
    count, open_call = 0, False
    for ev in events:
        if ev in ("CallIncoming", "CallStart", "CallStart_Handheld"):
            if not open_call:
                count += 1
                open_call = True
        elif ev == "CallEnd":
            open_call = False
    return count


def duration_penalty(seconds, params=None):
    """Штраф за тривалість одного відволікання (SafetyScoreCalculator.durationPenalty)."""
    step = params["distractionDurationStep"] if params else DURATION_STEP
    per_step = params["distractionDurationPenalty"] if params else DURATION_PENALTY
    cap = params["distractionDurationPenaltyMax"] if params else DURATION_PENALTY_MAX
    if seconds <= 0:
        return 0
    return min(cap, int(seconds // step) * per_step)


def safety_score(maneuvers, distractions, params=None, extra=0):
    """Формула застосунку (SafetyScoreCalculator): 100 - штрафи, не менше 0.
    params - параметри поїздки (trip_params); без них - поточні.
    extra - сумарний штраф за тривалість відволікань."""
    m_pen = params["maneuverPenalty"] if params else MANEUVER_PENALTY
    d_pen = params["distractionPenalty"] if params else DISTRACTION_PENALTY
    return max(0, 100 - (m_pen * maneuvers + d_pen * distractions + extra))


def classify_score(score, params=None):
    safe = params["safeScoreMin"] if params else SAFE_SCORE_MIN
    medium = params["mediumScoreMin"] if params else MEDIUM_SCORE_MIN
    if score >= safe:
        return "Безпечний"
    if score >= medium:
        return "Середній"
    return "Небезпечний"


# ======================================================================
# Графіки
# ======================================================================

def _unique_legend(ax, **kwargs):
    """Легенда без дублікатів. Викликається ПІСЛЯ побудови всіх ліній і порогів."""
    handles, labels = ax.get_legend_handles_labels()
    seen = {}
    for h, l in zip(handles, labels):
        if l and not l.startswith("_") and l not in seen:
            seen[l] = h
    ax.legend(seen.values(), seen.keys(), **kwargs)


def _break_gaps(t, *series, max_gap=1.0):
    """Вставляє NaN у місцях розриву даних (калібрування, фон), щоб лінія не з'єднувала їх."""
    idx = np.where(np.diff(t) > max_gap)[0] + 1
    if len(idx) == 0:
        return (t,) + series
    out = [np.insert(np.asarray(a, dtype=float), idx, np.nan) for a in (t,) + series]
    return tuple(out)


def _draw_threshold(ax):
    """Пунктирні лінії порога ±THRESHOLD."""
    ax.axhline(THRESHOLD, color="red", linestyle="--", alpha=0.5, label=f"Поріг ±{THRESHOLD} G")
    ax.axhline(-THRESHOLD, color="red", linestyle="--", alpha=0.5)


def _finish_trip_plot(fig, ax, title, path):
    """Підписи, сітка, легенда і збереження для графіків окремої поїздки."""
    ax.set_title(title)
    ax.set_xlabel("Час від початку запису, с")
    ax.set_ylabel("Прискорення по осі Y, G")
    ax.grid(True, alpha=0.4)
    _unique_legend(ax, loc="upper right")
    fig.tight_layout()
    fig.savefig(path, dpi=150)
    return fig


def plot_raw_vs_filtered(trip, out_dir):
    t, y, raw, events = trip["t"], trip["y"], trip["raw"], trip["events"]
    fig, ax = plt.subplots(figsize=(14, 6))

    tp, raw_p, y_p = _break_gaps(t, raw, y)
    ax.plot(tp, raw_p, color="#b5b5b5", linewidth=0.8, label=f"Сирий сигнал ({trip['raw_source']})")
    ax.plot(tp, y_p, color="tab:blue", linewidth=1.8, label=f"Відфільтрований (alpha={ALPHA})")
    _draw_threshold(ax)

    for ev, (marker, color, label) in EVENT_STYLE.items():
        sub = events[events["Event"] == ev]
        if len(sub):
            ax.scatter(sub["Timestamp"], sub["Filtered_Y"], marker=marker, color=color,
                       s=90, zorder=5, edgecolor="black", label=label)
    for w_start, w_end in trip["calibration_windows"]:
        ax.axvspan(w_start, w_end, color="gray", alpha=0.18, label="Калібрування")
    for ts in events[events["Event"] == "Distraction"]["Timestamp"]:
        ax.axvline(ts, color=DISTRACTION_COLOR, linestyle=":", linewidth=1.6, alpha=0.9,
                   label="Відволікання (Anti-Fraud)")
    for episode in distraction_episodes(events):
        for d_start, d_end in episode:
            ax.axvspan(d_start, d_end, color=DISTRACTION_COLOR, alpha=0.12, label="Телефон у руках")
    for ts in events[events["Event"].str.startswith("Call")]["Timestamp"]:
        ax.axvline(ts, color=CALL_COLOR, linestyle="-.", linewidth=1.2, alpha=0.8,
                   label="Дзвінок (без штрафу, якщо без рук)")

    return _finish_trip_plot(fig, ax, f"Сира та відфільтрована телеметрія: {trip['name']}",
                             os.path.join(out_dir, f"{stem(trip)}_raw_vs_filtered.png"))


ZOOM_MIN_TRIP_S = 120.0    # від якої тривалості будувати додатковий фрагмент
ZOOM_WINDOW_S = 40.0       # довжина фрагмента


def zoom_window(t, raw, width=ZOOM_WINDOW_S):
    """Фрагмент довжиною width с, де сирий сигнал найбільш мінливий."""
    step = max(1, int(round(1.0 / max(np.median(np.diff(t)), 1e-3))))   # ~1 с
    starts = np.arange(t[0], t[-1] - width, step * 0.5 + 1e-9)
    if len(starts) == 0:
        return float(t[0]), float(t[-1])
    scores = [np.std(raw[(t >= s0) & (t < s0 + width)]) if ((t >= s0) & (t < s0 + width)).sum() > 10 else 0.0
              for s0 in starts]
    s0 = float(starts[int(np.argmax(scores))])
    return s0, s0 + width


def plot_alpha_comparison(trip, out_dir):
    t, y, raw = trip["t"], trip["y"], trip["raw"]
    fig, ax = plt.subplots(figsize=(14, 6))

    ax.plot(*_break_gaps(t, raw), color="#c8c8c8", linewidth=0.7, label="Сирий сигнал")
    peak = 0.0
    for a in ALPHAS:
        ya = y if a == ALPHA else apply_filter(raw, a)
        peak = max(peak, float(np.max(np.abs(ya))))
        width = 2.2 if a == ALPHA else 1.2
        suffix = " (у додатку)" if a == ALPHA else ""
        ax.plot(*_break_gaps(t, ya), linewidth=width, label=f"alpha = {a}{suffix}")
    _draw_threshold(ax)

    limit = max(0.6, 1.3 * peak)
    ax.set_ylim(-limit, limit)
    full = _finish_trip_plot(fig, ax, f"Вплив коефіцієнта alpha на згладжування: {trip['name']}",
                             os.path.join(out_dir, f"{stem(trip)}_alpha_comparison.png"))

    # На довгій поїздці лінії різних alpha зливаються, тому додатково
    # будуємо фрагмент з найбільшою активністю сирого сигналу
    if t[-1] - t[0] > ZOOM_MIN_TRIP_S:
        window = zoom_window(t, raw)
        fig2, ax2 = plt.subplots(figsize=(14, 6))
        sel = (t >= window[0]) & (t <= window[1])
        ax2.plot(*_break_gaps(t[sel], raw[sel]), color="#c8c8c8", linewidth=0.9, label="Сирий сигнал")
        for a in ALPHAS:
            ya = y if a == ALPHA else apply_filter(raw, a)
            ax2.plot(*_break_gaps(t[sel], ya[sel]), linewidth=2.4 if a == ALPHA else 1.3,
                     label=f"alpha = {a}" + (" (у додатку)" if a == ALPHA else ""))
        _draw_threshold(ax2)
        ax2.set_xlim(window)
        zoom_peak = float(np.max(np.abs(raw[sel])))
        ax2.set_ylim(-max(0.6, 1.2 * zoom_peak), max(0.6, 1.2 * zoom_peak))
        _finish_trip_plot(fig2, ax2,
                          f"Вплив alpha, фрагмент {window[0]:.0f}-{window[1]:.0f} с (найбільша активність): {trip['name']}",
                          os.path.join(out_dir, f"{stem(trip)}_alpha_comparison_zoom.png"))
        return [full, fig2]
    return full


def plot_gps_check(trip, check, out_dir):
    """Швидкість GPS і порівняння прискорень: додаток проти GPS."""
    fig, (ax1, ax2) = plt.subplots(2, 1, figsize=(14, 7), sharex=True,
                                   gridspec_kw={"height_ratios": [1, 2]})
    ax1.plot(check["t"], check["speed"] * 3.6, color="tab:green", linewidth=1.5)
    ax1.set_ylabel("Швидкість GPS, км/год")
    ax1.grid(True, alpha=0.4)
    ax1.set_title(f"Перевірка калібрування за GPS: {trip['name']}  "
                  f"(r = {check['r']:.2f}, нахил = {check['slope']:.2f}, інтервалів: {check['n']})")

    ax2.plot(check["t"], check["a_gps"], color="tab:green", linewidth=1.0, alpha=0.8,
             label="Прискорення за GPS (dv/dt)")
    ax2.plot(check["t"], check["a_app"], color="tab:blue", linewidth=1.4,
             label="Поздовжнє прискорення додатка (відфільтроване)")
    ax2.axhline(0, color="black", linewidth=0.6)
    ax2.set_xlabel("Час від початку запису, с")
    ax2.set_ylabel("Прискорення, м/с²")
    ax2.grid(True, alpha=0.4)
    ax2.legend(loc="upper right")

    fig.tight_layout()
    fig.savefig(os.path.join(out_dir, f"{stem(trip)}_gps_check.png"), dpi=150)
    return fig


def plot_score_evolution(trip, out_dir):
    """Динаміка Safety Score протягом поїздки (лише для файлів з колонкою Score)."""
    ts, scores = trip["score_series"]
    fig, ax = plt.subplots(figsize=(14, 5))

    ax.plot(*_break_gaps(ts, scores), color="tab:blue", linewidth=2.0, drawstyle="steps-post",
            label="Safety Score")
    ax.axhline(SAFE_SCORE_MIN, color="green", linestyle="--", alpha=0.5, label=f"{SAFE_SCORE_MIN}: Безпечний")
    ax.axhline(MEDIUM_SCORE_MIN, color="orange", linestyle="--", alpha=0.5, label=f"{MEDIUM_SCORE_MIN}: Середній")
    for w_start, w_end in trip["calibration_windows"]:
        ax.axvspan(w_start, w_end, color="gray", alpha=0.18, label="Калібрування")

    final = scores[-1] if len(scores) else 100
    ax.set_ylim(max(0, min(70, final - 5)), 102)
    ax.set_title(f"Динаміка Safety Score: {trip['name']} (підсумок: {int(final)}, {classify_score(int(final))})")
    ax.set_xlabel("Час від початку запису, с")
    ax.set_ylabel("Safety Score")
    ax.grid(True, alpha=0.4)
    _unique_legend(ax, loc="lower left")

    fig.tight_layout()
    fig.savefig(os.path.join(out_dir, f"{stem(trip)}_safety_score.png"), dpi=150)
    return fig


def sensitivity_counts(trips):
    """Кількість маневрів для кожного порога і alpha. Повертає (по файлах для ALPHA, сума по alpha)."""
    per_file = {}
    raw_per_file = {}
    total = {a: np.zeros(len(THRESHOLDS), dtype=int) for a in ALPHAS}
    for trip in trips:
        raw_per_file[trip["name"]] = np.array(
            [len(detect_maneuvers(trip["t"], trip["raw"], th)) for th in THRESHOLDS])
        counts = []
        for a in ALPHAS:
            ya = trip["y"] if a == ALPHA else apply_filter(trip["raw"], a)
            row = np.array([len(detect_maneuvers(trip["t"], ya, th)) for th in THRESHOLDS])
            total[a] += row
            if a == ALPHA:
                counts = row
        per_file[trip["name"]] = counts
    return per_file, total, raw_per_file


def _style_count_axis(ax, title, margin, **legend_kwargs):
    """Оформлення осі з кількістю маневрів."""
    ax.axvline(THRESHOLD, color="red", linestyle="--", alpha=0.6, label=f"Поточний поріг {THRESHOLD} G")
    ax.set_title(title)
    ax.set_xlabel("Поріг, G")
    ax.set_ylabel("Виявлено маневрів")
    ax.yaxis.set_major_locator(MaxNLocator(integer=True, min_n_ticks=3))
    top = max([float(np.max(line.get_ydata())) for line in ax.get_lines()
               if len(line.get_ydata()) > 1 and line.get_linestyle() != "--"] + [1.0])
    ax.set_ylim(-0.04 * top, top * (1.0 + margin))   # кількість подій не буває від'ємною
    ax.grid(True, alpha=0.4)
    _unique_legend(ax, **legend_kwargs)


def plot_threshold_sensitivity(trips, out_dir):
    per_file, total, raw_per_file = sensitivity_counts(trips)
    fig, (ax1, ax2) = plt.subplots(1, 2, figsize=(14, 5.5))

    for name, counts in per_file.items():
        line, = ax1.plot(THRESHOLDS, counts, marker="o", label=f"{name} (з фільтром)")
        ax1.plot(THRESHOLDS, raw_per_file[name], marker="x", linestyle=":", color=line.get_color(),
                 label=f"{name} (без фільтра)")
    _style_count_axis(ax1, f"Кількість маневрів залежно від порога (alpha={ALPHA})", 0.25, fontsize=7)

    for a in ALPHAS:
        ax2.plot(THRESHOLDS, total[a], marker="o", linewidth=2.2 if a == ALPHA else 1.2, label=f"alpha = {a}")
    _style_count_axis(ax2, "Сума по всіх поїздках для різних alpha", 0.15)

    fig.tight_layout()
    fig.savefig(os.path.join(out_dir, "threshold_sensitivity.png"), dpi=150)
    return fig


def plot_distribution(trips, out_dir):
    values = np.concatenate([trip["y"] for trip in trips])
    share = 100.0 * np.mean(np.abs(values) > THRESHOLD)

    fig, ax = plt.subplots(figsize=(11, 5.5))
    ax.hist(values, bins=80, color="tab:blue", alpha=0.8)
    ax.set_yscale("log")
    ax.axvline(THRESHOLD, color="red", linestyle="--", label=f"Поріг ±{THRESHOLD} G")
    ax.axvline(-THRESHOLD, color="red", linestyle="--")
    ax.set_title(f"Розподіл відфільтрованого прискорення ({len(values)} вимірів, "
                 f"{share:.2f}% за модулем вище порога)")
    ax.set_xlabel("Відфільтроване прискорення по осі Y, G")
    ax.set_ylabel("Кількість вимірів (логарифмічна шкала)")
    ax.grid(True, alpha=0.4)
    _unique_legend(ax)

    fig.tight_layout()
    fig.savefig(os.path.join(out_dir, "distribution.png"), dpi=150)
    return fig


# ======================================================================
# Підсумки
# ======================================================================

def stem(trip):
    return os.path.splitext(trip["name"])[0]


def summarize(trips):
    rows = []
    for trip in trips:
        t, y, ev = trip["t"], trip["y"], trip["events"]["Event"]
        na = "н/д"  # у старих файлах немає колонки Event чи Score
        logged_brake = int(ev.eq("HardBraking").sum())
        logged_accel = int(ev.eq("HardAcceleration").sum())
        logged_distract = int(ev.eq("Distraction").sum())
        p = trip["params"]
        # Перерахунок з тими параметрами, з якими працював застосунок під час запису
        sim = detect_maneuvers(t, y, p["maneuverThreshold"], p["maneuverCooldown"])
        sim_brake = sum(1 for _, k in sim if k == "HardBraking")
        sim_accel = sum(1 for _, k in sim if k == "HardAcceleration")

        episodes = distraction_episodes(trip["events"])
        episode_seconds = [sum(e - b for b, e in ep) for ep in episodes]
        extra = sum(duration_penalty(sec, p) for sec in episode_seconds)
        has_durations = bool(ev.eq("DistractionEnd").any()) or "distractionDurationStep" in trip["metadata"]
        if trip["has_event_column"]:
            score_computed = safety_score(logged_brake + logged_accel, logged_distract, p, extra)
            score_computed_label = f"{score_computed} ({classify_score(score_computed, p)})"
        else:
            logged_brake = logged_accel = logged_distract = na
            score_computed_label = na

        score_logged = trip["final_score_logged"]
        score_logged_label = (f"{int(score_logged)} ({classify_score(int(score_logged), p)})"
                              if score_logged is not None else na)

        rows.append({
            "Файл": trip["name"],
            "Тривалість, с": round(float(t[-1] - t[0]), 1),
            "Вимірів": len(t),
            "Макс. розгін, G": round(float(np.max(y)), 3),
            "Макс. гальмування, G": round(float(abs(np.min(y))), 3),
            "Гальмувань (лог)": logged_brake,
            "Розгонів (лог)": logged_accel,
            "Відволікань (лог)": logged_distract,
            "Телефон у руках, с": round(sum(episode_seconds), 1) if has_durations else na,
            "Штраф за тривалість": extra if has_durations else na,
            "Дзвінків": count_calls(ev),
            "Гальмувань (перерахунок)": sim_brake,
            "Розгонів (перерахунок)": sim_accel,
            "Час вище порога, %": round(100.0 * float(np.mean(np.abs(y) > p["maneuverThreshold"])), 2),
            "Safety Score (лог)": score_logged_label,
            "Safety Score (розрахунок)": score_computed_label,
            "Кореляція з GPS (r)": round(trip["gps"]["r"], 2) if trip.get("gps") else na,
            "Сирий сигнал": trip["raw_source"],
            "Поріг запису, G": p["maneuverThreshold"],
            "Параметри": ("з файлу, відрізняються від поточних" if trip["params_changed"]
                          else "з файлу" if trip["metadata"] else "поточні (у файлі немає)"),
            "Версія застосунку": trip["metadata"].get("app", na),
        })
    return pd.DataFrame(rows)


def check_consistency(summary):
    """Порівнює події, записані додатком, з перерахунком за тим самим алгоритмом."""
    comparable = summary[summary["Гальмувань (лог)"] != "н/д"]
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

    has_score = comparable[comparable["Safety Score (лог)"] != "н/д"]
    if not has_score.empty:
        score_bad = has_score[has_score["Safety Score (лог)"] != has_score["Safety Score (розрахунок)"]]
        if score_bad.empty:
            print("Перевірка: Safety Score у CSV збігається з розрахунком за формулою.")
        else:
            print("Перевірка: Safety Score у CSV відрізняється від розрахунку за формулою:")
            print(score_bad[["Файл", "Safety Score (лог)", "Safety Score (розрахунок)"]].to_string(index=False))


# ======================================================================
# Точка входу
# ======================================================================

def main():
    parser = argparse.ArgumentParser(description="Аналітика CSV-телеметрії Velox")
    parser.add_argument("folder", nargs="?", default=os.path.dirname(os.path.abspath(__file__)),
                        help="каталог з CSV (за замовчуванням: каталог скрипта)")
    parser.add_argument("--show", action="store_true", help="показати вікна графіків")
    parser.add_argument("--config", help="шлях до VeloxConfig.swift (за замовчуванням шукається автоматично)")
    args = parser.parse_args()

    script_dir = os.path.dirname(os.path.abspath(__file__))
    config_path = args.config or find_config(script_dir)
    if args.config and not os.path.isfile(args.config):
        print(f"Файл конфігурації не знайдено: {args.config}")
        sys.exit(1)
    source = apply_config(config_path)
    print(f"Параметри: {source}")
    print(f"  alpha = {ALPHA}, поріг = {THRESHOLD} G, пауза = {COOLDOWN} с, "
          f"штрафи = -{MANEUVER_PENALTY} / -{DISTRACTION_PENALTY}, "
          f"класи: від {SAFE_SCORE_MIN} / від {MEDIUM_SCORE_MIN}")

    if not args.show:
        plt.switch_backend("Agg")

    folder = os.path.abspath(args.folder)
    csv_files = sorted(glob.glob(os.path.join(folder, "*.csv")))
    if not csv_files:
        print(f"CSV файли не знайдені в каталозі: {folder}")
        print("Покладіть CSV поруч зі скриптом або вкажіть каталог: python analyzer.py шлях/до/каталогу")
        sys.exit(1)

    out_dir = os.path.join(folder, "figures")
    os.makedirs(out_dir, exist_ok=True)

    print(f"--- Аналіз заїздів (каталог: {folder}) ---")
    trips = []
    for path in csv_files:
        trip = load_trip(path)
        if trip is None:
            continue
        trips.append(trip)
        note = f", службових рядків (Distraction, калібрування): {trip['n_extra_rows']}" if trip["n_extra_rows"] else ""
        print(f"Файл: {trip['name']}  (сирий сигнал: {trip['raw_source']}{note})")
        if trip["metadata"]:
            md = trip["metadata"]
            print(f"  -> Записано: Velox {md.get('app', '?')}, {md.get('device', '?')}, {md.get('os', '?')}, "
                  f"поріг {trip['params']['maneuverThreshold']} G")
        print(f"  -> Макс. розгін: {np.max(trip['y']):.3f} G")
        print(f"  -> Макс. гальмування (модуль): {abs(np.min(trip['y'])):.3f} G\n")

        alpha_figs = plot_alpha_comparison(trip, out_dir)
        figs = [plot_raw_vs_filtered(trip, out_dir)]
        figs += alpha_figs if isinstance(alpha_figs, list) else [alpha_figs]
        trip["gps"] = gps_check(trip)
        if trip["gps"] is not None:
            g = trip["gps"]
            print(f"  -> Перевірка за GPS: r = {g['r']:.2f}, нахил = {g['slope']:.2f} ({g['n']} інтервалів)")
            figs.append(plot_gps_check(trip, g, out_dir))
        if trip["score_series"] is not None:
            figs.append(plot_score_evolution(trip, out_dir))
        if not args.show:
            for f in figs:
                plt.close(f)

    if not trips:
        print("Жодного придатного CSV не знайдено.")
        sys.exit(1)

    figs = [plot_threshold_sensitivity(trips, out_dir), plot_distribution(trips, out_dir)]
    if not args.show:
        for f in figs:
            plt.close(f)

    summary = summarize(trips)
    summary.to_csv(os.path.join(out_dir, "summary.csv"), index=False, encoding="utf-8-sig")
    print("--- Підсумок ---")
    print(summary.to_string(index=False))
    print()
    check_consistency(summary)
    print(f"\nГрафіки та summary.csv збережено в: {out_dir}")

    if args.show:
        plt.show()


if __name__ == "__main__":
    main()
