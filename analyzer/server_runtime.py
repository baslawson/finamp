"""Cooperate across analyzer/karaoke processes without changing audio DSP.

Only background work takes the shared lease. Playback and HTTP handlers never
wait for it. Existing audio/measurements are not interrupted part way through.
"""
import contextlib
import fcntl
import json
import os
import re
import shutil
import threading
import time
from collections import OrderedDict
from pathlib import Path


class WorkDeferred(Exception):
    pass


def lower_worker_priority():
    # Linux niceness is per thread. Leave the API/radio threads at their original
    # priority; subprocesses created by this background thread inherit its nice.
    try:
        os.setpriority(os.PRIO_PROCESS, threading.get_native_id(), 10)
    except (AttributeError, OSError):
        pass


def machine_sample(path):
    memory = {}
    try:
        memory = {line.split(':')[0]: int(line.split()[1]) * 1024
            for line in Path('/proc/meminfo').read_text().splitlines()
            if line.startswith(('MemTotal:', 'MemAvailable:'))}
    except (OSError, ValueError):
        pass
    # Docker/LXC may expose more host memory than this service can actually use.
    for root, maximum, used, inactive in (
        ('/sys/fs/cgroup', 'memory.max', 'memory.current', 'inactive_file'),
        ('/sys/fs/cgroup/memory', 'memory.limit_in_bytes', 'memory.usage_in_bytes', 'total_inactive_file'),
    ):
        try:
            limit = int((Path(root) / maximum).read_text())
            current = int((Path(root) / used).read_text())
            stats = dict(line.split() for line in (Path(root) / 'memory.stat').read_text().splitlines())
            reclaimable = int(stats.get(inactive, 0))
            if 0 < limit < 2**60:
                memory['MemTotal'] = min(memory.get('MemTotal', limit), limit)
                memory['MemAvailable'] = min(memory.get('MemAvailable', limit), limit,
                    max(0, limit - current + reclaimable))
        except (OSError, ValueError):
            pass
    pressure = {}
    for name in ('cpu', 'memory', 'io'):
        try:
            lines = Path('/proc/pressure', name).read_text().splitlines()
            selected = next((line for line in lines if line.startswith('full ')), lines[0])
            pressure[name] = float(dict(part.split('=') for part in selected.split()[1:])['avg10'])
        except (OSError, ValueError, KeyError, IndexError):
            pressure[name] = 0
    disk = shutil.disk_usage(path)
    return {'cpus': os.cpu_count() or 1, 'load': list(os.getloadavg()),
        'memoryTotal': memory.get('MemTotal'), 'memoryAvailable': memory.get('MemAvailable'),
        'diskFree': disk.free, 'diskTotal': disk.total, 'pressure': pressure}


class RuntimeGovernor:
    def __init__(self, data, role='analyzer', playback=None, probe=machine_sample, clock=time.time):
        self.root, self.role = Path(data) / 'runtime', role
        self.playback, self.probe, self.clock = playback, probe, clock
        self.stop = threading.Event()
        self.lock = threading.RLock()
        self.states, self.sample, self.thread = {}, None, None
        self.priority_loader = lambda: []
        self.demands = OrderedDict()
        self.scan_events = {'analysis': threading.Event(), 'loudness': threading.Event()}

    def _read(self, name, max_age=20):
        try:
            value = json.loads((self.root / (name + '.json')).read_text())
            if 0 <= self.clock() - value['updated'] <= max_age:
                return value
        except (OSError, ValueError, KeyError, TypeError):
            pass
        return {}

    def _write(self, name, value):
        self.root.mkdir(parents=True, exist_ok=True, mode=0o700)
        temporary = self.root / f'.{name}.{os.getpid()}.{threading.get_ident()}.tmp'
        temporary.write_text(json.dumps(value))
        temporary.chmod(0o600)
        temporary.replace(self.root / (name + '.json'))

    def refresh(self):
        self.sample = self.probe(self.root.parent)
        if self.playback is not None:
            try:
                players = self.playback()
                self._write('playback', {'updated': self.clock(), 'players': players, 'available': True})
            except Exception:
                # Never interpret an unavailable Jellyfin as proof that nobody
                # is listening. Existing streams continue independently.
                self._write('playback', {'updated': self.clock(), 'players': None, 'available': False})
        with self.lock:
            self._write(self.role, {'updated': self.clock(), 'workers': dict(self.states)})

    def start(self):
        if self.thread and self.thread.is_alive():
            return
        self.root.mkdir(parents=True, exist_ok=True, mode=0o700)
        def run():
            while not self.stop.is_set():
                try:
                    self.refresh()
                except (OSError, ValueError):
                    pass
                self.stop.wait(5)
        self.thread = threading.Thread(target=run, name='server-resources', daemon=True)
        self.thread.start()

    def close(self):
        self.stop.set()
        for event in self.scan_events.values():
            event.set()
        if self.thread:
            self.thread.join(timeout=8)

    def mark(self, kind, state, message):
        with self.lock:
            previous = self.states.get(kind, {})
            self.states[kind] = {'state': state, 'message': message, 'updated': self.clock(),
                'since': previous.get('since', self.clock()) if previous.get('state') == state else self.clock()}
            try:
                self._write(self.role, {'updated': self.clock(), 'workers': dict(self.states)})
            except OSError:
                pass

    def reason(self, kind, starting=True):
        sample = self.sample or self.probe(self.root.parent)
        if sample['diskFree'] < 2 * 1024**3:
            return 'Waiting for at least 2 GB of free working space'
        available = sample.get('memoryAvailable')
        reserve = (1536 if kind == 'karaoke' and starting else 256) * 1024**2
        if available is None or available < reserve:
            return 'Waiting for more available memory'
        active = self._read('playback')
        if not active.get('available'):
            return 'Waiting for playback status from Jellyfin'
        pressure = sample.get('pressure', {})
        if pressure.get('memory', 0) >= 1:
            return 'Waiting for memory pressure to settle'
        if sample['load'][0] > sample['cpus'] * (0.85 if active['players'] else 1.2):
            return 'Playback has priority; waiting for CPU capacity'
        if active['players'] and pressure.get('io', 0) >= 2:
            return 'Playback has priority; waiting for disk activity to settle'
        if kind in ('analysis', 'loudness', 'health'):
            karaoke = self._read('karaoke').get('workers', {}).get('karaoke', {})
            if karaoke.get('state') == 'waiting' and karaoke.get('message') == 'Waiting for another background job':
                return 'Queued karaoke preparation has priority'
        return None

    def try_acquire(self, kind):
        if not re.fullmatch('[a-z]+', kind):
            raise ValueError('Invalid background worker')
        reason = self.reason(kind)
        if reason:
            self.mark(kind, 'waiting', reason)
            return None, reason
        self.root.mkdir(parents=True, exist_ok=True, mode=0o700)
        descriptor = (self.root / 'heavy.lock').open('a')
        try:
            fcntl.flock(descriptor.fileno(), fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            descriptor.close()
            reason = 'Waiting for another background job'
            self.mark(kind, 'waiting', reason)
            return None, reason
        self.mark(kind, 'running', 'Working at background priority')
        return descriptor, None

    def release(self, kind, descriptor):
        try:
            fcntl.flock(descriptor.fileno(), fcntl.LOCK_UN)
        finally:
            descriptor.close()
            self.mark(kind, 'idle', 'Ready for the next job')

    @contextlib.contextmanager
    def slot(self, kind):
        descriptor = None
        while not self.stop.is_set():
            descriptor, _ = self.try_acquire(kind)
            if descriptor is not None:
                break
            self.stop.wait(1)
        if descriptor is None:
            raise WorkDeferred('Server is stopping; work will resume after restart')
        try:
            yield
        finally:
            self.release(kind, descriptor)

    def checkpoint(self, kind):
        reason = self.reason(kind, starting=False)
        if reason:
            raise WorkDeferred(reason)

    def request_analysis(self, ids, group):
        now, wake = self.clock(), False
        with self.lock:
            for value in ids[:200]:
                value = value.replace('-', '').lower()
                if not re.fullmatch('[0-9a-f]{32}', value):
                    continue
                key = (group, value)
                if key not in self.demands or self.demands[key] + 3600 < now:
                    self.demands[key], wake = now, True
            while len(self.demands) > 1024:
                self.demands.popitem(last=False)
        if wake:
            self.scan_events[group].set()

    def prioritize(self, values, identify):
        with self.lock:
            requested = [key[1] for key, at in reversed(self.demands.items()) if self.clock() - at < 3600]
        try:
            requested.extend(self.priority_loader())
        except Exception:
            pass
        ranks = {}
        for value in requested:
            ranks.setdefault(value, len(ranks))
        def rank(value):
            ids = identify(value)
            if isinstance(ids, str):
                ids = [ids]
            return min((ranks.get(value, len(ranks)) for value in ids), default=len(ranks))
        return sorted(values, key=rank)

    def wait_scan(self, group, interval):
        # Demand can wake a six-hour scan, but never causes repeated library
        # walks faster than once every five minutes. Measurements are fixed.
        event = self.scan_events[group]
        demanded = event.wait(interval)
        event.clear()
        return not self.stop.wait(300 if demanded else 0)

    def run_scans(self, group, scan, interval, logger):
        lower_worker_priority()
        backoff = 60
        while not self.stop.is_set():
            try:
                scan()
                delay, backoff = interval, 60
            except Exception as error:
                delay, backoff = backoff, min(300, backoff * 2)
                self.mark(group, 'waiting', f'Library scan unavailable; retrying in {delay} seconds')
                logger.warning('Library scan unavailable (%s); retrying in %s seconds', type(error).__name__, delay)
            if not self.wait_scan(group, delay):
                break

    def status(self):
        sample = self.sample or self.probe(self.root.parent)
        workers = []
        for role in ('analyzer', 'karaoke'):
            state = self._read(role)
            for kind, worker in state.get('workers', {}).items():
                workers.append({'worker': kind, **worker})
        playback = self._read('playback')
        warnings = []
        if sample['diskFree'] < 2 * 1024**3:
            warnings.append('Low working space: new preparations are waiting')
        if (sample.get('memoryAvailable') or 0) < 512 * 1024**2:
            warnings.append('Limited available memory: heavy jobs may wait')
        if not playback.get('available'):
            warnings.append('Playback status is unavailable; new heavy jobs are waiting')
        return {'machine': sample, 'playback': {'available': bool(playback.get('available')),
            'players': playback.get('players')}, 'workers': workers, 'warnings': warnings,
            'policy': 'Playback first; one heavy background job at a time'}
