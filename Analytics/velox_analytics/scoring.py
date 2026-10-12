"""Safety Score, клас безпеки і оцінка водія (як SafetyScore.swift і Achievements.swift)."""


def duration_penalty(seconds, config):
    """Штраф за тривалість одного відволікання: duration_penalty балів за кожні
    duration_step с, не більше duration_penalty_max."""
    if seconds <= 0:
        return 0
    return min(config.duration_penalty_max, int(seconds // config.duration_step) * config.duration_penalty)


def safety_score(maneuvers, distractions, config, extra=0):
    """100 мінус штрафи, не менше 0. extra - сумарний штраф за тривалість відволікань."""
    penalty = config.maneuver_penalty * maneuvers + config.distraction_penalty * distractions + extra
    return max(0, 100 - penalty)


def classify_score(score, config):
    if score >= config.safe_score_min:
        return "Безпечний"
    if score >= config.medium_score_min:
        return "Середній"
    return "Небезпечний"


def driver_rating(trips, config, window=10):
    """Оцінка водія як на головній (DrivingStats.rating).

    Штрафи останніх window поїздок перераховуються на rating_distance_km км пробігу,
    щоб довга поїздка не програвала короткій. Без GPS відстань оцінюється за
    тривалістю з rating_fallback_speed_kmh. Повертає (оцінка, поїздок, км) або None."""
    scored = [trip for trip in trips if trip.final_score_logged is not None][-window:]
    if not scored:
        return None
    penalties = sum(100 - trip.final_score_logged for trip in scored)
    exposure = 0.0
    for trip in scored:
        km = trip.distance_km
        exposure += km if km else trip.duration / 3600 * config.rating_fallback_speed_kmh
    exposure = max(exposure, config.rating_distance_km)
    return max(0, round(100 - penalties / exposure * config.rating_distance_km)), len(scored), exposure


def trips_word(n):
    """1 поїздку, 2 поїздки, 5 поїздок (як HomeView.tripsWord)."""
    if 11 <= n % 100 <= 14:
        return "поїздок"
    return {1: "поїздку", 2: "поїздки", 3: "поїздки", 4: "поїздки"}.get(n % 10, "поїздок")
