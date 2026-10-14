#!/usr/bin/env python3
"""Always produce four pose comparisons. Baselines are installed only after Charles's approval."""
from pathlib import Path
from PIL import Image, ImageDraw
import argparse, hashlib, json, html
p=argparse.ArgumentParser();p.add_argument('candidate',type=Path);p.add_argument('--baseline',type=Path,default=Path(__file__).resolve().parents[1]/'screenshots/golden-approved');a=p.parse_args()
poses=['idle-focus','looking-at-you','drift','gesture']
if a.baseline.exists() and any(not (a.baseline/(pose+'.png')).is_file() for pose in poses):
 raise SystemExit('Approved golden baseline is incomplete; all four poses are required')
out=a.candidate.parent/'golden-comparison';out.mkdir(parents=True,exist_ok=True)
manifest={'status':'approved baseline comparison' if a.baseline.exists() else 'awaiting Charles approval; candidates are not golden references','poses':{}}
for pose in poses:
 candidate=a.candidate/(pose+'.png');new=Image.open(candidate).convert('RGBA');oldpath=a.baseline/(pose+'.png')
 canvas=Image.new('RGBA',(new.width*2,new.height+75),'#f6f2e9');d=ImageDraw.Draw(canvas)
 d.text((20,20),pose+' | approved reference' if oldpath.exists() else pose+' | approved reference pending',fill='#364035')
 if oldpath.exists():
  old=Image.open(oldpath).convert('RGBA');canvas.alpha_composite(old,(0,75))
 d.text((new.width+20,20),'candidate',fill='#364035');canvas.alpha_composite(new,(new.width,75));canvas.convert('RGB').save(out/(pose+'.png'))
 manifest['poses'][pose]={'candidateSHA256':hashlib.sha256(candidate.read_bytes()).hexdigest(),'approvedSHA256':hashlib.sha256(oldpath.read_bytes()).hexdigest() if oldpath.exists() else None}
(out/'manifest.json').write_text(json.dumps(manifest,indent=2)+'\n')
(out/'index.html').write_text('<!doctype html><meta charset="utf-8"><title>Moku golden comparison</title><style>body{background:#f6f2e9;color:#364035;font:16px system-ui;margin:24px}img{width:640px;max-width:100%;display:block}</style><h1>Four-pose golden comparison</h1><p>'+html.escape(manifest['status'])+'</p>'+''.join('<img src="'+s+'.png" alt="'+s+'">' for s in poses))
print(manifest['status'])
