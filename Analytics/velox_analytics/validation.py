"""Оцінювання подій за незалежною ручною розміткою інтервалів."""
import argparse
import json
from pathlib import Path
import pandas as pd


def match_events(detected, labels, tolerance=0.5):
    """Одна подія відповідає щонайбільше одному інтервалу того самого типу.

    Початок інтервалу — фактичний початок маневру. Затримка вимірюється від
    нього, тому tolerance не приховує затримку фільтра. Часи у секундах сесії.
    """
    used, delays, false_positives = set(), [], 0
    for time, kind in sorted(detected):
        candidates = [(i, row) for i, row in enumerate(labels)
                      if i not in used and row['event'] == kind
                      and row['start'] <= time <= row['end'] + tolerance]
        if not candidates:
            false_positives += 1
            continue
        index, row = min(candidates, key=lambda pair: pair[1]['end'])
        used.add(index)
        delays.append(float(time - row['start']))
    tp, fp, fn = len(used), false_positives, len(labels) - len(used)
    precision = tp / (tp + fp) if tp + fp else None
    recall = tp / (tp + fn) if tp + fn else None
    return dict(tp=tp, fp=fp, fn=fn, precision=precision, recall=recall,
                f1=2*tp/(2*tp+fp+fn) if 2*tp+fp+fn else None,
                delays_s=delays, mean_delay_s=sum(delays)/len(delays) if delays else None)


def main():
    from .config import AppConfig
    from .loader import load_trip
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('telemetry')
    parser.add_argument('labels', help='CSV: start,end,event; незалежна розмітка')
    parser.add_argument('--output', required=True)
    args = parser.parse_args()
    trip = load_trip(args.telemetry, AppConfig())
    if trip is None:
        parser.error('Непридатний файл телеметрії')
    labels = pd.read_csv(args.labels)
    if not {'start', 'end', 'event'} <= set(labels):
        parser.error('Потрібні колонки start,end,event')
    if labels[['start', 'end']].isna().any().any() or (labels.end < labels.start).any():
        parser.error('Некоректні часові інтервали')
    detected = [(float(t), kind) for t, kind in zip(trip.events.Timestamp, trip.events.Event)
                if kind in ('HardBraking', 'HardAcceleration', 'Distraction')]
    result = match_events(detected, labels.to_dict('records'))
    result['telemetry'] = Path(args.telemetry).name
    result['labels'] = Path(args.labels).name
    Path(args.output).write_text(json.dumps(result, ensure_ascii=False, indent=2), encoding='utf-8')
    print(json.dumps(result, ensure_ascii=False, indent=2))

if __name__ == '__main__':
    main()
