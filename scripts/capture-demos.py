#!/usr/bin/env python3
"""Record native developer views with synthetic data. Requires built apps and FFmpeg."""
import argparse
from datetime import datetime, timedelta, timezone
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
PRODUCTS = ROOT / 'App/DerivedData/Build/Products/Release'

def run_app(binary, env):
    subprocess.run([str(binary)], env=os.environ | env, check=True, timeout=55,
                   stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)

def gif(pattern, destination, fps=10, width=-1):
    subprocess.run(['ffmpeg', '-y', '-v', 'error', '-framerate', str(fps), '-i', str(pattern),
                    '-filter_complex', f'fps=12,scale={width}:-1:flags=lanczos,split[a][b];[a]palettegen=max_colors=256:stats_mode=diff[p];[b][p]paletteuse=dither=bayer:bayer_scale=3',
                    '-loop', '0', str(destination)], check=True)

def main():
    if shutil.which('ffmpeg') is None:
        raise SystemExit('Install FFmpeg first (brew install ffmpeg).')
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--output', type=Path, default=ROOT / 'docs/media')
    parser.add_argument('--only', choices=['dashboard', 'menu', 'all'], default='all')
    parser.add_argument('--history-directory', type=Path, help='Optional local copy of real history/snapshot/frame files; only rendered media is exported')
    args = parser.parse_args()
    args.output.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix='deskpilot-media-') as tmp:
        tmp = Path(tmp)
        bar = PRODUCTS / 'Deskpilot.app/Contents/MacOS/Deskpilot'
        dash = PRODUCTS / 'Deskpilot Dashboard.app/Contents/MacOS/Deskpilot Dashboard'
        if args.only in ('menu', 'all'):
            for scenario in ['busyDay', 'moving', 'beeping']:
                data = tmp / scenario
                prefix = tmp / (scenario + '-capture')
                env = dict(DESKPILOT_SIMULATE=scenario, DESKPILOT_DATA_DIR=str(data),
                           DESKPILOT_DEV_OPEN_MENU=str(prefix), DESKPILOT_DEV_SNAPSHOT_DELAY='1',
                           DESKPILOT_DEV_FRAMES='100' if scenario != 'busyDay' else '1',
                           DESKPILOT_DEV_INTERVAL='0.1', DESKPILOT_DEV_DESKTOP_CONTEXT='1')
                if scenario == 'busyDay' and args.history_directory:
                    data.mkdir(exist_ok=True)
                    shutil.copyfile(args.history_directory/'history.json', data/'history.json')
                    shutil.copyfile(args.history_directory/'snapshot.json', data/'snapshot.json')
                    env['DESKPILOT_DEV_FRAME'] = str(args.history_directory.resolve()/'frame.json')
                run_app(bar, env)
                if scenario == 'busyDay':
                    shutil.copyfile(prefix, args.output/'menu.png')
                else:
                    gif(str(prefix)+'-%04d.png', args.output/f'{scenario}.gif', width=-1)
                print('Recorded', scenario, flush=True)
        if args.only in ('dashboard', 'all'):
            # A reproducible invented year; no personal desk history is copied.
            data = tmp/'dashboard'
            data.mkdir()
            now = datetime.now(timezone.utc)
            day = now.astimezone().replace(hour=9, minute=0, second=0, microsecond=0)
            events = []
            def event(date, kind):
                if date <= now:
                    events.append(dict(byteOffset=len(events)*2, date=date.astimezone(timezone.utc).strftime('%Y-%m-%dT%H:%M:%SZ'), kind=kind))
            for ago in range(364, -1, -1):
                start = day-timedelta(days=ago)
                if start.weekday() >= 5:
                    continue
                event(start, dict(type='presence', present=True))
                for minute in range(0, 480, 20):
                    event(start+timedelta(minutes=minute),dict(type='move', toStanding=(minute//20+ago)%3 == 1))
                event(start+timedelta(hours=8), dict(type='presence', present=False))
            (data/'history.json').write_text(json.dumps(dict(writtenAt=now.strftime('%Y-%m-%dT%H:%M:%SZ'),standingThresholdInches=34,middleOfNightHour=4,events=events)))
            if args.history_directory:
                shutil.copyfile(args.history_directory/'history.json', data/'history.json')
                shutil.copyfile(args.history_directory/'snapshot.json', data/'snapshot.json')
            for appearance in ['light', 'dark']:
                prefix = tmp/appearance
                env = dict(DESKPILOT_SIMULATE='sitting', DESKPILOT_DEV_DATA_DIRECTORY=str(data),
                           DESKPILOT_DEV_APPEARANCE=appearance, DESKPILOT_DEV_NATIVE_SNAPSHOT=str(prefix),
                           DESKPILOT_DEV_SCROLL_MOTION='1', DESKPILOT_DEV_RANGE='day')
                run_app(dash, env)
                shutil.copyfile(str(prefix)+'-window.png',args.output/f'dashboard-{appearance}.png')
                gif(str(prefix)+'-scroll-%04d.png',args.output/f'scroll-{appearance}.gif',fps=20,width=-1)
                print('Recorded', appearance, flush=True)

if __name__ == '__main__':
    main()
