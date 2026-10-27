#!/usr/bin/env python3
"""Add or update German and Chinese translations in a String Catalog.

    add_translations.py CATALOG TSV [PLURALS_JSON]

TSV rows: key<TAB>zh-Hans<TAB>de (English is the key). PLURALS_JSON maps a
key to {"en": [one, other], "de": [one, other], "zh-Hans": other}. Entries
keep their order; new keys are appended. Written in Xcode's own layout so
Xcode leaves the file as it is.
"""
import json
import sys
from pathlib import Path


def unit(value):
    return {'stringUnit': {'state': 'translated', 'value': value}}


def plural(forms):
    if isinstance(forms, str):
        return {'variations': {'plural': {'other': unit(forms)}}}
    one, other = forms
    return {'variations': {'plural': {'one': unit(one), 'other': unit(other)}}}


def main():
    catalog_path = Path(sys.argv[1])
    text = catalog_path.read_text()
    existing = json.loads(text)['strings']
    added = {}
    for line in Path(sys.argv[2]).read_text().splitlines():
        if not line.strip() or line.startswith('#'):
            continue
        key, zh, de = line.split('\t')
        added[key] = {'localizations': {'de': unit(de), 'en': unit(key), 'zh-Hans': unit(zh)}}
    if len(sys.argv) > 3:
        for key, forms in json.loads(Path(sys.argv[3]).read_text()).items():
            added[key] = {'localizations': {lang: plural(forms[lang]) for lang in ('de', 'en', 'zh-Hans')}}
    clashes = sorted(set(added) & set(existing))
    if clashes:
        sys.exit('already in the catalog: ' + ', '.join(clashes))
    # Append as text so the rest of the file, and other branches' edits to
    # it, stay untouched.
    entries = json.dumps(added, ensure_ascii=False, indent=2, separators=(',', ' : '))
    body = '\n'.join('  ' + line for line in entries.splitlines()[1:-1])
    end = text.rindex('\n  },\n  "version"')
    text = text[:end] + ',\n' + body + text[end:]
    json.loads(text)
    catalog_path.write_text(text)


if __name__ == '__main__':
    main()
