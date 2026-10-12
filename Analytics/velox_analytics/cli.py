"""Командний рядок: python analyzer.py [каталог] [--show] [--config шлях]."""

import argparse
import glob
import os
import sys

import matplotlib.pyplot as plt
import numpy as np

from .checks import gps_check, trip_distance_km, yaw_check
from .config import find_config, load_config
from .loader import load_trip
from .plots import overview, trip_plots
from .report import write_reports
from .scoring import driver_rating, trips_word
from .summary import check_consistency, summarize


def parse_args(argv, script_dir):
    parser = argparse.ArgumentParser(description="Аналітика CSV-телеметрії Velox")
    parser.add_argument("folder", nargs="?", default=script_dir,
                        help="каталог з CSV (за замовчуванням: каталог скрипта)")
    parser.add_argument("--show", action="store_true", help="показати вікна графіків")
    parser.add_argument("--config", help="шлях до VeloxConfig.swift (за замовчуванням шукається автоматично)")
    return parser.parse_args(argv)


def analyze_trip(trip, config, out_dir):
    """Друкує короткий звіт про поїздку, виконує перевірки і будує її графіки.
    Повертає список рисунків."""
    note = f", службових рядків (Distraction, калібрування): {trip.n_extra_rows}" if trip.n_extra_rows else ""
    print(f"Файл: {trip.name}  (сирий сигнал: {trip.raw_source}{note})")
    if trip.metadata:
        md = trip.metadata
        print(f"  -> Записано: Velox {md.get('app', '?')}, {md.get('device', '?')}, {md.get('os', '?')}, "
              f"поріг {trip.params.threshold} G")
    print(f"  -> Макс. розгін: {np.max(trip.y):.3f} G")
    print(f"  -> Макс. гальмування (модуль): {abs(np.min(trip.y)):.3f} G\n")

    alpha_figures = trip_plots.alpha_comparison(trip, config, out_dir)
    figures = [trip_plots.raw_vs_filtered(trip, config, out_dir)] + alpha_figures

    trip.gps = gps_check(trip)
    if trip.gps is not None:
        g = trip.gps
        print(f"  -> Перевірка за GPS: r = {g.r:.2f}, нахил = {g.slope:.2f} ({g.n} інтервалів)")
        figures.append(trip_plots.gps_check(trip, g, out_dir))
    if trip.score_series is not None:
        figures.append(trip_plots.score_evolution(trip, config, out_dir))

    trip.yaw = yaw_check(trip)
    if trip.yaw is not None:
        yc = trip.yaw
        angle = f"{yc.angle:.1f}°" if yc.angle is not None else "н/д"
        state = "рішення прийнято" if yc.decided else "поворотів замало для рішення"
        print(f"  -> Напрям за поворотами проти GPS: похибка {angle} "
              f"(енергія {yc.energy:.1f}, узгодженість {yc.consistency:.2f}, {state})")

    trip.distance_km = trip_distance_km(trip)
    if trip.route is not None:
        figures.append(trip_plots.route(trip, out_dir))
    return figures


def close_unless_shown(figures, show):
    """Без --show рисунки закриваються одразу, щоб не тримати їх у памʼяті."""
    if not show:
        for fig in figures:
            plt.close(fig)


def main(argv=None, script_dir=None):
    script_dir = script_dir or os.getcwd()
    args = parse_args(argv, script_dir)

    if args.config and not os.path.isfile(args.config):
        print(f"Файл конфігурації не знайдено: {args.config}")
        sys.exit(1)
    config, source = load_config(args.config or find_config(script_dir))
    print(f"Параметри: {source}")
    print(f"  {config.describe()}")

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
        trip = load_trip(path, config)
        if trip is None:
            continue
        trips.append(trip)
        close_unless_shown(analyze_trip(trip, config, out_dir), args.show)

    if not trips:
        print("Жодного придатного CSV не знайдено.")
        sys.exit(1)

    close_unless_shown([overview.threshold_sensitivity(trips, config, out_dir),
                        overview.distribution(trips, config, out_dir)], args.show)

    summary = summarize(trips)
    summary.to_csv(os.path.join(out_dir, "summary.csv"), index=False, encoding="utf-8-sig")
    print("--- Підсумок ---")
    print(summary.to_string(index=False))
    print()
    check_consistency(summary)
    rating = driver_rating(trips, config)
    if rating is not None:
        value, count, km = rating
        print(f"Оцінка водія (як на головній): {value} за {count} {trips_word(count)}, "
              f"штрафи на {config.rating_distance_km:g} км, пробіг для розрахунку {km:.1f} км")
    report = write_reports(trips, config, source, rating, out_dir)
    print(f"\nГрафіки та summary.csv збережено в: {out_dir}")
    print(f"HTML-звіт: {report}")

    if args.show:
        plt.show()
