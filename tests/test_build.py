from pathlib import Path
import importlib.util
import json
import subprocess
import unittest
import re
import sys
import tempfile
import plistlib

ROOT=Path(__file__).resolve().parents[1]
def module(name):
    spec=importlib.util.spec_from_file_location(name,ROOT/'scripts'/f'{name}.py')
    value=importlib.util.module_from_spec(spec)
    # Match direct script execution while leaving the test process unchanged.
    sys.path.insert(0,str(ROOT/'scripts'))
    try:spec.loader.exec_module(value)
    finally:sys.path.pop(0)
    return value

class SourceAndBuildTests(unittest.TestCase):
    def test_synthetic_default_and_output(self):
        build=module('build');assets,config=build.load_data()
        self.assertTrue(all(a['dataURI'].startswith('data:image/svg+xml;base64,') for a in assets))
        ids={a['id'] for a in assets}
        self.assertEqual(ids,{p for trip in config['groups'].values() for group in trip for p in group})
        self.assertEqual(len(ids),len(assets))
        self.assertEqual(build.build(),len(assets))
        for name in ['index.html','map.html','map-workspace.html']:
            text=(ROOT/'dist'/name).read_text()
            self.assertNotIn('__ASSETS__',text);self.assertNotIn('__DEMO_CONFIG__',text)
            for script in re.findall(r'<script>(.*?)</script>',text,re.S):
                subprocess.run(['node','--check'],input=script,text=True,check=True,capture_output=True)
        main=(ROOT/'dist/index.html').read_text()
        workspace=(ROOT/'dist/map-workspace.html').read_text()
        self.assertIn('const productMapURL="./map-workspace.html"',main)
        self.assertIn("S.showMap=true",main)
        self.assertIn("trialKey='moments-demo-notes-v1'",main)
        self.assertIn('--line-soft',main)
        self.assertIn('font-variant-numeric: tabular-nums',main)
        self.assertIn('Motion.feedback',main)
        self.assertNotIn('data:image/svg+xml;base64,',workspace)
        self.assertNotIn('__WORKSPACE_JS__',workspace)

    def test_private_input_must_stay_in_private_directory(self):
        with self.assertRaises(ValueError):module('build').load_data(ROOT/'demo/sample-data.json')

    def test_privacy_guard_rejects_force_added_data(self):
        checker=module('check_privacy')
        self.assertIn('outside-source-allowlist',checker.inspect('private-data/photo.jpg',b'abc'))
        self.assertIn('embedded-media',checker.inspect('src/page.html',b'data:image/jpeg;base64,'+b'A'*90))
        self.assertIn('absolute-user-path',checker.inspect('src/page.html',b'/'+b'Users/'+b'sample-user/Pictures/example'))
        self.assertIn('credential',checker.inspect('src/sample.js',b'gh'+b'p_'+b'A'*25))

    def test_publishable_tree(self):
        count,failures=module('check_privacy').scan()
        self.assertGreater(count,10);self.assertEqual(failures,[])

    def test_apple_boot_preserves_notes_when_local_database_is_unavailable(self):
        apple=module('apple_web');identifier='APL'+'a'*64
        page="""<style></style><script>'use strict';
const A=JSON.parse(document.getElementById('assets').textContent),byId=Object.fromEntries(A.map(a=>[a.id,a]));
const notes=JSON.parse(sessionStorage.getItem('original-notes-key'));
const valid=Object.entries(notes).every(([key,v])=>/^(me|companion):(?:[PV]\\d{4}|APL[a-f0-9]{64})$/.test(key)&&byId[key.split(':')[1]]&&v);
function renderFrame(){globalThis.bootResult={valid,count:A.length};}
const Motion={start(){}};
window.demo={};renderFrame();Motion.start();
</script>"""
        built=apple.integrate_apple(page,ROOT/'src')
        self.assertLess(built.index('await AppleImportStore.load'),built.index('const byId='))
        self.assertIn('const APPLE_CONNECTION=null;',built)
        self.assertIn("getItem('original-notes-key')",built)
        script=re.search(r'<script>(.*?)</script>',built,re.S)[1]
        setup="const document={getElementById:()=>({textContent:'[]'})},window={},sessionStorage={getItem:()=>"+json.dumps(json.dumps({'me:'+identifier:{'text':'A synthetic memory'}}))+"};\n"
        subprocess.run(['node','--input-type=module'],input=setup+script+"\nawait new Promise(r=>setTimeout(r,0));if(!bootResult.valid||bootResult.count!==0)throw Error('Notes lost');",text=True,check=True,capture_output=True)

    def test_apple_bundle_metadata_and_private_pairing(self):
        helper=module('build_apple_helper')
        with tempfile.TemporaryDirectory() as folder:
            base=Path(folder);connection=base/'connection.local.json'
            app,config=helper.prepare(base/'output',connection)
            self.assertFalse(connection.exists(),'Pairing must publish only after a successful build')
            self.assertEqual(config['baseURL'],'http://127.0.0.1:8768')
            self.assertRegex(config['token'],r'^[a-f0-9]{64}$')
            info=plistlib.loads((app/'Contents/Info.plist').read_bytes())
            self.assertIn('NSPhotoLibraryUsageDescription',info)
            self.assertEqual(info['CFBundleExecutable'],'MomentsPhotosHelper')
            self.assertEqual((app/'Contents/Resources/connection.json').stat().st_mode&0o777,0o600)
            for language in ['zh-Hans','en','de']:
                self.assertTrue((app/'Contents/Resources'/f'{language}.lproj/InfoPlist.strings').exists())
            with self.assertRaises(ValueError):helper.prepare(base/'invalid',connection,80)

if __name__=='__main__':unittest.main()
