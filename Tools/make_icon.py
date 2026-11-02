"""Generates the needle icon: a backlit analog VU meter on a walnut faceplate, with an HDMI port as its maker's badge.
It is one of the icons in Resources/Icons; Tools/set_icon.py makes one of them the app icon.

Usage:  python3 Tools/make_icon.py                                   writes Resources/Icons/needle.png (1024 px)
        python3 Tools/make_icon.py --png out.png 2048                one PNG at any size
Needs:  pip install pillow numpy   (macOS: uses the Futura font)
"""
import sys,math
import numpy as np
from PIL import Image,ImageDraw,ImageFilter,ImageFont
PNG=sys.argv[2] if len(sys.argv)>2 and sys.argv[1]=="--png" else "Resources/Icons/needle.png"
N=int(sys.argv[3]) if len(sys.argv)>3 else 1024; SS=2; M=N*SS
K=M/1024          # sizes below are in 1024 px units
I=lambda v:int(round(v*K))
INK=(26,18,8,255); RED=(232,69,44,255)
FUTURA="/System/Library/Fonts/Supplemental/Futura.ttc"
# Walnut: a dark vertical gradient with faint grain lines.
y=np.mgrid[0:M,0:M][0].astype(np.float32)/M
wood=np.array([28,22,14],np.float32)*(1-y[...,None])+np.array([16,12,7],np.float32)*y[...,None]
img=Image.fromarray(wood.astype(np.uint8)).convert("RGBA")
grain=Image.new("RGBA",(M,M),(0,0,0,0)); gd=ImageDraw.Draw(grain)
for x in range(0,M,I(18)): gd.line([(x+I(3)*math.sin(x*0.013),0),(x,M)],fill=(255,255,255,8),width=max(1,I(2)))
img=Image.alpha_composite(img,grain)
# The meter window: glow, backlit face (bright at the bottom center), bezel.
wx0,wy0,wx1,wy1=I(130),I(190),I(894),I(834); rad=I(80)
glow=Image.new("RGBA",(M,M),(0,0,0,0)); ImageDraw.Draw(glow).rounded_rectangle([wx0,wy0,wx1,wy1],radius=rad,fill=(255,159,28,150))
img=Image.alpha_composite(img,glow.filter(ImageFilter.GaussianBlur(I(40))))
yy,xx=np.mgrid[0:M,0:M].astype(np.float32)
d=np.sqrt(((xx-M*0.5)/(M*0.55))**2+((yy-wy1)/(M*0.75))**2)
t=np.clip(d,0,1)[...,None]
c0,c1,c2=np.array([255,214,128]),np.array([255,159,28]),np.array([170,90,8])
face=np.where(t<0.55,c0*(1-t/0.55)+c1*(t/0.55),c1*(1-(t-0.55)/0.45)+c2*((t-0.55)/0.45))
faceimg=Image.fromarray(np.clip(face,0,255).astype(np.uint8)).convert("RGBA")
mask=Image.new("L",(M,M),0); ImageDraw.Draw(mask).rounded_rectangle([wx0,wy0,wx1,wy1],radius=rad,fill=255)
img.paste(faceimg,(0,0),mask)
dr=ImageDraw.Draw(img)
# Scale: an arc from -20 to +3 VU with ticks, the red zone past 0 VU, Futura numbers, "VU".
px,py,Rr=M//2,I(790),I(350)
def pt(deg,r): a=math.radians(deg); return (px+math.sin(a)*r, py-math.cos(a)*r)
def arc(a0,a1,r,col,w):
    pts=[pt(a0+(a1-a0)*i/80,r) for i in range(81)]; dr.line(pts,fill=col,width=w,joint="curve")
LO,HI=-45,45; RZ=LO+(HI-LO)*20/23
arc(LO,RZ,Rr,INK,I(7)); arc(RZ,HI,Rr,RED,I(16))
for i in range(13):
    a=LO+(HI-LO)*i/12; major=i%3==0
    dr.line([pt(a,Rr),pt(a,Rr+I(40 if major else 22))],fill=RED if a>RZ else INK,width=I(6 if major else 4))
num=ImageFont.truetype(FUTURA,I(44),index=0)
for label,vu in [("-20",-20),("-10",-10),("-5",-5),("0",0),("+3",3)]:
    a=LO+(HI-LO)*(vu+20)/23; x,yv=pt(a,Rr+I(78))
    dr.text((x,yv),label,font=num,fill=RED if vu>0 else INK,anchor="mm")
vu=ImageFont.truetype(FUTURA,I(96),index=0)
dr.text((px,I(640)),"VU",font=vu,fill=INK,anchor="mm")
# The needle, swung into the music (about -3 VU), with a soft shadow, and its pivot cap.
na=LO+(HI-LO)*17/23
sh=Image.new("RGBA",(M,M),(0,0,0,0)); sd=ImageDraw.Draw(sh)
sd.line([(px+I(10),py+I(8)),(lambda p:(p[0]+I(10),p[1]+I(8)))(pt(na,Rr+I(30)))],fill=(80,40,0,120),width=I(12))
img=Image.alpha_composite(img,sh.filter(ImageFilter.GaussianBlur(I(8)))); dr=ImageDraw.Draw(img)
dr.line([(px,py),pt(na,Rr+I(30))],fill=INK,width=I(11))
cap=I(46); dr.ellipse([px-cap,py-cap,px+cap,py+cap],fill=(42,30,16,255),outline=INK,width=I(6))
# The maker's badge: a small HDMI port outline.
bw,bt=I(80),I(56); bx,by=I(250),I(750)
dr.polygon([(bx-bw/2,by),(bx+bw/2,by),(bx+bt/2,by+I(22)),(bx-bt/2,by+I(22))],outline=INK,width=I(6))
# Bezel on top of the face, with a thin highlight.
dr.rounded_rectangle([wx0,wy0,wx1,wy1],radius=rad,outline=(58,46,30,255),width=I(22))
dr.rounded_rectangle([wx0+I(11),wy0+I(11),wx1-I(11),wy1-I(11)],radius=rad-I(11),outline=(244,233,212,24),width=I(3))
img=img.resize((N,N),Image.LANCZOS)
pad=round(100*N/1024); rr=round(185*N/1024)
m2=Image.new("L",(N,N),0); ImageDraw.Draw(m2).rounded_rectangle([pad,pad,N-pad,N-pad],radius=rr,fill=255)
canvas=Image.new("RGBA",(N,N),(0,0,0,0)); canvas.paste(img.resize((N-2*pad,N-2*pad),Image.LANCZOS),(pad,pad))
out=Image.new("RGBA",(N,N),(0,0,0,0)); out.paste(canvas,(0,0),m2)
shadow=Image.new("RGBA",(N,N),(0,0,0,0)); ImageDraw.Draw(shadow).rounded_rectangle([pad,pad+round(14*N/1024),N-pad,N-pad+round(14*N/1024)],radius=rr,fill=(0,0,0,110))
final=Image.alpha_composite(shadow.filter(ImageFilter.GaussianBlur(16*N/1024)),out)
final.save(PNG); print("png ok")
