#!/usr/bin/env python3
"""Pinned public fixtures; downloads are outside benchmark timing."""
from pathlib import Path
import json, urllib.request, zipfile, shutil, hashlib
root = Path(__file__).resolve().parent/'Fixtures'
root.mkdir(exist_ok=True)
def download(url, target):
    target.parent.mkdir(parents=True,exist_ok=True)
    urllib.request.urlretrieve(url,target)
yomitan = '67db60ddc2cbd7b5172d777c117e3201d7ddff0f'
model = 'cfef6f6f2a70783dedc0bfae40cecbc2052285d3'
for page in range(5):
    filename=f'en_Pepper-and-Carrot_by-David-Revoy_E01P{page:02}.jpg'
    download('https://www.peppercarrot.com/0_sources/ep01_Potion-of-Flight/low-res/'+filename,root/'comic'/filename)
tree=json.load(urllib.request.urlopen('https://api.github.com/repos/yomidevs/yomitan/git/trees/'+yomitan+'?recursive=1'))
for entry in tree['tree']:
    prefix='test/data/dictionaries/valid-dictionary1/'
    if entry['path'].startswith(prefix) and entry['type']=='blob':
        download('https://raw.githubusercontent.com/yomidevs/yomitan/'+yomitan+'/'+entry['path'],root/'dictionary'/entry['path'][len(prefix):])
for path in ['Data/com.apple.CoreML/model.mlmodel','Data/com.apple.CoreML/weights/weight.bin','Manifest.json']:
    package='DepthAnythingV2SmallF16.mlpackage/'+path
    download('https://huggingface.co/apple/coreml-depth-anything-v2-small/resolve/'+model+'/'+package,root/'model'/package)
download('https://huggingface.co/apple/coreml-depth-anything-v2-small/resolve/'+model+'/README.md',root/'model'/'MODEL-CARD.md')
for i in range(128):
    target=root/'comic128'/f'{i:04}.jpg';target.parent.mkdir(exist_ok=True)
    shutil.copy2(sorted((root/'comic').glob('*.jpg'))[i%5],target)
folder=root/'dictionary4000';folder.mkdir(exist_ok=True)
for index in range(4000):
    payload=json.dumps([[f'語{index}','ご','noun','',0,[f'Dictionary stress entry {index} '+('definition text '*20)],index,'']],ensure_ascii=False).encode()
    (folder/f'term_bank_{index:04}.json').write_bytes(payload)
for name in ['source','comic','comic128','dictionary','dictionary4000','model']:
    with zipfile.ZipFile(root/(name+'.zip'),'w',compression=zipfile.ZIP_STORED if name.startswith('comic') else zipfile.ZIP_DEFLATED) as z:
        for path in sorted((root/name).rglob('*')):
            if path.is_file():
                info=zipfile.ZipInfo(path.relative_to(root/name).as_posix(),date_time=(2026,1,1,0,0,0))
                info.compress_type=zipfile.ZIP_STORED if name.startswith('comic') else zipfile.ZIP_DEFLATED
                z.writestr(info,path.read_bytes())
manifest=[{'path':p.relative_to(root).as_posix(),'bytes':p.stat().st_size,'sha256':hashlib.sha256(p.read_bytes()).hexdigest()}
          for p in sorted(root.rglob('*')) if p.is_file() and p.name!='manifest.json']
(root/'manifest.json').write_text(json.dumps(manifest,indent=2)+'\n')
