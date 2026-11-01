"""Run the PageProbe UI test and end it when the probe stops making progress.

Usage:
  python3 scripts/page_probe_watchdog.py --page-dir DIR --diagnostics DIR -- xcodebuild ... test-without-building

The app writes DIR/page-heartbeat.txt every few seconds (PageProbe). This
script runs the command, prints a short status line to the job log every
minute, and ends the run early, with a diagnostics folder, when:

- the heartbeat never appears (the app did not start the probe),
- the heartbeat stops changing (the app died or hangs completely),
- the main thread leaves the probe's ping unanswered for too long,
- no phase finishes for too long.

A finished command keeps its own exit code; a run the watchdog ends exits 124.
Only synthetic test data is involved; the diagnostics hold the probe's own
files, a process list and (on a Mac) a screenshot of the synthetic library.
"""
from pathlib import Path
import argparse
import os
import re
import shutil
import signal
import subprocess
import sys
import time

STUCK_EXIT = 124


def parse_heartbeat(text):
    """`key=value` fields separated by tabs; the phase name comes last."""
    fields = {}
    for part in text.strip().split('\t'):
        key, sep, value = part.partition('=')
        if sep:
            fields[key] = value
    return fields


def number(fields, key, default=0.0):
    try:
        return float(fields.get(key, default))
    except ValueError:
        return default


def finished_phases(page_dir):
    report = Path(page_dir) / 'page-report.txt'
    try:
        return report.read_text(errors='replace').count('page report (')
    except OSError:
        return 0


class Watchdog:
    def __init__(self, page_dir, diagnostics, launch_grace, stale_heartbeat, main_silent, no_progress,
                 print_every, poll, app_name, clock=time.monotonic):
        self.page_dir = Path(page_dir)
        self.diagnostics = Path(diagnostics)
        self.launch_grace = launch_grace
        self.stale_heartbeat = stale_heartbeat
        self.main_silent = main_silent
        self.no_progress = no_progress
        self.print_every = print_every
        self.poll = poll
        self.app_name = app_name
        self.clock = clock
        self.started = clock()
        self.last_print = None
        self.progress = None
        self.progress_at = self.started
        self.last_beat = None
        self.beat_changed_at = None

    @property
    def heartbeat_path(self):
        return self.page_dir / 'page-heartbeat.txt'

    def elapsed(self):
        return self.clock() - self.started

    def read_heartbeat(self):
        try:
            return parse_heartbeat(self.heartbeat_path.read_text(errors='replace'))
        except OSError:
            return None

    def check(self):
        """None while the probe is healthy, otherwise why it looks stuck."""
        now = self.clock()
        beat = self.read_heartbeat()
        if beat is None:
            if now - self.started > self.launch_grace:
                return f'no heartbeat after {now - self.started:.0f} s: the app never started the page probe'
            return None
        if beat.get('beat') != self.last_beat:
            self.last_beat = beat.get('beat')
            self.beat_changed_at = now
        if now - self.beat_changed_at > self.stale_heartbeat:
            return (f'the heartbeat stopped {now - self.beat_changed_at:.0f} s ago '
                    f'(the app quit, crashed or hangs completely) during "{beat.get("phase", "?")}"')
        silent = number(beat, 'main_silent')
        if silent > self.main_silent:
            return (f'the main thread left a ping unanswered for {silent:.0f} s during '
                    f'"{beat.get("phase", "?")}" ({number(beat, "phase_elapsed"):.0f} s into it)')
        progress = max(int(number(beat, 'phases_done')), finished_phases(self.page_dir))
        if progress != self.progress:
            self.progress = progress
            self.progress_at = now
        if now - self.progress_at > self.no_progress:
            return (f'no phase finished for {now - self.progress_at:.0f} s; still in '
                    f'"{beat.get("phase", "?")}" ({beat.get("detail", "")})')
        return None

    def status_line(self):
        beat = self.read_heartbeat()
        minutes, seconds = divmod(int(self.elapsed()), 60)
        if beat is None:
            return f'[page probe +{minutes}:{seconds:02d}] waiting for the app to start the probe'
        detail = beat.get('detail', '')
        return (f'[page probe +{minutes}:{seconds:02d}] {int(number(beat, "phases_done"))} phases done; '
                f'"{beat.get("phase", "?")}" for {number(beat, "phase_elapsed"):.0f} s; '
                f'main thread silent {number(beat, "main_silent"):.0f} s; '
                f'memory {number(beat, "memory_mb"):.0f} MB'
                + (f'; {detail}' if detail else ''))

    def maybe_print(self):
        now = self.clock()
        if self.last_print is None or now - self.last_print >= self.print_every:
            self.last_print = now
            print(self.status_line(), flush=True)

    def collect(self, reason):
        """Diagnostics into the folder and a short version into the log."""
        diag = self.diagnostics
        diag.mkdir(parents=True, exist_ok=True)
        (diag / 'WATCHDOG.txt').write_text(
            f'{reason}\nafter {self.elapsed():.0f} s\nlast heartbeat: '
            + (self.heartbeat_path.read_text(errors='replace') if self.heartbeat_path.exists() else 'none\n'))
        if self.page_dir.is_dir():
            # The probe's own files only (the diagnostics may sit inside).
            (diag / 'pages').mkdir(exist_ok=True)
            for item in self.page_dir.iterdir():
                if item.is_file():
                    shutil.copy2(item, diag / 'pages' / item.name)
        run(['ps', '-axo', 'pid,ppid,pcpu,pmem,rss,etime,command'], diag / 'processes.txt')
        if shutil.which('screencapture'):
            run(['screencapture', '-x', str(diag / 'screen.png')])
        pid = app_pid(self.app_name)
        if pid and shutil.which('sample'):
            # The app samples its own main thread (page-stuck-main.txt);
            # `sample` adds the other threads where the runner allows it.
            if run(['sample', str(pid), '3', '-file', str(diag / 'sample.txt')], timeout=60) != 0 and shutil.which('sudo'):
                run(['sudo', '-n', 'sample', str(pid), '3', '-file', str(diag / 'sample.txt')], timeout=60)

        print('PROBE-WATCHDOG-BEGIN', flush=True)
        print(f'watchdog: {reason}')
        print((diag / 'WATCHDOG.txt').read_text().rstrip())
        stuck = self.page_dir / 'page-stuck-main.txt'
        if stuck.exists():
            print('-- page-stuck-main.txt (main thread stacks taken by the app) --')
            print('\n'.join(stuck.read_text(errors='replace').splitlines()[:260]))
        report = self.page_dir / 'page-report.txt'
        if report.exists():
            print('-- phases finished so far --')
            for line in report.read_text(errors='replace').splitlines():
                if line.startswith(('page report (', 'imported ', 'page probe:')):
                    print(line)
        processes = diag / 'processes.txt'
        if processes.exists():
            print('-- processes --')
            for line in processes.read_text(errors='replace').splitlines():
                if self.app_name in line or 'xcodebuild' in line or 'Runner' in line:
                    print(line[:240])
        sample = diag / 'sample.txt'
        if sample.exists():
            print('-- sample: each thread\'s heaviest stack, innermost frames last (full file in the artifact) --')
            print(sample_digest(sample.read_text(errors='replace')))
        print('PROBE-WATCHDOG-END', flush=True)


SAMPLE_LINE = re.compile(r'^(?P<lead>\s*[+!:| ]*)(?P<count>\d+) (?P<rest>.+)$')
THREAD_LINE = re.compile(r'^\s*\d+ Thread_\d+')


def frame_name(rest):
    """`foo(bar)  (in Lib) + 12  [0x…]  File.swift:3` → `foo(bar)  (in Lib)`."""
    rest = re.sub(r'\s+\[0x[0-9a-f]+(?:,0x[0-9a-f]+)*\].*$', '', rest)
    rest = re.sub(r'\s+\+ \d+$', '', rest)
    return rest.strip()


def sample_digest(text, frames=30, max_threads=40):
    """From macOS `sample` output: every thread's heaviest path (the first
    branch printed at each level, since children are sorted by count), keeping
    its innermost `frames`, then the busiest tops of stack."""
    lines = text.splitlines()
    try:
        start = next(i for i, line in enumerate(lines) if line.startswith('Call graph:')) + 1
    except StopIteration:
        return 'no call graph in the sample'
    out, threads, index = [], 0, start
    while index < len(lines) and threads < max_threads:
        line = lines[index]
        if line.startswith(('Total number in stack', 'Sort by top of stack', 'Binary Images')):
            break
        if not THREAD_LINE.match(line):
            index += 1
            continue
        threads += 1
        header = line.strip()
        path, depth = [], -1
        index += 1
        while index < len(lines) and lines[index].strip() and not THREAD_LINE.match(lines[index]):
            match = SAMPLE_LINE.match(lines[index])
            index += 1
            if not match:
                continue
            column = len(match['lead'])
            if column <= depth:
                break  # a sibling or a return: the heaviest branch has ended
            depth = column
            path.append(f"{match['count']:>5} {frame_name(match['rest'])}")
        while index < len(lines) and lines[index].strip() and not THREAD_LINE.match(lines[index]):
            index += 1
        out.append(header)
        if len(path) > frames:
            out.append(f'        … {len(path) - frames} outer frames')
        out.extend('   ' + frame[:220] for frame in path[-frames:])
    tops = [i for i, line in enumerate(lines) if line.startswith('Sort by top of stack')]
    if tops:
        out.append(lines[tops[0]])
        out.extend(line.rstrip()[:200] for line in lines[tops[0] + 1:tops[0] + 26] if line.strip())
    return '\n'.join(out)


def run(command, output=None, timeout=30):
    try:
        if output is None:
            return subprocess.run(command, timeout=timeout, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL).returncode
        with open(output, 'w') as handle:
            return subprocess.run(command, timeout=timeout, stdout=handle, stderr=subprocess.STDOUT).returncode
    except (OSError, subprocess.TimeoutExpired):
        return -1


def app_pid(name):
    if not shutil.which('pgrep'):
        return None
    result = subprocess.run(['pgrep', '-x', name], capture_output=True, text=True)
    pids = result.stdout.split()
    return int(pids[0]) if pids else None


def stop(process, app_name, grace):
    """Ends the command's whole process group, then the app it launched."""
    for sig in (signal.SIGTERM, signal.SIGKILL):
        try:
            os.killpg(process.pid, sig)
        except (ProcessLookupError, PermissionError):
            pass
        try:
            process.wait(timeout=grace)
            break
        except subprocess.TimeoutExpired:
            continue
    if shutil.which('pkill'):
        subprocess.run(['pkill', '-KILL', '-x', app_name], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument('--page-dir', required=True)
    parser.add_argument('--diagnostics', required=True)
    parser.add_argument('--launch-grace', type=float, default=600, help='seconds until the first heartbeat')
    parser.add_argument('--stale-heartbeat', type=float, default=180, help='seconds without a new heartbeat')
    parser.add_argument('--main-silent', type=float, default=240, help='seconds the main thread may leave a ping unanswered')
    parser.add_argument('--no-progress', type=float, default=900, help='seconds without a finished phase')
    parser.add_argument('--print-every', type=float, default=60)
    parser.add_argument('--poll', type=float, default=5)
    parser.add_argument('--stop-grace', type=float, default=20)
    parser.add_argument('--app-name', default='Moments')
    parser.add_argument('command', nargs=argparse.REMAINDER)
    args = parser.parse_args(argv)
    command = args.command[1:] if args.command[:1] == ['--'] else args.command
    if not command:
        parser.error('give the command to run after --')

    watchdog = Watchdog(args.page_dir, args.diagnostics, args.launch_grace, args.stale_heartbeat,
                        args.main_silent, args.no_progress, args.print_every, args.poll, args.app_name)
    process = subprocess.Popen(command, start_new_session=True)
    try:
        while True:
            try:
                code = process.wait(timeout=args.poll)
                # Killed by a signal: report it the way a shell does.
                return 128 - code if code < 0 else code
            except subprocess.TimeoutExpired:
                pass
            watchdog.maybe_print()
            reason = watchdog.check()
            if reason:
                try:
                    watchdog.collect(reason)
                finally:
                    stop(process, args.app_name, args.stop_grace)
                print(f'::error::Page probe stopped by the watchdog: {reason}', flush=True)
                return STUCK_EXIT
    except KeyboardInterrupt:
        stop(process, args.app_name, args.stop_grace)
        raise


if __name__ == '__main__':
    sys.exit(main())
