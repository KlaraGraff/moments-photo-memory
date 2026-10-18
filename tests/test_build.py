from pathlib import Path
import importlib.util
import json
import subprocess
import unittest
import re

ROOT=Path(__file__).resolve().parents[1]
def module(name):
    spec=importlib.util.spec_from_file_location(name,ROOT/'scripts'/f'{name}.py')
    value=importlib.util.module_from_spec(spec);spec.loader.exec_module(value);return value

class SourceAndBuildTests(unittest.TestCase):
    def test_synthetic_default_and_output(self):
        build=module('build');assets,config=build.load_data()
        self.assertTrue(all(a['dataURI'].startswith('data:image/svg+xml;base64,') for a in assets))
        ids={a['id'] for a in assets}
        self.assertEqual(ids,{p for trip in config['groups'].values() for group in trip for p in group})
        self.assertEqual(len(ids),len(assets))
        self.assertEqual(build.build(),len(assets))
        for name in ['index.html','map.html']:
            text=(ROOT/'dist'/name).read_text()
            self.assertNotIn('__ASSETS__',text);self.assertNotIn('__DEMO_CONFIG__',text)
            for script in re.findall(r'<script>(.*?)</script>',text,re.S):
                subprocess.run(['node','--check'],input=script,text=True,check=True,capture_output=True)

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

if __name__=='__main__':unittest.main()
