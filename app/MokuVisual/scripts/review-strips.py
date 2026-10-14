#!/usr/bin/env python3
"""Decode actual MP4 output and retain every frame for critical contact-sheet review."""
import argparse, subprocess, json
from pathlib import Path
from PIL import Image, ImageDraw, ImageChops
p=argparse.ArgumentParser();p.add_argument('movie',type=Path);p.add_argument('--width',type=int,default=200);p.add_argument('--per-sheet',type=int,default=60);p.add_argument('--actor',action='store_true');a=p.parse_args()
folder=a.movie.with_name(a.movie.stem+'-decoded');folder.mkdir(exist_ok=True)
for old in folder.glob('*.png'): old.unlink()
for old in folder.glob('strip*.jpg'): old.unlink()
subprocess.run(['ffmpeg','-hide_banner','-loglevel','error','-y','-i',str(a.movie),'-fps_mode','passthrough','-enc_time_base','1/60000',str(folder/'%05d.png')],check=True)
frames=sorted(folder.glob('*.png')); cols=6
for base in range(0,len(frames),a.per_sheet):
    group=frames[base:base+a.per_sheet];first=Image.open(group[0]);h=180 if a.actor else round(first.height*a.width/first.width);rows=(len(group)+cols-1)//cols
    sheet=Image.new('RGB',(cols*a.width,rows*(h+20)),'#eee9df');d=ImageDraw.Draw(sheet)
    for i,f in enumerate(group):
        im=Image.open(f).convert('RGB'); label=str(base+i)
        if a.actor:
            channels=ImageChops.difference(im,Image.new('RGB',im.size,im.getpixel((0,0)))).split()
            mask=ImageChops.lighter(ImageChops.lighter(channels[0],channels[1]),channels[2]).point(lambda v: 255 if v>28 else 0)
            box=mask.getbbox()
            if box:
                label+=f' @ {box[0]},{box[1]}'
                im=im.crop((max(0,box[0]-12),max(0,box[1]-12),min(im.width,box[2]+12),min(im.height,box[3]+12)))
            im.thumbnail((a.width,h))
        else: im=im.resize((a.width,h))
        x=i%cols*a.width;y=i//cols*(h+20);sheet.paste(im,(x+(a.width-im.width)//2,y+20));d.text((x+4,y+3),label,fill='#303c30')
    sheet.save(folder/f'strip-{base:05d}.jpg',quality=92)
print(json.dumps({'movie':str(a.movie),'frames':len(frames),'sheets':len(list(folder.glob('strip*.jpg')))}))
