"""Check the publishable source tree or the exact staged Git blobs."""
from pathlib import Path
import argparse
import hashlib
import json
import os
import re
import subprocess

ROOT=Path(__file__).resolve().parents[1]
IGNORED={'.git','dist','private-data','local-data','exports','backups','research','qa',
         '__pycache__','node_modules','.venv','.derivedData','DerivedData','build','.build'}
EXACT={'.gitignore','README.md','AGENTS.md','demo/sample-data.json','docs/design-notes.html','docs/ui-quality-principles.md',
       'scripts/apple_photos_bridge.swift','scripts/apple_photos_host.swift',
       'scripts/run-ui-smoke.sh','scripts/run-ui-import-check.sh','scripts/make_synthetic_import_fixtures.swift',
       'vendor/leaflet/leaflet.js','vendor/leaflet/leaflet.css','vendor/leaflet/LICENSE',
       'vendor/leaflet/manifest.json','docs/sharing-design.md',
       'macos/Config/Signing.xcconfig','macos/Config/Local.xcconfig.example',
       'macos/Sources/Moments/Assets.xcassets/Contents.json',
       'macos/Sources/Moments/Assets.xcassets/AccentColor.colorset/Contents.json'}
# Third-party binaries allowed only byte for byte. Regenerate SFace with
# scripts/convert_sface_coreml.py and update these hashes in the same commit.
PINNED={
 'macos/Sources/Moments/People/SFace-LICENSE.txt':'cfc7749b96f63bd31c3c42b5c471bf756814053e847c10f3eb003417bc523d30',
 'macos/Sources/Moments/People/SFace.mlpackage/Manifest.json':'9a9a0616a0d8c0169fe56b4c7afe25aee2a6c2099881b0d2b598a78bcfd874be',
 'macos/Sources/Moments/People/SFace.mlpackage/Data/com.apple.CoreML/model.mlmodel':'eb4d04780c12c424aca59df914a703a687906a667b7af761fb355f1f4f8a379e',
 'macos/Sources/Moments/People/SFace.mlpackage/Data/com.apple.CoreML/weights/weight.bin':'1b29383ae452c0cba52dbf7158cd84ea3d896b8f05e1bc606edb366b0f3f8c34',
 # Country outlines for trip route maps: Natural Earth 1:50m (public domain),
 # simplified and packed by hand; see WorldOutline.swift for the format.
 'macos/Sources/Moments/Resources/WorldOutline.bin':'fced4d2ac26d2c30e25ff10421ff7f196bc8f240c4b56e20516592100f9b8881',
}
# Gitignored per-developer files: skipped when scanning the working tree, and
# never allowlisted, so staging one fails the --staged check.
LOCAL_ONLY={'macos/Config/Local.xcconfig'}
PATTERNS={
 'absolute-user-path':r'/(?:Users|home)/[^/\s]+/',
 'credential':r'\b(?:gh[pousr]_[A-Za-z0-9]{20,}|github_pat_[A-Za-z0-9_]{20,}|sk-[A-Za-z0-9_-]{24,})',
 'private-key':r'-----BEGIN (?:RSA |EC |OPENSSH )?PRIVATE KEY-----',
 'embedded-media':r'data:(?:image|audio|video)/[^;\s"\']+;base64,[A-Za-z0-9+/]{80,}',
 'source-photo-id':r'\bP\d{4}\b',
}

def allowed(name):
    path=Path(name)
    if name in EXACT:
        return True
    if path.parts and path.parts[0] == 'macos' and path.suffix in {'.swift', '.yml', '.xcstrings'}:
        return True
    if path.parts[:2] == ('.github', 'workflows') and path.suffix in {'.yml', '.yaml'}:
        return True
    return (len(path.parts)==2 and path.parts[0] in {'src','scripts','tests'}
       and path.suffix in {'.html','.css','.js','.mjs','.py'})

def candidates(staged=False):
    if staged:
        result=subprocess.run(['git','ls-files','--cached','-z'],cwd=ROOT,capture_output=True,check=True)
        for raw in result.stdout.split(b'\0'):
            if not raw:continue
            name=raw.decode();data=subprocess.run(['git','show',':'+name],cwd=ROOT,capture_output=True,check=True).stdout
            yield name,data
    else:
        for folder,dirs,files in os.walk(ROOT):
            dirs[:]=[d for d in dirs if d not in IGNORED and not d.endswith(('.xcodeproj','.xcworkspace'))]
            for name in files:
                if name in IGNORED:continue  # a worktree's .git is a file
                path=Path(folder)/name
                if path.relative_to(ROOT).as_posix() in LOCAL_ONLY:continue
                yield path.relative_to(ROOT).as_posix(),path.read_bytes() if not path.is_symlink() else b'\0'

def inspect(name,data):
    if name in PINNED:
        return [] if hashlib.sha256(data).hexdigest()==PINNED[name] else ['pinned-file-changed']
    errors=[]
    if not allowed(name):errors.append('outside-source-allowlist')
    # The string catalog grows with every language and screen; it is still
    # text and still checked against every pattern below.
    if len(data)>(1_000_000 if name.endswith('.xcstrings') else 300_000):errors.append('oversized-file')
    try:text=data.decode('utf-8')
    except UnicodeDecodeError:return errors+['binary-file']
    if '\0' in text:errors.append('binary-or-symlink')
    for rule,pattern in PATTERNS.items():
        if re.search(pattern,text):errors.append(rule)
    if name=='demo/sample-data.json':
        try:
            sample=json.loads(text)
            assert sample['kind']=='synthetic-demo-only'
            assert set(sample)=={'kind','assets','groups','sourceNotes','covers'}
            for asset in sample['assets']:
                assert re.fullmatch(r'D\d{4}',asset['id'])
                assert not any(k in asset for k in ['dataURI','filename','filePath','exif','locationProvenance'])
                assert asset['date'] is None or asset['date'].startswith('2000:')
                if asset['geo']:
                    assert set(asset['geo'])=={'latitude','longitude'}
                    assert 0<=asset['geo']['latitude']<=.02 and 0<=asset['geo']['longitude']<=.02
        except (AssertionError,KeyError,TypeError,ValueError):errors.append('invalid-synthetic-demo')
    return errors

def scan(staged=False):
    failures=[];count=0
    for name,data in candidates(staged):
        count+=1
        for rule in inspect(name,data):failures.append({'file':name,'rule':rule})
    return count,failures

if __name__=='__main__':
    parser=argparse.ArgumentParser();parser.add_argument('--staged',action='store_true')
    count,failures=scan(parser.parse_args().staged)
    print(json.dumps({'checked_files':count,'passed':not failures,'failures':failures},ensure_ascii=False,indent=2))
    raise SystemExit(bool(failures))
