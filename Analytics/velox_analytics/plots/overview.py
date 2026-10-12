"""Графіки за всіма поїздками: чутливість до порога і розподіл прискорень."""

import matplotlib.pyplot as plt
import numpy as np
from matplotlib.ticker import MaxNLocator

from ..config import THRESHOLDS
from ..summary import sensitivity_counts
from .common import save, unique_legend


def _style_count_axis(ax, title, threshold, margin, **legend_kwargs):
    """Оформлення осі з кількістю маневрів."""
    ax.axvline(threshold, color="red", linestyle="--", alpha=0.6, label=f"Поточний поріг {threshold} G")
    ax.set_title(title)
    ax.set_xlabel("Поріг, G")
    ax.set_ylabel("Виявлено маневрів")
    ax.yaxis.set_major_locator(MaxNLocator(integer=True, min_n_ticks=3))
    top = max([float(np.max(line.get_ydata())) for line in ax.get_lines()
               if len(line.get_ydata()) > 1 and line.get_linestyle() != "--"] + [1.0])
    ax.set_ylim(-0.04 * top, top * (1.0 + margin))   # кількість подій не буває відʼємною
    ax.grid(True, alpha=0.4)
    unique_legend(ax, **legend_kwargs)


def threshold_sensitivity(trips, config, out_dir):
    """Ліворуч - кожна поїздка з фільтром і без, праворуч - сума для різних alpha.
    Обґрунтовує поріг: з фільтром кількість маневрів на спокійній їзді близька до нуля."""
    per_file, total, raw_per_file = sensitivity_counts(trips, config)
    fig, (ax1, ax2) = plt.subplots(1, 2, figsize=(14, 5.5))

    for name, counts in per_file.items():
        line, = ax1.plot(THRESHOLDS, counts, marker="o", label=f"{name} (з фільтром)")
        ax1.plot(THRESHOLDS, raw_per_file[name], marker="x", linestyle=":", color=line.get_color(),
                 label=f"{name} (без фільтра)")
    _style_count_axis(ax1, f"Кількість маневрів залежно від порога (alpha={config.alpha})",
                      config.threshold, 0.25, fontsize=7)

    for a in config.alphas:
        ax2.plot(THRESHOLDS, total[a], marker="o", linewidth=2.2 if a == config.alpha else 1.2,
                 label=f"alpha = {a}")
    _style_count_axis(ax2, "Сума по всіх поїздках для різних alpha", config.threshold, 0.15)
    return save(fig, out_dir, "threshold_sensitivity.png")


def distribution(trips, config, out_dir):
    """Гістограма відфільтрованого прискорення всіх поїздок (логарифмічна шкала)."""
    values = np.concatenate([trip.y for trip in trips])
    share = 100.0 * np.mean(np.abs(values) > config.threshold)

    fig, ax = plt.subplots(figsize=(11, 5.5))
    ax.hist(values, bins=80, color="tab:blue", alpha=0.8)
    ax.set_yscale("log")
    ax.axvline(config.threshold, color="red", linestyle="--", label=f"Поріг ±{config.threshold} G")
    ax.axvline(-config.threshold, color="red", linestyle="--")
    ax.set_title(f"Розподіл відфільтрованого прискорення ({len(values)} вимірів, "
                 f"{share:.2f}% за модулем вище порога)")
    ax.set_xlabel("Відфільтроване прискорення по осі Y, G")
    ax.set_ylabel("Кількість вимірів (логарифмічна шкала)")
    ax.grid(True, alpha=0.4)
    unique_legend(ax)
    return save(fig, out_dir, "distribution.png")
