#!/usr/bin/env python3
"""Exercise the actual hosted daemon, Swift-compatible frames and file command queue."""
import json
import queue
import subprocess
import tempfile
import threading
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
BINARY = ROOT / 'rust/target/release/tempo'

class Service:
    def __init__(self, directory, scenario):
        self.directory = Path(directory)
        self.frames = queue.Queue()
        self.errors = open(self.directory / 'daemon.log', 'w')
        self.process = subprocess.Popen([str(BINARY), '--data-dir', str(directory), 'serve', '--hosted', '--sim', scenario], stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=self.errors, text=True)
        def read():
            for line in self.process.stdout:
                self.frames.put(json.loads(line))
        self.reader = threading.Thread(target=read, daemon=True)
        self.reader.start()

    def wait(self, predicate, timeout=10):
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            try:
                frame = self.frames.get(timeout=max(.01, deadline-time.monotonic()))
            except queue.Empty:
                break
            assert frame['protocolVersion'] == 1
            if predicate(frame):
                return frame
        raise AssertionError('No matching UI frame; log: ' + (self.directory/'daemon.log').read_text())

    def command(self, *args):
        started = time.monotonic()
        result = subprocess.run([str(BINARY), '--data-dir', str(self.directory), *args], capture_output=True, text=True, timeout=20)
        assert result.returncode == 0, result.stderr
        assert time.monotonic()-started < 3, 'Hosted command took too long'

    def close(self):
        self.process.stdin.close()
        assert self.process.wait(timeout=8) == 0
        self.reader.join(timeout=1)
        self.errors.close()
        snapshot = json.loads((self.directory/'snapshot.json').read_text())
        assert snapshot['connected'] is False and 'nextMove' not in snapshot

with tempfile.TemporaryDirectory(prefix='tempo-hosted-') as scratch:
    directory = Path(scratch)
    service = Service(directory, 'sitting')
    try:
        frame = service.wait(lambda f: f['state'].get('today') and f['todaySegments'] and f['snapshot']['connected'])
        assert frame['state']['today']['isStanding'] is False
        assert frame['todaySegments']
        assert frame['state']['settings']['countdownTiming'] == {'countdownSeconds': 15, 'pulseTimeSeconds': 8}
        fixture = ROOT/'Tests/DeskpilotKitTests/Fixtures/rust-ui-frame.json'
        fixture.write_text(json.dumps(frame, indent=2)+'\n')
        duplicate = subprocess.run([str(BINARY),'--data-dir',str(directory),'serve','--sim','sitting'],capture_output=True,text=True,timeout=5)
        assert duplicate.returncode != 0 and 'already running' in duplicate.stderr
        service.command('pause')
        service.wait(lambda f: f['snapshot']['paused'])
        service.command('resume')
        service.wait(lambda f: not f['snapshot']['paused'])
        service.command('cruise', 'off')
        service.wait(lambda f: 'cruise' not in f['snapshot'])
        service.command('cruise', 'set', '20', '60')
        service.wait(lambda f: f['snapshot'].get('cruise',{}).get('standingSeconds') == 1200)
        service.command('preset','sit')
        service.command('reconnect')
        service.wait(lambda f: f['state']['status'] == 'connected' and f['state'].get('settings'))
        service.command('backup')
        assert list((directory/'history-backups').glob('*.json'))
    finally:
        service.close()

for scenario, expected in [('out-of-reach','disconnected'),('bluetooth-off','bluetoothOff'),('unauthorized','unauthorized')]:
    with tempfile.TemporaryDirectory(prefix='tempo-hosted-') as scratch:
        service = Service(scratch,scenario)
        try:
            service.wait(lambda f: f['state']['status'] == expected)
        finally:
            service.close()

with tempfile.TemporaryDirectory(prefix='tempo-hosted-') as scratch:
    service = Service(scratch,'beeping')
    try:
        service.wait(lambda f: f['state'].get('today',{}).get('nextMove',{}).get('announcedAt'), timeout=10)
        service.wait(lambda f: f['state']['isMoving'], timeout=25)
        service.wait(lambda f: f['state'].get('today',{}).get('isStanding') is True and not f['state']['isMoving'], timeout=25)
    finally:
        service.close()
print('Hosted integration passed: frame schema, queue commands, exclusive ownership, reconnect, backup, failure states, motor transition, EOF shutdown.')
