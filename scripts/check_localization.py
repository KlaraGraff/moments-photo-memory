#!/usr/bin/env python3
"""Fail when a user-visible string has no German or Chinese translation.

Reads the .xcloc bundles written by `xcodebuild -exportLocalizations`, which
holds every string Xcode extracted from the Swift sources merged with the
String Catalogs, so a string added in code but never translated shows up
here even though it is missing from Localizable.xcstrings.

Usage: check_localization.py EXPORT_DIR
"""
import json
import re
import sys
import xml.etree.ElementTree as ET
from pathlib import Path

NS = {'x': 'urn:oasis:names:tc:xliff:document:1.2'}
LANGUAGES = ('de', 'zh-Hans')
DONE_STATES = {'translated', 'final', 'signed-off', 'needs-review-l10n'}


def missing_units(xliff):
    root = ET.parse(xliff).getroot()
    for file in root.findall('x:file', NS):
        original = file.get('original', '')
        for unit in file.iter(f"{{{NS['x']}}}trans-unit"):
            if unit.get('translate') == 'no':
                continue
            source = unit.find('x:source', NS)
            target = unit.find('x:target', NS)
            note = unit.find('x:note', NS)
            text = '' if source is None else ''.join(source.itertext())
            # Numbers and punctuation alone ("%lld", "%@/%@") need no translation.
            if not re.search(r'[^\W\d_]', re.sub(r'%(\d+\$)?(lld|ld|d|@|f|\.\df)', '', text)):
                continue
            translated = (
                target is not None
                and ''.join(target.itertext()).strip()
                and target.get('state', 'translated') in DONE_STATES
            )
            if not translated:
                yield {
                    'file': original,
                    'id': unit.get('id'),
                    'source': text,
                    'note': '' if note is None else ''.join(note.itertext()),
                }


def main():
    export = Path(sys.argv[1])
    problems = {}
    for language in LANGUAGES:
        xliffs = list(export.glob(f'{language}.xcloc/Localized Contents/{language}.xliff'))
        if not xliffs:
            print(f'::error::no {language} export in {export}')
            return 1
        for unit in missing_units(xliffs[0]):
            entry = problems.setdefault(unit['id'], {**unit, 'languages': []})
            entry['languages'].append(language)
    if not problems:
        print('Every string has de and zh-Hans translations.')
        return 0
    print(f'::error::{len(problems)} strings are missing a de or zh-Hans translation. '
          'Add them to macos/Sources/Moments/Resources/Localizable.xcstrings '
          '(or the catalog named below).')
    for entry in sorted(problems.values(), key=lambda e: (e['file'], e['id'])):
        print('MISSING ' + json.dumps(entry, ensure_ascii=False))
    return 1


if __name__ == '__main__':
    sys.exit(main())
