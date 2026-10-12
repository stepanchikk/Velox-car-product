"""Спільне оформлення графіків."""

import os

import numpy as np

EVENT_STYLE = {
    "HardBraking": ("v", "red", "Різке гальмування"),
    "HardAcceleration": ("^", "darkorange", "Агресивний розгін"),
}
DISTRACTION_COLOR = "purple"
CALL_COLOR = "teal"
RAW_COLOR = "#b5b5b5"
DPI = 150


def unique_legend(ax, **kwargs):
    """Легенда без дублікатів. Викликається ПІСЛЯ побудови всіх ліній і порогів."""
    handles, labels = ax.get_legend_handles_labels()
    seen = {}
    for handle, label in zip(handles, labels):
        if label and not label.startswith("_") and label not in seen:
            seen[label] = handle
    ax.legend(seen.values(), seen.keys(), **kwargs)


def break_gaps(t, *series, max_gap=1.0):
    """Вставляє NaN у місцях розриву даних (калібрування, фон), щоб лінія не зʼєднувала їх."""
    idx = np.where(np.diff(t) > max_gap)[0] + 1
    if len(idx) == 0:
        return (t,) + series
    return tuple(np.insert(np.asarray(a, dtype=float), idx, np.nan) for a in (t,) + series)


def draw_threshold(ax, threshold):
    """Пунктирні лінії порога ±threshold."""
    ax.axhline(threshold, color="red", linestyle="--", alpha=0.5, label=f"Поріг ±{threshold} G")
    ax.axhline(-threshold, color="red", linestyle="--", alpha=0.5)


def shade_calibration(ax, windows):
    for start, end in windows:
        ax.axvspan(start, end, color="gray", alpha=0.18, label="Калібрування")


def save(fig, out_dir, file_name):
    fig.tight_layout()
    fig.savefig(os.path.join(out_dir, file_name), dpi=DPI)
    return fig


def finish_trip_plot(fig, ax, title, out_dir, file_name):
    """Підписи, сітка, легенда і збереження для графіків окремої поїздки."""
    ax.set_title(title)
    ax.set_xlabel("Час від початку запису, с")
    ax.set_ylabel("Прискорення по осі Y, G")
    ax.grid(True, alpha=0.4)
    unique_legend(ax, loc="upper right")
    return save(fig, out_dir, file_name)
