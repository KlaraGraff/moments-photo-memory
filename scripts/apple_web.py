"""Wire the approved Apple source into a page without changing its origin/notes key."""
import json

def integrate_apple(page,source,connection=None):
    source=source.resolve()
    store=(source/'apple-store.js').read_text()
    ui=(source/'apple-import.js').read_text()
    css=(source/'apple-import.css').read_text()
    config=json.dumps(connection,ensure_ascii=False).replace('</',r'<\/')
    bootstrap=store+"\nconst restoredApple=await AppleImportStore.load().catch(()=>({assets:[],groups:[],favoriteIds:[],error:'storage-unavailable'}));\n"
    start="'use strict';"
    if page.count(start)!=1:raise ValueError('Expected one application entry')
    page=page.replace(start,"(async()=>{\n'use strict';\n"+bootstrap,1)
    declaration="const A=JSON.parse(document.getElementById('assets').textContent),byId=Object.fromEntries(A.map(a=>[a.id,a]));"
    if declaration not in page:raise ValueError('Asset bootstrap has changed')
    restored="const A=JSON.parse(document.getElementById('assets').textContent);\nfor(const asset of restoredApple.assets||[])if(!A.some(a=>a.id===asset.id))A.push(asset);\nconst byId=Object.fromEntries(A.map(a=>[a.id,a]));"
    page=page.replace(declaration,restored,1)
    # If the local asset database is temporarily unavailable, keep orphan Apple
    # notes intact instead of invalidating every earlier photo's writing.
    membership="byId[key.split(':')[1]]&&v"
    guard="(byId[key.split(':')[1]]||/^APL[a-f0-9]{64}$/.test(key.split(':')[1]))&&v"
    if membership not in page:raise ValueError('Notes validation has changed')
    page=page.replace(membership,guard,1)
    page=page.replace('</style>','\n'+css+'</style>',1)
    page=page.replace('window.demo={','const APPLE_CONNECTION='+config+';\n'+ui+'\nwindow.demo={',1)
    end='};renderFrame();Motion.start();\n</script>'
    if end not in page:raise ValueError('Application boot footer has changed')
    failure="})().catch(()=>{const warning=document.createElement('p');warning.setAttribute('role','alert');warning.textContent='照片页暂未能初始化，请保留原标签页并刷新重试。 / Unable to initialise Moments. Keep this tab and retry.';document.body.prepend(warning);});\n"
    return page.replace(end,'};renderFrame();Motion.start();\n'+failure+'</script>',1)
