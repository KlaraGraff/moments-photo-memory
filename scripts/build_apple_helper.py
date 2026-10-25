"""Build a local, ad-hoc-signed PhotoKit host. Never reads the Photos library."""
import argparse
import json
import os
from pathlib import Path
import plistlib
import secrets
import subprocess
import tempfile

ROOT=Path(__file__).resolve().parents[1]
IDENTIFIER='com.moments.photos.helper'

def prepare(output, connection, port=8768):
    output=Path(output).resolve();connection=Path(connection).resolve()
    if not 1024<=port<=65535:raise ValueError('Invalid helper port')
    output.mkdir(parents=True,exist_ok=True);connection.parent.mkdir(parents=True,exist_ok=True)
    prior=json.loads(connection.read_text()) if connection.exists() else {}
    token=prior.get('token','')
    if len(token)!=64 or any(c not in '0123456789abcdef' for c in token):token=secrets.token_hex(32)
    app=output/'Moments Photos Helper.app';contents=app/'Contents';resources=contents/'Resources';binary=contents/'MacOS'
    resources.mkdir(parents=True,exist_ok=True);binary.mkdir(exist_ok=True)
    runtime={'port':port,'token':token}
    runtime_path=resources/'connection.json';runtime_path.write_text(json.dumps(runtime));runtime_path.chmod(0o600)
    info={'CFBundleIdentifier':IDENTIFIER,'CFBundleName':'Moments Photos Helper','CFBundleDisplayName':'片刻照片助手',
          'CFBundleExecutable':'MomentsPhotosHelper','CFBundlePackageType':'APPL','CFBundleVersion':'1',
          'CFBundleShortVersionString':'0.1.0','LSMinimumSystemVersion':'13.0','NSHighResolutionCapable':True,
          'NSPhotoLibraryUsageDescription':'片刻读取你选择范围内的照片、拍摄信息和预览，帮助整理旅行与记录回忆；不会修改或删除照片。'}
    with (contents/'Info.plist').open('wb') as f:plistlib.dump(info,f)
    messages={
       'zh-Hans':'片刻读取你选择范围内的照片、拍摄信息和预览，帮助整理旅行与记录回忆；不会修改或删除照片。',
       'en':'Moments reads photos, capture information and previews in your chosen scope to organise memories. It does not modify or delete photos.',
       'de':'Moments liest Fotos, Aufnahmeinformationen und Vorschaubilder im gewählten Bereich, um Erinnerungen zu ordnen. Fotos werden nicht verändert oder gelöscht.'}
    for lang,message in messages.items():
        folder=resources/(lang+'.lproj');folder.mkdir(exist_ok=True)
        (folder/'InfoPlist.strings').write_text('"NSPhotoLibraryUsageDescription" = '+json.dumps(message,ensure_ascii=False)+';\n')
    config={'baseURL':f'http://127.0.0.1:{port}','token':token,'helperPath':app.as_uri()}
    return app,config

def build(output,connection,port=8768):
    app,config=prepare(output,connection,port)
    executable=app/'Contents/MacOS/MomentsPhotosHelper'
    with tempfile.TemporaryDirectory(prefix='moments-host-build-',dir='/private/tmp') as temp:
        subprocess.run(['xcrun','swiftc','-swift-version','6','-warnings-as-errors','-parse-as-library','-DMOMENTS_HOST',
            '-module-cache-path',str(Path(temp)/'cache'),str(ROOT/'scripts/apple_photos_bridge.swift'),
            str(ROOT/'scripts/apple_photos_host.swift'),'-o',str(executable)],check=True)
    subprocess.run(['codesign','--force','--sign','-','--timestamp=none','--identifier',IDENTIFIER,str(app)],check=True,capture_output=True)
    subprocess.run(['codesign','--verify','--strict',str(app)],check=True,capture_output=True)
    # Publish the page's connection only after the host bundle is complete.
    path=Path(connection).resolve();candidate=path.with_suffix('.candidate.json');candidate.write_text(json.dumps(config));candidate.chmod(0o600);os.replace(candidate,path)
    return app

if __name__=='__main__':
    parser=argparse.ArgumentParser();parser.add_argument('--output-dir',type=Path,default=ROOT/'dist/apple-helper')
    parser.add_argument('--connection',type=Path,default=ROOT/'private-data/apple-connection.local.json')
    parser.add_argument('--port',type=int,default=8768);args=parser.parse_args()
    result=build(args.output_dir,args.connection,args.port)
    print('Built local Photos helper:',result)
    print('Ad-hoc signature verified. No photo permission requested and no library read.')
