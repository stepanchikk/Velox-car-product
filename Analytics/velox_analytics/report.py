"""HTML-звіт: окрема сторінка на кожну поїздку і загальна сторінка report.html.

Сторінка поїздки містить підсумок, висновки перевірок, хронологію подій і
графіки. Графіки вбудовано у файл (base64), тому кожну сторінку можна
відкрити окремо, переслати чи показати без інтернету. Загальна сторінка
порівнює поїздки, показує графіки за всіма поїздками і посилається на сторінки
поїздок (вони мають лежати в тому самому каталозі).
"""

import base64
import html
import os
import re
from dataclasses import dataclass
from datetime import datetime

from .events import EVENT_LABELS, count_calls, distractions_at_call_start, screen_off_intervals
from .scoring import classify_score, trips_word
from .summary import NA, trip_row

INDEX_FILE = "report.html"
MAX_EVENT_ROWS = 300

# Графіки поїздки: (суфікс файлу, підпис, як читати)
TRIP_FIGURES = [
    ("_raw_vs_filtered.png", "Сира та відфільтрована телеметрія",
     "Сірим - прискорення до фільтра, синім - після. Маневр фіксується, коли синя лінія виходить за червоний поріг; "
     "сірі смуги - калібрування, фіолетові - телефон у руках."),
    ("_safety_score.png", "Динаміка Safety Score",
     "Кожна сходинка вниз - подія зі штрафом. Пунктири - межі класів."),
    ("_gps_check.png", "Перевірка калібрування за GPS",
     "Прискорення застосунку (синє) має повторювати прискорення за швидкістю GPS (зелене). GPS оновлюється раз на "
     "секунду і запізнюється, тому збіг неповний, але знак має бути той самий."),
    ("_route.png", "Маршрут", "Місця подій на маршруті (лише з увімкненим «Зберігати маршрут»)."),
    ("_alpha_comparison.png", "Вплив коефіцієнта фільтра alpha",
     "Менший alpha згладжує сильніше, але запізнюється. 0.2 - компроміс між придушенням шуму і швидкістю реакції."),
    ("_alpha_comparison_zoom.png", "Вплив alpha на фрагменті з найбільшою активністю", ""),
]
OVERVIEW_FIGURES = [
    ("threshold_sensitivity.png", "Кількість маневрів залежно від порога",
     "Без фільтра шум дороги дає хибні маневри навіть на спокійній їзді; з фільтром при порозі 0.4 G їх немає."),
    ("distribution.png", "Розподіл відфільтрованого прискорення",
     "Логарифмічна шкала: видно, як рідко прискорення наближається до порога."),
]

STATUS_LABELS = {"ok": "Так", "warn": "Увага", "fail": "Помилка", "info": "Довідка"}


@dataclass
class Check:
    status: str   # ok | warn | fail | info
    title: str
    detail: str = ""


# ----------------------------------------------------------------------
# Висновки перевірок (без HTML, тому їх легко тестувати)
# ----------------------------------------------------------------------

def trip_checks(trip, row):
    """Висновки перевірок поїздки. row - рядок summary.trip_row."""
    checks = []

    if row["Гальмувань (лог)"] == NA:
        checks.append(Check("info", "Події не перевірено", "У файлі немає колонки Event (стара версія)."))
    elif (row["Гальмувань (лог)"], row["Розгонів (лог)"]) == (row["Гальмувань (перерахунок)"],
                                                              row["Розгонів (перерахунок)"]):
        checks.append(Check("ok", "Маневри в CSV збігаються з перерахунком",
                            f"Гальмувань {row['Гальмувань (лог)']}, розгонів {row['Розгонів (лог)']} "
                            f"при порозі {row['Поріг запису, G']} G."))
    else:
        checks.append(Check("fail", "Маневри в CSV не збігаються з перерахунком",
                            f"Гальмувань: у файлі {row['Гальмувань (лог)']}, перерахунок "
                            f"{row['Гальмувань (перерахунок)']}; розгонів: {row['Розгонів (лог)']} і "
                            f"{row['Розгонів (перерахунок)']}."))

    logged, computed = row["Safety Score (лог)"], row["Safety Score (розрахунок)"]
    if NA in (logged, computed):
        checks.append(Check("info", "Safety Score не перевірено", "У файлі немає колонки Score або Event."))
    elif logged == computed:
        checks.append(Check("ok", "Safety Score збігається з формулою", f"{logged}."))
    else:
        checks.append(Check("fail", "Safety Score не збігається з формулою",
                            f"У файлі {logged}, за формулою {computed}."))

    if trip.gps is None:
        checks.append(Check("info", "Калібрування за GPS не перевірено",
                            "Немає колонки Speed_mps або замало даних швидкості."))
    else:
        g = trip.gps
        detail = f"Кореляція r = {g.r:.2f}, нахил {g.slope:.2f}, інтервалів {g.n}."
        if g.r >= 0.3:
            checks.append(Check("ok", "Напрям руху підтверджено GPS", detail))
        elif g.r > 0:
            checks.append(Check("warn", "Слабка кореляція з GPS", detail + " Знак правильний, але сигнал слабкий."))
        else:
            checks.append(Check("fail", "Прискорення суперечить GPS",
                                detail + " Ймовірно, напрям руху визначено навпаки."))

    if trip.yaw is not None and trip.yaw.angle is not None:
        y = trip.yaw
        detail = (f"Розбіжність з калібруванням за GPS {y.angle:.1f}° за всю поїздку "
                  f"(енергія поворотів {y.energy:.1f}, узгодженість {y.consistency:.2f}).")
        if not y.decided:
            checks.append(Check("info", "Напрям за поворотами: рішення не прийнято",
                                detail + " Застосунок без GPS не змінив би калібрування."))
        elif y.angle <= 20:
            checks.append(Check("ok", "Напрям за поворотами збігається з GPS", detail))
        else:
            checks.append(Check("warn", "Напрям за поворотами розходиться з GPS",
                                detail + " Без GPS застосунок виправив би напрям."))

    background = trip.metadata.get("background")
    locked = screen_off_intervals(trip.events, trip.t[-1])
    if background == "on" or locked:
        seconds = sum(end - start for start, end in locked)
        checks.append(Check("info", "Запис із вимкненим екраном дозволено",
                            f"Екран блокували {len(locked)} {_times_word(len(locked))}, разом {seconds:.0f} с; за цей час штраф був "
                            f"лише за користування телефоном (розблокування не для Velox)."))
    elif background == "off":
        checks.append(Check("info", "Запис лише з увімкненим екраном",
                            "Фоновий режим був вимкнений або недоступний: блокування екрана вважалось відволіканням."))

    grace = trip.params.call_focus_loss_grace
    for ts, delay in distractions_at_call_start(trip.events, grace):
        checks.append(Check("warn", "Відволікання на початку розмови без рук",
                            f"На {ts:.1f} с, через {delay:.1f} с після початку дзвінка. Екран розмови відкрила "
                            f"система; з виправленням від 12.10.2026 такий випадок не штрафується."))

    if trip.params_changed:
        checks.append(Check("warn", "Записано з іншими параметрами",
                            "Події перевірено з параметрами, записаними у файлі, а не з поточними."))
    elif trip.metadata:
        checks.append(Check("ok", "Параметри запису збігаються з поточним VeloxConfig"))
    else:
        checks.append(Check("info", "У файлі немає параметрів запису",
                            "Стара версія застосунку: використано поточні параметри."))
    return checks


def _times_word(n):
    """1 раз, 2 рази, 5 разів."""
    if 11 <= n % 100 <= 14:
        return "разів"
    return {1: "раз", 2: "рази", 3: "рази", 4: "рази"}.get(n % 10, "разів")


def trip_started(trip):
    """Час початку поїздки: з рядка "# started" або з імені файлу."""
    started = trip.metadata.get("started")
    if started:
        try:
            return datetime.fromisoformat(started)
        except ValueError:
            pass
    match = re.search(r"(\d{4}-\d{2}-\d{2})_(\d{2})-(\d{2})-(\d{2})", trip.name)
    if match:
        return datetime.strptime(" ".join(match.groups()), "%Y-%m-%d %H %M %S")
    return None


def page_name(trip):
    return f"{trip.stem}.html"


# ----------------------------------------------------------------------
# HTML
# ----------------------------------------------------------------------

def _e(value):
    return html.escape(str(value))


def _duration(seconds):
    minutes, sec = divmod(int(round(seconds)), 60)
    return f"{minutes} хв {sec:02d} с" if minutes else f"{sec} с"


def _image(path):
    with open(path, "rb") as f:
        return "data:image/png;base64," + base64.b64encode(f.read()).decode("ascii")


def _figures(out_dir, items):
    parts = []
    for file_name, title, note in items:
        path = os.path.join(out_dir, file_name)
        if not os.path.isfile(path):
            continue
        caption = f"<b>{_e(title)}.</b> {_e(note)}" if note else f"<b>{_e(title)}</b>"
        parts.append(f'<figure><img src="{_image(path)}" alt="{_e(title)}"><figcaption>{caption}</figcaption></figure>')
    return "\n".join(parts)


def _score_class(score, config):
    if score is None:
        return "none"
    if score >= config.safe_score_min:
        return "safe"
    return "medium" if score >= config.medium_score_min else "danger"


def _metrics(pairs):
    cells = "".join(f"<div><dt>{_e(label)}</dt><dd>{_e(value)}</dd></div>" for label, value in pairs)
    return f'<dl class="metrics">{cells}</dl>'


def _checks_html(checks):
    items = []
    for c in checks:
        detail = f"<p>{_e(c.detail)}</p>" if c.detail else ""
        items.append(f'<li class="check {c.status}"><span class="badge">{STATUS_LABELS[c.status]}</span>'
                     f"<div><h3>{_e(c.title)}</h3>{detail}</div></li>")
    return f'<ul class="checks">{"".join(items)}</ul>'


def _events_html(trip):
    events = trip.events
    if events.empty:
        return "<p class=\"muted\">Подій у файлі немає.</p>"
    rows = []
    for ts, ev in list(zip(events["Timestamp"], events["Event"]))[:MAX_EVENT_ROWS]:
        label = EVENT_LABELS.get(ev, "")
        kind = ("danger" if ev in ("HardBraking", "HardAcceleration", "Distraction", "CallStart_Handheld")
                else "calib" if ev.startswith("Calibration") else "")
        rows.append(f'<tr class="{kind}"><td class="num">{float(ts):.1f}</td><td><code>{_e(ev)}</code></td>'
                    f"<td>{_e(label)}</td></tr>")
    more = (f'<p class="muted">Показано перші {MAX_EVENT_ROWS} з {len(events)}.</p>'
            if len(events) > MAX_EVENT_ROWS else "")
    return ('<div class="scroll"><table><thead><tr><th>Час, с</th><th>Подія</th><th>Що означає</th></tr></thead>'
            f'<tbody>{"".join(rows)}</tbody></table></div>{more}')


def _page(title, body):
    return f"""<!doctype html>
<html lang="uk">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>{_e(title)}</title>
<style>{CSS}</style>
</head>
<body>
<main>
{body}
</main>
</body>
</html>
"""


def trip_page(trip, config, out_dir):
    """HTML сторінки однієї поїздки."""
    row = trip_row(trip)
    checks = trip_checks(trip, row)
    started = trip_started(trip)
    when = started.strftime("%d.%m.%Y, %H:%M") if started else trip.name
    score = int(trip.final_score_logged) if trip.final_score_logged is not None else None
    score_text = str(score) if score is not None else "н/д"
    score_label = classify_score(score, trip.params) if score is not None else "немає колонки Score"
    md = trip.metadata

    origin = ", ".join(x for x in (f"Velox {md['app']}" if "app" in md else "", md.get("device", ""),
                                   md.get("os", "")) if x)
    seconds = row["Телефон у руках, с"]
    metrics = _metrics([
        ("Тривалість", _duration(trip.duration)),
        ("Відстань", f"{row['Відстань, км']} км" if row["Відстань, км"] != NA else NA),
        ("Гальмувань", row["Гальмувань (лог)"]),
        ("Розгонів", row["Розгонів (лог)"]),
        ("Відволікань", row["Відволікань (лог)"]),
        ("Телефон у руках", f"{seconds} с" if seconds != NA else NA),
        ("Дзвінків", count_calls(trip.events["Event"])),
        ("З вимкненим екраном", f"{row['Екран вимкнено, с']} с" if row["Екран вимкнено, с"] != NA else NA),
        ("Макс. розгін", f"{row['Макс. розгін, G']} G"),
        ("Макс. гальмування", f"{row['Макс. гальмування, G']} G"),
        ("Вимірів", row["Вимірів"]),
    ])
    body = f"""
<nav><a href="{INDEX_FILE}">Усі поїздки</a></nav>
<header class="trip">
  <div>
    <p class="eyebrow">{_e(trip.name)}</p>
    <h1>Поїздка {_e(when)}</h1>
    <p class="muted">{_e(origin or "Версія застосунку невідома")}. Сирий сигнал {_e(trip.raw_source)}.</p>
  </div>
  <div class="score {_score_class(score, config)}"><span>{score_text}</span><small>{_e(score_label)}</small></div>
</header>
{metrics}
<section><h2>Перевірки</h2>{_checks_html(checks)}</section>
<section><h2>Графіки</h2>{_figures(out_dir, [(trip.stem + suffix, t, n) for suffix, t, n in TRIP_FIGURES])}</section>
<section><h2>Хронологія подій</h2>{_events_html(trip)}</section>
"""
    return _page(f"Velox: поїздка {when}", body)


def index_page(trips, config, source, rating, out_dir):
    """HTML загальної сторінки."""
    rows = []
    for trip in trips:
        row = trip_row(trip)
        checks = trip_checks(trip, row)
        counts = {s: sum(c.status == s for c in checks) for s in ("ok", "warn", "fail")}
        status = "fail" if counts["fail"] else "warn" if counts["warn"] else "ok"
        started = trip_started(trip)
        score = int(trip.final_score_logged) if trip.final_score_logged is not None else None
        distance = row["Відстань, км"]
        rows.append(
            f'<tr><td><a href="{_e(page_name(trip))}">{_e(started.strftime("%d.%m.%Y %H:%M") if started else trip.name)}</a></td>'
            f'<td class="num">{_e(_duration(trip.duration))}</td>'
            f'<td class="num">{_e(distance if distance != NA else "")}</td>'
            f'<td class="num"><span class="pill {_score_class(score, config)}">{score if score is not None else "н/д"}</span></td>'
            f'<td class="num">{row["Гальмувань (лог)"]} / {row["Розгонів (лог)"]} / {row["Відволікань (лог)"]}</td>'
            f'<td><span class="pill {status}">{counts["ok"]} так, {counts["warn"]} увага, {counts["fail"]} помилок</span></td></tr>')
    if rating is not None:
        value, count, km = rating
        rating_html = (f'<div class="score {_score_class(value, config)}"><span>{value}</span>'
                       f"<small>оцінка водія за {count} {trips_word(count)}</small></div>")
        rating_note = (f"Оцінка водія: штрафи останніх поїздок перераховано на {config.rating_distance_km:g} км "
                       f"пробігу (менший пробіг рахується як {config.rating_distance_km:g} км).")
    else:
        rating_html, rating_note = "", "У файлах немає колонки Score, оцінку водія не пораховано."
    body = f"""
<header class="trip">
  <div>
    <p class="eyebrow">Velox: аналітика телеметрії</p>
    <h1>Звіт за {len(trips)} {_e(trips_word(len(trips)))}</h1>
    <p class="muted">{_e(rating_note)}</p>
    <p class="muted">Параметри: {_e(config.describe())}. Джерело: {_e(os.path.basename(source) if os.path.isfile(str(source)) else source)}.</p>
  </div>
  {rating_html}
</header>
<section><h2>Поїздки</h2>
<div class="scroll"><table>
<thead><tr><th>Поїздка</th><th>Тривалість</th><th>Км</th><th>Safety Score</th><th>Гальм. / розг. / відвол.</th><th>Перевірки</th></tr></thead>
<tbody>{"".join(rows)}</tbody></table></div>
<p class="muted">Повна таблиця з усіма показниками - у summary.csv поруч із цим файлом.</p>
</section>
<section><h2>За всіма поїздками</h2>{_figures(out_dir, OVERVIEW_FIGURES)}</section>
"""
    return _page("Velox: аналітика поїздок", body)


def write_reports(trips, config, source, rating, out_dir):
    """Записує сторінки поїздок і report.html. Повертає шлях до report.html."""
    for trip in trips:
        with open(os.path.join(out_dir, page_name(trip)), "w", encoding="utf-8") as f:
            f.write(trip_page(trip, config, out_dir))
    path = os.path.join(out_dir, INDEX_FILE)
    with open(path, "w", encoding="utf-8") as f:
        f.write(index_page(trips, config, source, rating, out_dir))
    return path


CSS = """
:root {
  color-scheme: light;
  --bg: #F1F4F8; --panel: #FFFFFF; --raised: #E6ECF2; --line: #D3DBE4;
  --ink: #142233; --muted: #5B6B7C; --accent: #1764E8;
  --safe: #1E9E5A; --medium: #C98A00; --danger: #D83A30;
}
* { box-sizing: border-box; }
body { margin: 0; background: var(--bg); color: var(--ink);
  font: 16px/1.55 -apple-system, BlinkMacSystemFont, "SF Pro Text", "Segoe UI", Roboto, sans-serif; }
main { max-width: 1080px; margin: 0 auto; padding: 24px 16px 64px; }
nav a, a { color: var(--accent); text-decoration: none; }
nav a:hover, a:hover { text-decoration: underline; }
nav { margin-bottom: 16px; font-size: 15px; }
h1 { font-size: 30px; line-height: 1.2; margin: 4px 0 8px; letter-spacing: -0.01em; }
h2 { font-size: 20px; margin: 40px 0 14px; }
h3 { font-size: 16px; margin: 0; }
p { margin: 0 0 6px; }
.muted { color: var(--muted); font-size: 15px; }
.eyebrow { color: var(--muted); font-size: 14px; margin: 0; font-variant-numeric: tabular-nums; }
header.trip { display: flex; gap: 24px; align-items: center; justify-content: space-between;
  background: var(--panel); border: 1px solid var(--line); border-radius: 20px; padding: 24px; }
.score { flex: none; width: 148px; height: 148px; border-radius: 50%; display: flex; flex-direction: column;
  align-items: center; justify-content: center; border: 10px solid var(--raised); text-align: center; }
.score span { font-size: 46px; font-weight: 700; line-height: 1; font-variant-numeric: tabular-nums; }
.score small { font-size: 13px; color: var(--muted); max-width: 110px; margin-top: 4px; }
.score.safe { border-color: var(--safe); } .score.safe span { color: var(--safe); }
.score.medium { border-color: var(--medium); } .score.medium span { color: var(--medium); }
.score.danger { border-color: var(--danger); } .score.danger span { color: var(--danger); }
.metrics { display: grid; grid-template-columns: repeat(auto-fill, minmax(150px, 1fr)); margin: 16px 0 0;
  background: var(--panel); border: 1px solid var(--line); border-radius: 16px; overflow: hidden; }
.metrics div { padding: 12px 16px; box-shadow: inset -1px -1px 0 var(--line); }
.metrics dt { color: var(--muted); font-size: 14px; }
.metrics dd { margin: 2px 0 0; font-size: 22px; font-weight: 600; font-variant-numeric: tabular-nums; }
.checks { list-style: none; padding: 0; margin: 0; display: grid; gap: 10px; }
.check { display: flex; gap: 14px; align-items: flex-start; background: var(--panel); border: 1px solid var(--line);
  border-left: 5px solid var(--muted); border-radius: 12px; padding: 12px 16px; }
.check p { color: var(--muted); font-size: 15px; margin-top: 2px; }
.badge { flex: none; font-size: 13px; font-weight: 600; border-radius: 999px; padding: 2px 10px;
  background: var(--raised); min-width: 70px; text-align: center; }
.check.ok { border-left-color: var(--safe); } .check.ok .badge { background: #DDF3E6; color: #146B3E; }
.check.warn { border-left-color: var(--medium); } .check.warn .badge { background: #FBEFD0; color: #7A5300; }
.check.fail { border-left-color: var(--danger); } .check.fail .badge { background: #FADDDA; color: #9C231B; }
figure { margin: 0 0 18px; background: var(--panel); border: 1px solid var(--line); border-radius: 16px; padding: 12px;
  break-inside: avoid; }
figure img { width: 100%; height: auto; display: block; }
figcaption { color: var(--muted); font-size: 15px; padding: 8px 4px 0; }
figcaption b { color: var(--ink); }
.scroll { overflow-x: auto; background: var(--panel); border: 1px solid var(--line); border-radius: 16px; }
table { border-collapse: collapse; width: 100%; font-size: 15px; }
th, td { text-align: left; padding: 9px 14px; border-bottom: 1px solid var(--line); vertical-align: top; }
th { color: var(--muted); font-weight: 600; background: #F7F9FB; white-space: nowrap; }
tr:last-child td { border-bottom: none; }
td.num { font-variant-numeric: tabular-nums; white-space: nowrap; }
tr.danger td:first-child { box-shadow: inset 4px 0 0 var(--danger); }
tr.calib td { color: var(--muted); }
code { font: 13px/1.4 ui-monospace, "SF Mono", Menlo, monospace; }
.pill { display: inline-block; border-radius: 999px; padding: 1px 10px; font-weight: 600; background: var(--raised); }
.pill.safe, .pill.ok { background: #DDF3E6; color: #146B3E; }
.pill.medium, .pill.warn { background: #FBEFD0; color: #7A5300; }
.pill.danger, .pill.fail { background: #FADDDA; color: #9C231B; }
@media (max-width: 640px) {
  header.trip { flex-direction: column-reverse; align-items: flex-start; }
  h1 { font-size: 24px; }
  .score { width: 120px; height: 120px; } .score span { font-size: 38px; }
}
@media print { body { background: #fff; } nav { display: none; } section { break-inside: auto; } }
"""
