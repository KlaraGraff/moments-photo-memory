"""The PageProbe CI helpers: the report summary and the stall watchdog."""
from pathlib import Path
import importlib.util
import subprocess
import sys
import tempfile
import textwrap
import time
import unittest

ROOT = Path(__file__).resolve().parents[1]


def module(name):
    spec = importlib.util.spec_from_file_location(name, ROOT / 'scripts' / f'{name}.py')
    value = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(value)
    return value


summary = module('page_probe_summary')
watchdog = module('page_probe_watchdog')

# Lines as a CI job log shows them (synthetic library, CI Mac).
BEFORE = textwrap.dedent("""\
    2026-10-31T19:21:02.6520330Z page probe: 3 cores
    2026-10-31T19:21:02.6520700Z imported 5000 (trips 41, places 2218) in 10.7 s; faces 3226, day notes 46, photo notes 52, chapters 8 in 1.9 s
    2026-10-31T19:21:02.6556360Z page report (after import (faces, bursts, place names)): selection-to-shell not observed, first-content 1.67 s, first-thumbnail not observed, fully-settled 176.02 s, cancellation-observed no, longest stall 4227 ms, stalls>100ms 67, main busy 138.47 s, memory 201 MB (-13)
    2026-10-31T19:21:02.6597710Z page report (People): selection-to-shell 1.25 s, first-content 1.30 s, first-thumbnail 1.46 s, fully-settled 44.89 s (timed out), cancellation-observed no, longest stall 1458 ms, stalls>100ms 131, main busy 43.78 s, memory 188 MB (-13)
    main thread samples: 12000 (every 2.0 ms)
    2026-10-31T19:21:02.6755520Z page report (Library): selection-to-shell 1.19 s, first-content 1.37 s, first-thumbnail 2.12 s, fully-settled 2.12 s, cancellation-observed no, longest stall 2119 ms, stalls>100ms 1, main busy 2.14 s, memory 263 MB (+13)
    """)
AFTER = textwrap.dedent("""\
    page report (People): selection-to-shell 0.20 s, first-content 0.40 s, first-thumbnail 0.50 s, fully-settled 3.10 s, cancellation-observed no, longest stall 310 ms, stalls>100ms 4, main busy 2.00 s, memory 180 MB (+1)
    page report (Library): selection-to-shell 1.19 s, first-content 1.37 s, first-thumbnail 2.12 s, fully-settled 2.12 s, cancellation-observed no, longest stall 2119 ms, stalls>100ms 1, main busy 2.14 s, memory 263 MB (+13)
    page report (Map): selection-to-shell 0.77 s, first-content 2.19 s, first-thumbnail not observed, fully-settled 3.91 s, cancellation-observed no, longest stall 2192 ms, stalls>100ms 2, main busy 3.91 s, memory 299 MB (+111)
    """)


class SummaryTests(unittest.TestCase):
    def test_parses_phases_with_parentheses_timeouts_and_missing_values(self):
        rows, notes = summary.parse(BEFORE)
        self.assertEqual([row['phase'] for row in rows], ['after import (faces, bursts, place names)', 'People', 'Library'])
        people = rows[1]
        self.assertTrue(people['timed_out'])
        self.assertEqual(people['settled'], 44.89)
        self.assertEqual((people['stalls'], people['longest'], people['busy']), (131, 1458, 43.78))
        self.assertIsNone(rows[0]['shell'])
        self.assertFalse(rows[2]['timed_out'])
        self.assertTrue(notes[0].startswith('imported 5000'))

    def test_summary_names_the_pages_that_timed_out(self):
        text = summary.summary(BEFORE)
        self.assertIn('44.89 s (timed out)', text)
        self.assertIn('timed out (never settled within the phase limit): People', text)
        markdown = summary.summary(BEFORE, markdown=True)
        self.assertIn('| People | 1.25 s | 1.30 s | 44.89 s (timed out) | 1458 ms | 131 | 43.78 s | 188 MB |', markdown)

    def test_compare_shows_before_and_after_per_phase(self):
        text = summary.compare(BEFORE, AFTER, markdown=True)
        self.assertIn('| People | 1.30 s → 0.40 s | 44.89 s (timed out) → 3.10 s | 1458 ms → 310 ms | 131 → 4 | 43.78 s → 2.00 s |', text)
        # Phases only one side has are kept, with a dash for the other side.
        self.assertIn('| Map | – | – | – | – | – |', text)
        self.assertIn('after import (faces, bursts, place names)', text)

    def test_empty_input_says_so(self):
        self.assertEqual(summary.summary('nothing here'), 'no page report lines found')


def heartbeat(beat, phases_done=0, main_silent=0.0, phase='People'):
    return (f'beat={beat}\tuptime=10.0\tphases_done={phases_done}\tphase_elapsed=2.0\tmain_silent={main_silent}'
            f'\tmemory_mb=200\tlast_finished=none\tdetail=waiting for a quiet main thread\tphase={phase}\n')


class FakeClock:
    def __init__(self):
        self.now = 1000.0

    def __call__(self):
        return self.now


class WatchdogCheckTests(unittest.TestCase):
    def make(self, folder, clock, **limits):
        options = dict(launch_grace=60, stale_heartbeat=30, main_silent=40, no_progress=100)
        options.update(limits)
        return watchdog.Watchdog(folder, Path(folder) / 'diag', print_every=60, poll=1, app_name='Moments',
                                 clock=clock, **options)

    def test_heartbeat_fields_keep_spaces_in_the_phase_name(self):
        fields = watchdog.parse_heartbeat(heartbeat(3, phase='after import (faces, bursts, place names)'))
        self.assertEqual(fields['phase'], 'after import (faces, bursts, place names)')
        self.assertEqual(fields['detail'], 'waiting for a quiet main thread')

    def test_no_heartbeat_is_fine_until_the_launch_grace_runs_out(self):
        with tempfile.TemporaryDirectory() as folder:
            clock = FakeClock()
            dog = self.make(folder, clock)
            clock.now += 59
            self.assertIsNone(dog.check())
            clock.now += 2
            self.assertIn('never started the page probe', dog.check())

    def test_a_heartbeat_that_stops_changing_is_stuck(self):
        with tempfile.TemporaryDirectory() as folder:
            clock = FakeClock()
            dog = self.make(folder, clock)
            path = Path(folder) / 'page-heartbeat.txt'
            path.write_text(heartbeat(1))
            self.assertIsNone(dog.check())
            clock.now += 20
            path.write_text(heartbeat(2))
            self.assertIsNone(dog.check())
            clock.now += 31
            self.assertIn('heartbeat stopped', dog.check())

    def test_an_unanswered_main_thread_is_stuck(self):
        with tempfile.TemporaryDirectory() as folder:
            clock = FakeClock()
            dog = self.make(folder, clock)
            path = Path(folder) / 'page-heartbeat.txt'
            path.write_text(heartbeat(1, main_silent=12.0, phase='Map'))
            self.assertIsNone(dog.check())
            path.write_text(heartbeat(2, main_silent=41.0, phase='Map'))
            self.assertIn('main thread left a ping unanswered for 41 s during "Map"', dog.check())

    def test_finished_phases_count_as_progress(self):
        with tempfile.TemporaryDirectory() as folder:
            clock = FakeClock()
            dog = self.make(folder, clock)
            path = Path(folder) / 'page-heartbeat.txt'
            for beat in range(1, 5):
                path.write_text(heartbeat(beat, phases_done=beat))
                self.assertIsNone(dog.check())
                clock.now += 25
            # Still beating, but stuck in one phase for longer than allowed.
            for beat in range(5, 11):
                path.write_text(heartbeat(beat, phases_done=4))
                clock.now += 25
                reason = dog.check()
            self.assertIn('no phase finished', reason)


class WatchdogRunTests(unittest.TestCase):
    def run_watchdog(self, folder, child, *limits):
        args = ['--page-dir', folder, '--diagnostics', str(Path(folder) / 'diag'), '--poll', '0.1',
                '--print-every', '0.5', '--stop-grace', '2', '--app-name', 'MomentsTestNoSuchApp', *limits,
                '--', sys.executable, '-c', child]
        return subprocess.run([sys.executable, str(ROOT / 'scripts' / 'page_probe_watchdog.py'), *args],
                              capture_output=True, text=True, timeout=60)

    def test_a_finished_command_keeps_its_exit_code(self):
        with tempfile.TemporaryDirectory() as folder:
            result = self.run_watchdog(folder, 'import sys; sys.exit(3)')
            self.assertEqual(result.returncode, 3, result.stdout + result.stderr)
            self.assertFalse((Path(folder) / 'diag').exists())

    def test_a_stuck_probe_is_ended_with_diagnostics(self):
        with tempfile.TemporaryDirectory() as folder:
            # The child plays an app whose main thread stopped answering.
            child = textwrap.dedent(f"""
                import pathlib, time
                folder = pathlib.Path({folder!r})
                (folder / 'page-report.txt').write_text('page probe: 3 cores\\n')
                (folder / 'page-stuck-main.txt').write_text('main thread stack 1 (3 frames):\\n  Moments.MapScreen.body.getter\\n')
                beat = 0
                while True:
                    beat += 1
                    (folder / 'page-heartbeat.txt').write_text(
                        f'beat={{beat}}\\tphases_done=3\\tphase_elapsed=9\\tmain_silent={{beat * 5}}\\tphase=Map\\n')
                    time.sleep(0.1)
                """)
            started = time.monotonic()
            result = self.run_watchdog(folder, child, '--main-silent', '20')
            self.assertEqual(result.returncode, watchdog.STUCK_EXIT, result.stdout + result.stderr)
            self.assertLess(time.monotonic() - started, 30)
            self.assertIn('PROBE-WATCHDOG-BEGIN', result.stdout)
            self.assertIn('Moments.MapScreen.body.getter', result.stdout)
            self.assertIn('main thread left a ping unanswered', result.stdout)
            diag = Path(folder) / 'diag'
            self.assertTrue((diag / 'WATCHDOG.txt').exists())
            self.assertTrue((diag / 'pages' / 'page-stuck-main.txt').exists())
            self.assertTrue((diag / 'processes.txt').exists())

    def test_status_lines_reach_the_log_while_waiting(self):
        with tempfile.TemporaryDirectory() as folder:
            result = self.run_watchdog(folder, 'import time; time.sleep(1.2)')
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            self.assertIn('waiting for the app to start the probe', result.stdout)


if __name__ == '__main__':
    unittest.main()
