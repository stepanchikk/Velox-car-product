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
import sys

import numpy as np
import pandas as pd
import matplotlib.pyplot as plt
from matplotlib.ticker import MaxNLocator

# ---------- Параметри, що відповідають додатку ----------
ALPHA = 0.2            # коефіцієнт Low-Pass фільтра в SensorManager
THRESHOLD = 0.4        # поріг маневру, G
COOLDOWN = 3.0         # пауза між двома маневрами, с

# ---------- Параметри аналізу ----------
ALPHAS = [0.1, 0.2, 0.3, 0.5]
THRESHOLDS = np.round(np.arange(0.20, 0.601, 0.05), 2)

EVENT_STYLE = {
    "HardBraking": ("v", "red", "Різке гальмування"),
    "HardAcceleration": ("^", "darkorange", "Агресивний розгін"),
}
DISTRACTION_COLOR = "purple"


# ======================================================================
# Завантаження та підготовка даних
# ======================================================================

def load_trip(path):
    """Читає CSV поїздки. Повертає словник з даними або None, якщо файл не підходить."""
    try:
        df = pd.read_csv(path)
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
    df = df.dropna(subset=["Timestamp", "Filtered_Y"]).reset_index(drop=True)

    if len(df) < 3:
        print(f"  Пропуск {os.path.basename(path)}: замало даних ({len(df)} рядків)")
        return None

    # Події (для позначок на графіку) беремо з усіх рядків
    events = df[df["Event"] != ""][["Timestamp", "Event", "Filtered_Y"]].copy()
    calibration_windows = find_calibration_windows(df)

    # Нова версія додатка пише подію Distraction окремим рядком між вимірами.
    # Такий рядок повторює Filtered_Y попереднього рядка, тому його можна відсіяти,
    # щоб не псувати відновлення сирого сигналу.
    same_as_prev = df["Filtered_Y"].eq(df["Filtered_Y"].shift(1))
    is_calibration = df["Event"].str.startswith("Calibration")
    is_extra = (df["Event"].eq("Distraction") & same_as_prev) | is_calibration
    motion = df[~is_extra].reset_index(drop=True)

    t = motion["Timestamp"].to_numpy(dtype=float)
    y = motion["Filtered_Y"].to_numpy(dtype=float)

    if has_raw and motion["Raw_Y"].notna().all():
        raw = motion["Raw_Y"].to_numpy(dtype=float)
        raw_source = "записаний у CSV"
    else:
        raw = reconstruct_raw(y, ALPHA)
        raw_source = f"відновлений (alpha={ALPHA})"

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
        "has_event_column": has_event_column,
        "n_extra_rows": int(np.count_nonzero(is_extra)),
    }


def find_calibration_windows(df):
    """Проміжки калібрування: від CalibrationStart* до наступного CalibrationDone."""
    windows = []
    start = None
    for ts, ev in zip(df["Timestamp"], df["Event"]):
        if ev.startswith("CalibrationStart"):
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


def detect_maneuvers(t, y, threshold, cooldown=COOLDOWN):
    """Повторює логіку detectManeuvers з додатка: поріг + пауза між подіями."""
    found = []
    last = -np.inf
    for ti, yi in zip(t, y):
        if ti - last < cooldown:
            continue
        if yi < -threshold:
            found.append((ti, "HardBraking"))
            last = ti
        elif yi > threshold:
            found.append((ti, "HardAcceleration"))
            last = ti
    return found


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

    return _finish_trip_plot(fig, ax, f"Сира та відфільтрована телеметрія: {trip['name']}",
                             os.path.join(out_dir, f"{stem(trip)}_raw_vs_filtered.png"))


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
    return _finish_trip_plot(fig, ax, f"Вплив коефіцієнта alpha на згладжування: {trip['name']}",
                             os.path.join(out_dir, f"{stem(trip)}_alpha_comparison.png"))


def sensitivity_counts(trips):
    """Кількість маневрів для кожного порога і alpha. Повертає (по файлах для ALPHA, сума по alpha)."""
    per_file = {}
    total = {a: np.zeros(len(THRESHOLDS), dtype=int) for a in ALPHAS}
    for trip in trips:
        counts = []
        for a in ALPHAS:
            ya = trip["y"] if a == ALPHA else apply_filter(trip["raw"], a)
            row = np.array([len(detect_maneuvers(trip["t"], ya, th)) for th in THRESHOLDS])
            total[a] += row
            if a == ALPHA:
                counts = row
        per_file[trip["name"]] = counts
    return per_file, total


def _style_count_axis(ax, title, margin, **legend_kwargs):
    """Оформлення осі з кількістю маневрів."""
    ax.axvline(THRESHOLD, color="red", linestyle="--", alpha=0.6, label=f"Поточний поріг {THRESHOLD} G")
    ax.set_title(title)
    ax.set_xlabel("Поріг, G")
    ax.set_ylabel("Виявлено маневрів")
    ax.yaxis.set_major_locator(MaxNLocator(integer=True))
    ax.margins(y=margin)
    ax.grid(True, alpha=0.4)
    _unique_legend(ax, **legend_kwargs)


def plot_threshold_sensitivity(trips, out_dir):
    per_file, total = sensitivity_counts(trips)
    fig, (ax1, ax2) = plt.subplots(1, 2, figsize=(14, 5.5))

    for name, counts in per_file.items():
        ax1.plot(THRESHOLDS, counts, marker="o", label=name)
    _style_count_axis(ax1, f"Кількість маневрів залежно від порога (alpha={ALPHA})", 0.25, fontsize=8)

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
        logged_brake = int(ev.eq("HardBraking").sum())
        logged_accel = int(ev.eq("HardAcceleration").sum())
        sim = detect_maneuvers(t, y, THRESHOLD)
        sim_brake = sum(1 for _, k in sim if k == "HardBraking")
        sim_accel = sum(1 for _, k in sim if k == "HardAcceleration")
        na = "н/д"  # у старих файлах немає колонки Event
        if not trip["has_event_column"]:
            logged_brake = logged_accel = na
        rows.append({
            "Файл": trip["name"],
            "Тривалість, с": round(float(t[-1] - t[0]), 1),
            "Вимірів": len(t),
            "Макс. розгін, G": round(float(np.max(y)), 3),
            "Макс. гальмування, G": round(float(abs(np.min(y))), 3),
            "Гальмувань (лог)": logged_brake,
            "Розгонів (лог)": logged_accel,
            "Відволікань (лог)": na if not trip["has_event_column"] else int(ev.eq("Distraction").sum()),
            "Гальмувань (перерахунок)": sim_brake,
            "Розгонів (перерахунок)": sim_accel,
            "Час вище порога, %": round(100.0 * float(np.mean(np.abs(y) > THRESHOLD)), 2),
            "Сирий сигнал": trip["raw_source"],
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
              "(можливо, змінювався поріг у додатку або паузи виміряні по годиннику):")
        print(bad[["Файл", "Гальмувань (лог)", "Гальмувань (перерахунок)",
                   "Розгонів (лог)", "Розгонів (перерахунок)"]].to_string(index=False))


# ======================================================================
# Точка входу
# ======================================================================

def main():
    parser = argparse.ArgumentParser(description="Аналітика CSV-телеметрії Velox")
    parser.add_argument("folder", nargs="?", default=os.path.dirname(os.path.abspath(__file__)),
                        help="каталог з CSV (за замовчуванням: каталог скрипта)")
    parser.add_argument("--show", action="store_true", help="показати вікна графіків")
    args = parser.parse_args()

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
        print(f"  -> Макс. розгін: {np.max(trip['y']):.3f} G")
        print(f"  -> Макс. гальмування (модуль): {abs(np.min(trip['y'])):.3f} G\n")

        figs = [plot_raw_vs_filtered(trip, out_dir), plot_alpha_comparison(trip, out_dir)]
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
