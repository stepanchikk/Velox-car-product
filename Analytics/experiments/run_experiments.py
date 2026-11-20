"""Відтворювані СИНТЕТИЧНІ випробування Velox. Не польові результати."""
import argparse
import csv
import json
import platform
import sys
from pathlib import Path
sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import numpy as np
import pandas as pd
import matplotlib
matplotlib.use('Agg')
import matplotlib.pyplot as plt
from velox_analytics.checks import yaw_forward
from velox_analytics.filtering import apply_filter, detect_maneuvers
from velox_analytics.validation import match_events


def angle(a, b):
    return float(np.degrees(np.arccos(np.clip(np.dot(a, b), -1, 1))))


def run(seed, trials, output):
    output.mkdir(parents=True, exist_ok=True)
    rng = np.random.default_rng(seed)
    rows = []
    for trial in range(trials):
        rotation, _ = np.linalg.qr(rng.normal(size=(3, 3)))
        if np.linalg.det(rotation) < 0: rotation[:, 0] *= -1
        forward, side, up = rotation.T
        t = np.arange(0, 180, .1)
        speed = 12 + 3*np.sin(t*.2)
        accel = .6*np.cos(t*.2)
        yaw = .22*np.sin(t*.15)
        acc = (accel[:, None]*forward + (speed*yaw)[:, None]*side)/9.80665
        acc += rng.normal(0, .03, acc.shape)
        gyro = yaw[:, None]*up + rng.normal(0, .01, acc.shape)
        # Довільне кріплення і похибка вертикалі. Ті самі пороги, що в застосунку.
        noisy_up = up + rng.normal(0, .01, 3)
        estimate, energy, consistency = yaw_forward(acc, gyro, noisy_up)
        yaw_error = angle(estimate, forward) if estimate is not None else None
        # GPS: прямолінійний профіль 25 с, щосекундні швидкості з шумом.
        ts = np.arange(0, 25, .1)
        v = 8 + 4*np.sin(ts*.45)
        a = 1.8*np.cos(ts*.45)
        imu = a[:, None]*forward/9.80665 + rng.normal(0, .03, (len(ts), 3))
        gps_v = v[::10] + rng.normal(0, .25, len(v[::10]))
        w = np.zeros(3); gps_energy = 0.; decided_at = None
        for i in range(1, len(gps_v)):
            agps = gps_v[i]-gps_v[i-1]
            avg = imu[(i-1)*10:i*10].mean(axis=0)
            avg -= up*np.dot(avg, up)
            if abs(agps) >= 6: continue
            w += agps*avg; gps_energy += agps**2
            if gps_energy >= 4:
                decided_at = i
                break
        gps_error = angle(w/np.linalg.norm(w), forward) if np.linalg.norm(w) else None
        rows.append(dict(trial=trial, yaw_error_deg=yaw_error, yaw_decided=energy>=3 and consistency>=.5,
                         gps_error_deg=gps_error, gps_decided=gps_energy>=4, gps_decision_s=decided_at))
    pd.DataFrame(rows).to_csv(output/'calibration_trials.csv', index=False)
    t = np.arange(0, 120, .1)
    raw = rng.normal(0, .025, len(t))
    labels=[]
    for start, end, value in [(10,12,.6),(30,32,-.6),(60,62,.5),(80,82,-.45)]:
        raw[(t>=start)&(t<end)] += value
        labels.append(dict(start=start,end=end,event='HardAcceleration' if value>0 else 'HardBraking'))
    raw[[50, 250, 500, 700, 1000]] += 1.0
    y=apply_filter(raw,.2)
    found=detect_maneuvers(t,y,.4,3)
    event_by_time=dict(found);penalty=0
    with (output/'Velox_Data_2026-11-17_00-00-00.csv').open('w') as f:
        f.write('# format=4\n# dataset=synthetic\n# started=2026-11-17T00:00:00+02:00\n# filterAlpha=0.2\n# maneuverThreshold=0.4\n# maneuverCooldown=3\n')
        w=csv.writer(f);w.writerow(['Timestamp','Filtered_Y','Event','Raw_Y','Score','Speed_mps','PenaltyTotal','ManeuversEnabled','Movement','Processing_ms','SampleGap_s'])
        for ti,xi,yi in zip(t,raw,y):
            event=event_by_time.get(ti,'');penalty+=2 if event else 0
            w.writerow([ti,yi,event,xi,max(0,100-penalty),10,penalty,1,'moving',0,.1])
        w.writerow([120,y[-1],'TripEnd',raw[-1],100-penalty,10,penalty,1,'moving',0,.1])
    pd.DataFrame(labels).to_csv(output/'labels.csv',index=False)
    metrics=[]
    for alpha in [.1,.2,.3,.5]:
        for threshold in [.25,.3,.35,.4,.45,.5]:
            result=match_events(detect_maneuvers(t,apply_filter(raw,alpha),threshold,3),labels)
            result.pop('delays_s');metrics.append(dict(alpha=alpha,threshold=threshold,**result))
    pd.DataFrame(metrics).to_csv(output/'sensitivity.csv',index=False)
    def stats(key):
        a=np.array([r[key] for r in rows if r[key] is not None]);return dict(median=float(np.median(a)),p95=float(np.percentile(a,95)),max=float(max(a)))
    results=dict(dataset='synthetic',seed=seed,trials=trials,python=platform.python_version(),numpy=np.__version__,
                 yaw=stats('yaw_error_deg'),gps=stats('gps_error_deg'),
                 maneuvers=match_events(found,labels),
                 assumptions='Жорстке кріплення; прямий рух для GPS; синусоїдальні повороти; Gaussian noise. Не оцінює реальну дорожню точність.')
    (output/'results.json').write_text(json.dumps(results,ensure_ascii=False,indent=2))
    fig,axes=plt.subplots(2,1,figsize=(10,7))
    axes[0].plot(t,raw,lw=.7,label='Raw');axes[0].plot(t,y,label='Filtered alpha=0.2');axes[0].axhline(.4,c='r',ls='--');axes[0].axhline(-.4,c='r',ls='--');axes[0].set(xlabel='Time, s',ylabel='Acceleration, G',title='SYNTHETIC telemetry');axes[0].legend()
    axes[1].hist([r['yaw_error_deg'] for r in rows],bins=30,alpha=.7,label='Yaw');axes[1].hist([r['gps_error_deg'] for r in rows],bins=30,alpha=.7,label='GPS');axes[1].set(xlabel='Angle error, degrees',ylabel='Trials',title=f'SYNTHETIC calibration, seed={seed}');axes[1].legend()
    fig.tight_layout();fig.savefig(output/'simulation.png',dpi=160);plt.close(fig)
    print(json.dumps(results,ensure_ascii=False,indent=2))

if __name__=='__main__':
    parser=argparse.ArgumentParser(description=__doc__);parser.add_argument('--seed',type=int,default=20261117);parser.add_argument('--trials',type=int,default=500);parser.add_argument('--out',type=Path,default=Path(__file__).parent/'output');a=parser.parse_args()
    if a.trials<1:parser.error('--trials має бути додатним')
    run(a.seed,a.trials,a.out)
