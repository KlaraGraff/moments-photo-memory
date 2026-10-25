"""Build a self-contained prototype from synthetic demo data by default."""
from pathlib import Path
import argparse
import base64
import html
import json
from apple_web import integrate_apple

ROOT = Path(__file__).resolve().parents[1]
ASSET_FIELDS = {'id', 'date', 'trip', 'place', 'scene', 'tags', 'width', 'height',
                'geo', 'titleLabels', 'locationArea', 'locationSite',
                'locationFullLabels', 'locationConfidenceText', 'type', 'previewURL',
                'originalURL', 'livePhotoURL', 'duration', 'confirmedDateDay',
                'confirmedDateLabel', 'timeConfidence', 'rawDate'}

def illustration(index, width, height):
    """Original geometric artwork; no image files or personal photos are read."""
    colors = [('#e8ddd0', '#b27d63', '#647e74'), ('#e4e8dd', '#83977f', '#d3b88d'),
              ('#e0e6e8', '#839eaf', '#c29d79')]
    bg, hill, foreground = colors[index % len(colors)]
    svg = f'''<svg xmlns="http://www.w3.org/2000/svg" width="{width}" height="{height}" viewBox="0 0 600 720"><rect width="600" height="720" fill="{bg}"/><circle cx="{125+index%5*60}" cy="180" r="62" fill="#f9f1d8"/><path d="M0 490 Q170 230 340 450 T600 420 V720 H0Z" fill="{hill}"/><path d="M0 590 Q210 410 410 570 T600 500 V720 H0Z" fill="{foreground}"/><path d="M270 720 Q310 530 420 500" fill="none" stroke="#f6efdc" stroke-width="8" opacity=".6"/><text x="36" y="655" fill="#fffaf1" font-family="sans-serif" font-size="17" letter-spacing="3">DEMO {index+1:02d}</text></svg>'''
    return 'data:image/svg+xml;base64,' + base64.b64encode(svg.encode()).decode()

def load_data(private_path=None):
    if private_path:
        path = Path(private_path).resolve()
        if not path.is_relative_to(ROOT / 'private-data'):
            raise ValueError('Private input must be inside private-data/')
    else:
        path = ROOT / 'demo/sample-data.json'
    raw = json.loads(path.read_text())
    assets = []
    for i, original in enumerate(raw['assets']):
        asset = {k: original[k] for k in ASSET_FIELDS if k in original}
        asset.setdefault('width', 600);asset.setdefault('height', 720)
        asset['dataURI'] = original.get('dataURI') if private_path else None
        if not asset['dataURI']:
            asset['dataURI'] = illustration(i, asset['width'], asset['height'])
        assets.append(asset)
    config = {k: raw[k] for k in ['groups', 'sourceNotes', 'covers']}
    return assets, config

def js_json(value):
    return json.dumps(value, ensure_ascii=False).replace('</', r'<\/')

def build(private_path=None):
    assets, config = load_data(private_path)
    source = ROOT / 'src'
    page = (source / 'ui-template.html').read_text()
    css = '\n'.join((source / name).read_text() for name in ['custom-places.css', 'motion.css', 'product-map.css', 'library-view.css', 'footprints.css', 'quality-polish.css'])
    modules = '\n'.join((source / name).read_text() for name in ['custom-places.js', 'motion.js'])
    page = page.replace('__ASSETS__', js_json(assets)).replace('__DEMO_CONFIG__', js_json(config))
    page = page.replace('</style>', '\n'+css+'</style>', 1)
    page = page.replace("'use strict';", "'use strict';\n"+modules, 1)
    integration = (source/'product-map.js').read_text()+'\n'+(source/'product-integration.js').read_text()
    integration = integration.replace('__MAP_WORKSPACE_URL__', js_json('./map-workspace.html'))
    library={'groups':config['groups'],'sourceNotes':config['sourceNotes'],'favoriteIds':[],'summary':{'records':len(assets)}}
    integration+='\nconst LIBRARY='+js_json(library)+';\n'+(source/'library-view.js').read_text()+'\n'+(source/'globe-bridge.js').read_text()+'\n'+(source/'footprints.js').read_text()
    page = page.replace('window.demo={', (source/'prototype.js').read_text()+'\n'+integration+'\nwindow.demo={', 1)
    page = page.replace('};renderFrame();\n</script>', '};renderFrame();Motion.start();\n</script>')
    page = page.replace('<div id="filter-panel"', '<section id="place-editor" hidden></section><div id="filter-panel"', 1)
    page = integrate_apple(page,source)
    target = ROOT / 'dist';target.mkdir(exist_ok=True)
    (target/'index.html').write_text(page)
    map_page = (source/'map-template.html').read_text().replace('__ASSETS__', js_json(assets)).replace('__DEMO_CONFIG__', js_json(config))
    map_page = map_page.replace('__MAP_WHEEL_JS__', (source/'map-wheel.js').read_text())
    for marker,name in [('__ROAD_ROUTING_JS__','road-routing.js'),('__ROAD_PANEL_JS__','road-panel.js'),('__ROAD_PANEL_CSS__','road-panel.css')]:
        map_page=map_page.replace(marker,(source/name).read_text())
    map_page = map_page.replace('__LEAFLET_CSS__', (ROOT/'vendor/leaflet/leaflet.css').read_text())
    map_page = map_page.replace('__LEAFLET_JS__', (ROOT/'vendor/leaflet/leaflet.js').read_text().replace('</script', r'<\/script'))
    (target/'map.html').write_text(map_page)
    workspace = (source/'map-workspace.html').read_text()
    for marker, file in [('__LEAFLET_CSS__', ROOT/'vendor/leaflet/leaflet.css'),
                         ('__LEAFLET_JS__', ROOT/'vendor/leaflet/leaflet.js'),
                         ('__MAP_WHEEL_JS__', source/'map-wheel.js'),
                         ('__ROAD_ROUTING_JS__', source/'road-routing.js'),
                         ('__ROAD_PANEL_JS__', source/'road-panel.js'),
                         ('__ROAD_PANEL_CSS__', source/'road-panel.css'),
                         ('__WORKSPACE_JS__', source/'map-workspace.js'),
                         ('__WORKSPACE_CSS__', source/'map-workspace.css')]:
        content = file.read_text()
        workspace = workspace.replace(marker, content.replace('</script', r'<\/script') if file.suffix=='.js' else content)
    (target/'map-workspace.html').write_text(workspace)
    (target/'globe-workspace.html').write_text((source/'globe-workspace.html').read_text())
    (target/'docs').mkdir(exist_ok=True)
    (target/'docs/design-notes.html').write_bytes((ROOT/'docs/design-notes.html').read_bytes())
    return len(assets)

if __name__ == '__main__':
    parser = argparse.ArgumentParser();parser.add_argument('--private-data')
    args = parser.parse_args()
    count = build(args.private_data)
    print(f'Built {count} '+('local private' if args.private_data else 'synthetic demo')+' previews in dist/')
