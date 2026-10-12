"""Юніт-тести логіки аналітики. Запуск з каталогу Analytics:
    python -m unittest discover tests
"""

import os
import tempfile
import unittest

import numpy as np

from velox_analytics.config import AppConfig, SWIFT_KEYS, load_config, parse_config
from velox_analytics.events import (calibration_windows, count_calls, distraction_episodes,
                                   distractions_at_call_start, episode_seconds)
from velox_analytics.filtering import apply_filter, count_maneuvers, detect_maneuvers, reconstruct_raw
from velox_analytics.loader import load_trip, read_metadata
from velox_analytics.report import trip_checks, trip_started, write_reports
from velox_analytics.scoring import classify_score, duration_penalty, safety_score, trips_word
from velox_analytics.summary import trip_row

CONFIG = AppConfig()


class ConfigTests(unittest.TestCase):

    def test_parse_swift(self):
        text = """
        static let filterAlpha: Double = 0.25
        static let maneuverPenalty: Int = 3
        static let liveRouteMaxPoints: Int = 2000
        """
        self.assertEqual(parse_config(text), {"filterAlpha": 0.25, "maneuverPenalty": 3})

    def test_real_config_has_all_keys(self):
        # VeloxConfig.swift проєкту має містити всі параметри, які читає аналітика
        here = os.path.dirname(os.path.abspath(__file__))
        for path in (os.path.join(here, "..", "..", "VeloxConfig.swift"),
                     os.path.join(here, "..", "VeloxConfig.swift")):
            if os.path.isfile(path):
                with open(path, encoding="utf-8") as f:
                    self.assertEqual(set(parse_config(f.read())), set(SWIFT_KEYS))
                return
        self.skipTest("VeloxConfig.swift не знайдено")

    def test_defaults_without_file(self):
        config, source = load_config(None)
        self.assertEqual(config, AppConfig())
        self.assertIn("за замовчуванням", source)

    def test_trip_params_from_metadata(self):
        params, changed = CONFIG.for_trip({"maneuverThreshold": "0.35", "maneuverPenalty": "2"})
        self.assertEqual(params.threshold, 0.35)
        self.assertEqual(params.maneuver_penalty, 2)
        self.assertEqual(changed, ["maneuverThreshold: 0.35 (зараз 0.4)"])
        self.assertEqual(CONFIG.threshold, 0.4, "поточні параметри не змінюються")

    def test_alphas_include_app_alpha(self):
        self.assertEqual(AppConfig(alpha=0.15).alphas, [0.1, 0.15, 0.2, 0.3, 0.5])


class FilteringTests(unittest.TestCase):

    def test_filter_formula(self):
        y = apply_filter(np.array([1.0, 1.0, 0.0]), 0.2)
        np.testing.assert_allclose(y, [0.2, 0.36, 0.288])

    def test_reconstruct_is_inverse(self):
        raw = np.random.default_rng(1).normal(0, 0.3, 200)
        np.testing.assert_allclose(reconstruct_raw(apply_filter(raw, 0.2), 0.2), raw, atol=1e-12)

    def test_threshold_is_strict_and_cooldown_per_type(self):
        t = np.array([0.0, 0.1, 1.0, 2.0, 3.5])
        y = np.array([-0.4, -0.5, 0.5, -0.6, -0.6])
        found = detect_maneuvers(t, y, 0.4, 3.0)
        # -0.4 не перевищує поріг; розгін не чекає паузи гальмування; друге гальмування через 3.4 с
        self.assertEqual(found, [(0.1, "HardBraking"), (1.0, "HardAcceleration"), (3.5, "HardBraking")])
        self.assertEqual(count_maneuvers(found), (2, 1))


class EventsTests(unittest.TestCase):

    def test_calibration_windows_include_retry(self):
        events = ["CalibrationStart", "", "CalibrationDone", "CalibrationStart_Auto", "CalibrationFailed",
                  "CalibrationStart_Retry", "CalibrationDone"]
        self.assertEqual(calibration_windows([0, 1, 2, 10, 20, 25, 30], events), [(0.0, 2.0), (10.0, 30.0)])

    def test_distraction_episode_with_resume(self):
        events = {"Timestamp": [10, 15, 16, 20, 40, 45],
                  "Event": ["Distraction", "DistractionEnd", "DistractionResume", "DistractionEnd",
                            "Distraction", "DistractionEnd"]}
        episodes = distraction_episodes(events)
        self.assertEqual(len(episodes), 2)
        self.assertEqual(episode_seconds(episodes), [9.0, 5.0])

    def test_distraction_right_after_handsfree_call(self):
        # Поїздка 12.10.2026: CarPlay-дзвінок на 38.98 с, відволікання на 39.18 с
        events = {"Timestamp": [38.98, 39.18, 48.37, 60.0, 70.0],
                  "Event": ["CallStart", "Distraction", "CallEnd", "CallStart_Handheld", "Distraction"]}
        found = distractions_at_call_start(events, 2.0)
        self.assertEqual(len(found), 1)
        self.assertAlmostEqual(found[0][1], 0.2, places=6)

    def test_calls(self):
        self.assertEqual(count_calls(["CallIncoming", "CallStart", "CallEnd", "CallStart_Handheld", "CallEnd"]), 2)


class ScoringTests(unittest.TestCase):

    def test_duration_penalty(self):
        self.assertEqual([duration_penalty(s, CONFIG) for s in (0, 9.9, 10, 35, 300)], [0, 0, 1, 3, 5])

    def test_score_and_class(self):
        self.assertEqual(safety_score(2, 1, CONFIG, extra=1), 90)
        self.assertEqual(safety_score(100, 0, CONFIG), 0)
        self.assertEqual([classify_score(s, CONFIG) for s in (90, 75, 74)],
                         ["Безпечний", "Середній", "Небезпечний"])

    def test_trips_word(self):
        self.assertEqual([trips_word(n) for n in (1, 2, 5, 11, 21, 22)],
                         ["поїздку", "поїздки", "поїздок", "поїздок", "поїздку", "поїздки"])


class LoaderTests(unittest.TestCase):

    def write(self, text):
        f = tempfile.NamedTemporaryFile("w", suffix=".csv", delete=False, encoding="utf-8")
        f.write(text)
        f.close()
        self.addCleanup(os.remove, f.name)
        return f.name

    def test_format3_with_service_rows(self):
        rows = ["# format=3", "# maneuverThreshold=0.35",
                "Timestamp,Filtered_Y,Event,Raw_Y,Score,Speed_mps,Lat,Lon",
                "0.0,0,CalibrationStart,0,100,,,",
                "2.0,0,CalibrationDone,0,100,0,48.29,25.93"]
        rows += [f"{2 + i / 10:.1f},0.1,,0.1,100,1,48.29,25.93" for i in range(1, 6)]
        rows += ["2.55,0.1,Distraction,0.1,95,1,,", "2.6,0.1,,0.1,95,1,48.2901,25.93"]
        path = self.write("\n".join(rows) + "\n")
        self.assertEqual(read_metadata(path), ({"format": "3", "maneuverThreshold": "0.35"}, 2))

        trip = load_trip(path, CONFIG)
        self.assertEqual(len(trip.t), 6, "калібрування і окремий рядок Distraction - не виміри")
        self.assertEqual(trip.n_extra_rows, 3)
        self.assertEqual(trip.params.threshold, 0.35)
        self.assertTrue(trip.params_changed)
        self.assertEqual(trip.raw_source, "записаний у CSV")
        self.assertEqual(trip.final_score_logged, 95)
        self.assertEqual(trip.segment_kind, {1: "gps"})
        # перший рядок без координат не входить у маршрут, а Distraction стає на останню точку
        self.assertEqual(len(trip.route), 8)
        self.assertEqual(trip.route[trip.route["Event"] == "Distraction"]["Lat"].iloc[0], 48.29)

    def test_old_format_reconstructs_raw(self):
        raw = np.array([0.0, 0.5, -0.3, 0.2])
        y = apply_filter(raw, 0.2)
        path = self.write("Timestamp,Filtered_Y\n" + "\n".join(f"{i / 10},{float(v)!r}" for i, v in enumerate(y)) + "\n")
        trip = load_trip(path, CONFIG)
        np.testing.assert_allclose(trip.raw, raw, atol=1e-12)
        self.assertFalse(trip.has_event_column)

    def test_rejects_unrelated_csv(self):
        self.assertIsNone(load_trip(self.write("a,b\n1,2\n"), CONFIG))


CARPLAY_TRIP = ["# format=3", "# started=2026-10-12T14:45:36+03:00", "# maneuverThreshold=0.4",
                "Timestamp,Filtered_Y,Event,Raw_Y,Score,Speed_mps",
                "0.0,0,CalibrationStart,0,100,", "2.0,0,CalibrationDone,0,100,5"]
CARPLAY_TRIP += [f"{2 + i / 10:.1f},0.01,,0.01,100,5" for i in range(1, 40)]
CARPLAY_TRIP += ["5.95,0.01,CallStart,0.01,100,5", "6.0,0.01,Distraction,0.01,95,5", "9.0,0.01,CallEnd,0.01,95,5",
                 "9.5,0.01,DistractionEnd,0.01,95,5", "9.6,0.01,,0.01,95,5"]


class ReportTests(unittest.TestCase):

    def setUp(self):
        self.dir = tempfile.mkdtemp()
        self.path = os.path.join(self.dir, "Velox_Data_2026-10-12_14-45-36.csv")
        with open(self.path, "w", encoding="utf-8") as f:
            f.write("\n".join(CARPLAY_TRIP) + "\n")
        self.trip = load_trip(self.path, CONFIG)

    def tearDown(self):
        import shutil
        shutil.rmtree(self.dir)

    def test_checks(self):
        checks = {c.title: c.status for c in trip_checks(self.trip, trip_row(self.trip))}
        self.assertEqual(checks["Маневри в CSV збігаються з перерахунком"], "ok")
        self.assertEqual(checks["Safety Score збігається з формулою"], "ok")
        self.assertEqual(checks["Відволікання на початку розмови без рук"], "warn")
        self.assertEqual(checks["Калібрування за GPS не перевірено"], "info")

    def test_started_from_metadata_or_name(self):
        self.assertEqual(trip_started(self.trip).strftime("%d.%m.%Y %H:%M"), "12.10.2026 14:45")
        self.trip.metadata.pop("started")
        self.assertEqual(trip_started(self.trip).strftime("%H:%M:%S"), "14:45:36")

    def test_pages_written(self):
        index = write_reports([self.trip], CONFIG, "VeloxConfig.swift", None, self.dir)
        with open(index, encoding="utf-8") as f:
            text = f.read()
        self.assertIn('href="Velox_Data_2026-10-12_14-45-36.html"', text)
        with open(os.path.join(self.dir, "Velox_Data_2026-10-12_14-45-36.html"), encoding="utf-8") as f:
            page = f.read()
        self.assertIn("Поїздка 12.10.2026, 14:45", page)
        self.assertIn("CallStart", page)


if __name__ == "__main__":
    unittest.main()
