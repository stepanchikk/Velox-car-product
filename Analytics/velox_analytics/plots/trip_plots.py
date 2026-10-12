"""Графіки окремої поїздки. Кожна функція зберігає PNG у out_dir і повертає рисунок(и).

config - поточні параметри (AppConfig): графіки показують поїздку так, як її
обробив би застосунок зараз.
"""

import matplotlib.pyplot as plt
import numpy as np

from ..events import distraction_episodes
from ..scoring import classify_score
from .common import (CALL_COLOR, DISTRACTION_COLOR, EVENT_STYLE, RAW_COLOR, break_gaps, draw_threshold,
                     finish_trip_plot, save, shade_calibration, unique_legend)

ZOOM_MIN_TRIP_S = 120.0    # від якої тривалості будувати додатковий фрагмент
ZOOM_WINDOW_S = 40.0       # довжина фрагмента


def raw_vs_filtered(trip, config, out_dir):
    """Сирий і відфільтрований сигнал з порогом, подіями, калібруванням, відволіканнями і дзвінками."""
    t, events = trip.t, trip.events
    fig, ax = plt.subplots(figsize=(14, 6))

    tp, raw_p, y_p = break_gaps(t, trip.raw, trip.y)
    ax.plot(tp, raw_p, color=RAW_COLOR, linewidth=0.8, label=f"Сирий сигнал ({trip.raw_source})")
    ax.plot(tp, y_p, color="tab:blue", linewidth=1.8, label=f"Відфільтрований (alpha={config.alpha})")
    draw_threshold(ax, config.threshold)

    for ev, (marker, color, label) in EVENT_STYLE.items():
        sub = events[events["Event"] == ev]
        if len(sub):
            ax.scatter(sub["Timestamp"], sub["Filtered_Y"], marker=marker, color=color,
                       s=90, zorder=5, edgecolor="black", label=label)
    shade_calibration(ax, trip.calibration_windows)
    for ts in events[events["Event"] == "Distraction"]["Timestamp"]:
        ax.axvline(ts, color=DISTRACTION_COLOR, linestyle=":", linewidth=1.6, alpha=0.9,
                   label="Відволікання (Anti-Fraud)")
    for episode in distraction_episodes(events):
        for start, end in episode:
            ax.axvspan(start, end, color=DISTRACTION_COLOR, alpha=0.12, label="Телефон у руках")
    for ts in events[events["Event"] == "CalibrationDirectionFix"]["Timestamp"]:
        ax.axvline(ts, color="black", linestyle="--", linewidth=1.2, alpha=0.7,
                   label="Напрям руху виправлено за поворотами (без GPS)")
    for ts in events[events["Event"].str.startswith("Call")]["Timestamp"]:
        ax.axvline(ts, color=CALL_COLOR, linestyle="-.", linewidth=1.2, alpha=0.8,
                   label="Дзвінок (без штрафу, якщо без рук)")

    return finish_trip_plot(fig, ax, f"Сира та відфільтрована телеметрія: {trip.name}",
                            out_dir, f"{trip.stem}_raw_vs_filtered.png")


def zoom_window(t, raw, width=ZOOM_WINDOW_S):
    """Фрагмент довжиною width с, де сирий сигнал найбільш мінливий."""
    step = max(1, int(round(1.0 / max(np.median(np.diff(t)), 1e-3))))   # ~1 с
    starts = np.arange(t[0], t[-1] - width, step * 0.5 + 1e-9)
    if len(starts) == 0:
        return float(t[0]), float(t[-1])
    scores = []
    for s0 in starts:
        sel = (t >= s0) & (t < s0 + width)
        scores.append(np.std(raw[sel]) if sel.sum() > 10 else 0.0)
    s0 = float(starts[int(np.argmax(scores))])
    return s0, s0 + width


def _plot_alphas(ax, trip, config, sel, app_width, other_width):
    """Лінії сигналу для кожного alpha; повертає найбільше значення за модулем."""
    peak = 0.0
    for a in config.alphas:
        ya = trip.smoothed(a, config.alpha)[sel]
        peak = max(peak, float(np.max(np.abs(ya))))
        is_app = a == config.alpha
        ax.plot(*break_gaps(trip.t[sel], ya), linewidth=app_width if is_app else other_width,
                label=f"alpha = {a}" + (" (у додатку)" if is_app else ""))
    return peak


def alpha_comparison(trip, config, out_dir):
    """Вплив коефіцієнта фільтра на всю поїздку і, для довгих поїздок, на
    фрагмент з найбільшою активністю (на повному графіку лінії зливаються)."""
    t, raw = trip.t, trip.raw
    everything = np.ones(len(t), dtype=bool)

    fig, ax = plt.subplots(figsize=(14, 6))
    ax.plot(*break_gaps(t, raw), color="#c8c8c8", linewidth=0.7, label="Сирий сигнал")
    peak = _plot_alphas(ax, trip, config, everything, 2.2, 1.2)
    draw_threshold(ax, config.threshold)
    limit = max(0.6, 1.3 * peak)
    ax.set_ylim(-limit, limit)
    figures = [finish_trip_plot(fig, ax, f"Вплив коефіцієнта alpha на згладжування: {trip.name}",
                                out_dir, f"{trip.stem}_alpha_comparison.png")]

    if t[-1] - t[0] > ZOOM_MIN_TRIP_S:
        window = zoom_window(t, raw)
        sel = (t >= window[0]) & (t <= window[1])
        fig2, ax2 = plt.subplots(figsize=(14, 6))
        ax2.plot(*break_gaps(t[sel], raw[sel]), color="#c8c8c8", linewidth=0.9, label="Сирий сигнал")
        _plot_alphas(ax2, trip, config, sel, 2.4, 1.3)
        draw_threshold(ax2, config.threshold)
        ax2.set_xlim(window)
        zoom_limit = max(0.6, 1.2 * float(np.max(np.abs(raw[sel]))))
        ax2.set_ylim(-zoom_limit, zoom_limit)
        figures.append(finish_trip_plot(
            fig2, ax2, f"Вплив alpha, фрагмент {window[0]:.0f}-{window[1]:.0f} с (найбільша активність): {trip.name}",
            out_dir, f"{trip.stem}_alpha_comparison_zoom.png"))
    return figures


def gps_check(trip, check, out_dir):
    """Швидкість GPS і порівняння прискорень: застосунок проти GPS."""
    fig, (ax1, ax2) = plt.subplots(2, 1, figsize=(14, 7), sharex=True,
                                   gridspec_kw={"height_ratios": [1, 2]})
    ax1.plot(check.t, check.speed * 3.6, color="tab:green", linewidth=1.5)
    ax1.set_ylabel("Швидкість GPS, км/год")
    ax1.grid(True, alpha=0.4)
    ax1.set_title(f"Перевірка калібрування за GPS: {trip.name}  "
                  f"(r = {check.r:.2f}, нахил = {check.slope:.2f}, інтервалів: {check.n})")

    ax2.plot(check.t, check.a_gps, color="tab:green", linewidth=1.0, alpha=0.8,
             label="Прискорення за GPS (dv/dt)")
    ax2.plot(check.t, check.a_app, color="tab:blue", linewidth=1.4,
             label="Поздовжнє прискорення додатка (відфільтроване)")
    ax2.axhline(0, color="black", linewidth=0.6)
    ax2.set_xlabel("Час від початку запису, с")
    ax2.set_ylabel("Прискорення, м/с²")
    ax2.grid(True, alpha=0.4)
    ax2.legend(loc="upper right")
    return save(fig, out_dir, f"{trip.stem}_gps_check.png")


def route(trip, out_dir):
    """Маршрут з місцями подій (лише якщо у файлі є координати)."""
    r = trip.route
    # Градус довготи коротший за градус широти в cos(широти) разів;
    # розмір рисунка - за пропорціями маршруту, щоб не було порожніх полів
    k = np.cos(np.radians(r["Lat"].mean()))
    width = max(float(r["Lon"].max() - r["Lon"].min()) * k, 1e-6)
    height = max(float(r["Lat"].max() - r["Lat"].min()), 1e-6)
    fig_h = float(np.clip(10 * height / width, 4, 10))
    fig, ax = plt.subplots(figsize=(10, fig_h + 1.2))

    ax.plot(r["Lon"], r["Lat"], color="tab:blue", linewidth=2, label="Маршрут")
    ax.scatter(r["Lon"].iloc[0], r["Lat"].iloc[0], color="green", s=80, zorder=5, label="Старт")
    ax.scatter(r["Lon"].iloc[-1], r["Lat"].iloc[-1], color="black", s=80, zorder=5, label="Фініш")
    for ev, (marker, color, label) in EVENT_STYLE.items():
        sub = r[r["Event"] == ev]
        if len(sub):
            ax.scatter(sub["Lon"], sub["Lat"], marker=marker, color=color, s=110, zorder=6,
                       edgecolor="black", label=label)
    sub = r[r["Event"] == "Distraction"]
    if len(sub):
        ax.scatter(sub["Lon"], sub["Lat"], marker="X", color=DISTRACTION_COLOR, s=110, zorder=6,
                   edgecolor="black", label="Відволікання")

    ax.set_aspect(1 / k)
    ax.ticklabel_format(useOffset=False, style="plain")   # повні координати замість «+4.826e1»
    ax.set_title(f"Маршрут: {trip.name}")
    ax.set_xlabel("Довгота, градуси")
    ax.set_ylabel("Широта, градуси")
    ax.grid(True, alpha=0.4)
    unique_legend(ax, loc="best")
    return save(fig, out_dir, f"{trip.stem}_route.png", crop=True)


def score_evolution(trip, config, out_dir):
    """Динаміка Safety Score протягом поїздки (лише для файлів з колонкою Score)."""
    ts, scores = trip.score_series
    fig, ax = plt.subplots(figsize=(14, 5))

    ax.plot(*break_gaps(ts, scores), color="tab:blue", linewidth=2.0, drawstyle="steps-post",
            label="Safety Score")
    ax.axhline(config.safe_score_min, color="green", linestyle="--", alpha=0.5,
               label=f"{config.safe_score_min}: Безпечний")
    ax.axhline(config.medium_score_min, color="orange", linestyle="--", alpha=0.5,
               label=f"{config.medium_score_min}: Середній")
    shade_calibration(ax, trip.calibration_windows)

    final = scores[-1] if len(scores) else 100
    ax.set_ylim(max(0, min(70, final - 5)), 102)
    ax.set_title(f"Динаміка Safety Score: {trip.name} "
                 f"(підсумок: {int(final)}, {classify_score(int(final), config)})")
    ax.set_xlabel("Час від початку запису, с")
    ax.set_ylabel("Safety Score")
    ax.grid(True, alpha=0.4)
    unique_legend(ax, loc="lower left")
    return save(fig, out_dir, f"{trip.stem}_safety_score.png")
