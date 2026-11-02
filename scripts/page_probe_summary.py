"""Turn PageProbe reports into a short table, or compare two of them.

Usage:
  python3 scripts/page_probe_summary.py REPORT [--markdown]
  python3 scripts/page_probe_summary.py --compare BEFORE AFTER [--markdown]

REPORT is page-report.txt, or a CI job log that contains its lines (the log's
timestamps are ignored). Times are seconds from the click to that point:
  shell    the page's frame appeared
  content  its first useful content was ready
  settled  the main thread went quiet (the end of the last stretch of 50 ms
           or more before a quiet 1.5 s); "timed out" means it never did
           within the probe's limit for that phase
  longest  the longest single main-thread stretch, what feels like a freeze
  stalls   stretches over 100 ms
  busy     main-thread time spent during the phase
"""
from pathlib import Path
import argparse
import re
import sys

LINE = re.compile(
    r'page report \((?P<phase>.+?)\): '
    r'selection-to-shell (?P<shell>[\d.]+ s|not observed), '
    r'first-content (?P<content>[\d.]+ s|not observed), '
    r'first-thumbnail (?P<thumbnail>[\d.]+ s|not observed), '
    r'fully-settled (?P<settled>[\d.]+) s(?P<timed> \(timed out\))?, '
    r'cancellation-observed (?:yes|no), '
    r'longest stall (?P<longest>\d+) ms, '
    r'stalls>100ms (?P<stalls>\d+), '
    r'main busy (?P<busy>[\d.]+) s, '
    r'memory (?P<memory>\d+) MB'
)
IMPORT = re.compile(r'(imported \d+ .*)$')


def seconds(value):
    return None if value == 'not observed' else float(value.split()[0])


def parse(text):
    rows, notes = [], []
    for line in text.splitlines():
        match = LINE.search(line)
        if match:
            rows.append({
                'phase': match['phase'],
                'shell': seconds(match['shell']),
                'content': seconds(match['content']),
                'settled': float(match['settled']),
                'timed_out': bool(match['timed']),
                'longest': int(match['longest']),
                'stalls': int(match['stalls']),
                'busy': float(match['busy']),
                'memory': int(match['memory']),
            })
            continue
        found = IMPORT.search(line)
        if found and found[1] not in notes:
            notes.append(found[1])
    return rows, notes


def fmt(value, unit='s'):
    if value is None:
        return '–'
    if unit == 'ms':
        return f'{value} ms'
    return f'{value:.2f} s'


def settled(row):
    return fmt(row['settled']) + (' (timed out)' if row['timed_out'] else '')


COLUMNS = ['phase', 'shell', 'content', 'settled', 'longest', 'stalls >100 ms', 'main busy', 'memory']


def cells(row):
    return [row['phase'], fmt(row['shell']), fmt(row['content']), settled(row), fmt(row['longest'], 'ms'),
            str(row['stalls']), fmt(row['busy']), f"{row['memory']} MB"]


def change(before, after, key, unit='s'):
    if before is None or after is None:
        return '–'
    old, new = before.get(key), after.get(key)
    if old is None or new is None:
        return f'{fmt(old, unit)} → {fmt(new, unit)}'
    text = f'{fmt(old, unit)} → {fmt(new, unit)}'
    if key == 'settled':
        text = f"{settled(before)} → {settled(after)}"
    return text


COMPARE_COLUMNS = ['phase', 'content', 'settled', 'longest', 'stalls >100 ms', 'main busy']


def compare_cells(phase, before, after):
    stalls = '–' if before is None or after is None else f"{before['stalls']} → {after['stalls']}"
    return [phase, change(before, after, 'content'), change(before, after, 'settled'),
            change(before, after, 'longest', 'ms'), stalls, change(before, after, 'busy')]


def table(header, body, markdown):
    if markdown:
        lines = ['| ' + ' | '.join(header) + ' |', '|' + '---|' * len(header)]
        lines += ['| ' + ' | '.join(row) + ' |' for row in body]
        return '\n'.join(lines)
    widths = [max(len(str(row[i])) for row in [header] + body) for i in range(len(header))]
    return '\n'.join('  '.join(str(cell).ljust(width) for cell, width in zip(row, widths)).rstrip()
                     for row in [header] + body)


def summary(text, markdown=False):
    rows, notes = parse(text)
    if not rows:
        return 'no page report lines found'
    out = table(COLUMNS, [cells(row) for row in rows], markdown)
    if notes:
        out = '\n'.join(notes) + '\n\n' + out
    slow = [row['phase'] for row in rows if row['timed_out']]
    if slow:
        out += '\n\ntimed out (never settled within the phase limit): ' + ', '.join(slow)
    return out


def compare(before_text, after_text, markdown=False):
    before, _ = parse(before_text)
    after, _ = parse(after_text)
    if not before or not after:
        return 'no page report lines found in ' + ('the first report' if not before else 'the second report')
    by_before = {row['phase']: row for row in before}
    by_after = {row['phase']: row for row in after}
    phases = [row['phase'] for row in before] + [row['phase'] for row in after if row['phase'] not in by_before]
    return table(COMPARE_COLUMNS, [compare_cells(phase, by_before.get(phase), by_after.get(phase)) for phase in phases], markdown)


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument('report', nargs='?')
    parser.add_argument('--compare', nargs=2, metavar=('BEFORE', 'AFTER'))
    parser.add_argument('--markdown', action='store_true')
    args = parser.parse_args(argv)
    if args.compare:
        before, after = (Path(name).read_text(errors='replace') for name in args.compare)
        print(compare(before, after, args.markdown))
    elif args.report:
        print(summary(Path(args.report).read_text(errors='replace'), args.markdown))
    else:
        parser.error('give a report, or --compare BEFORE AFTER')
    return 0


if __name__ == '__main__':
    sys.exit(main())
