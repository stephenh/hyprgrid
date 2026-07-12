#!/usr/bin/env python3
"""Render the hyprgrid model: 4 columns (apps) x task rows, focus band sliding between tasks. -> PNG/GIF."""
import sys, math
from PIL import Image, ImageDraw, ImageFont

# ---- theme (catppuccin mocha) ----
BASE=(30,30,46); MANTLE=(24,24,37); CRUST=(17,17,27)
S0=(49,50,68); S1=(69,71,90); S2=(88,91,112); OV0=(108,112,134); OV1=(127,132,156)
TEXT=(205,214,244); SUB=(166,173,200)
MAUVE=(203,166,247); BLUE=(137,180,250); SAPPH=(116,199,236); GREEN=(166,227,161)
TEAL=(148,226,213); YELLOW=(249,226,175); PEACH=(250,179,135); RED=(243,139,168); LAV=(180,190,254)
ACCENT=MAUVE

FD="/usr/share/fonts/TTF/"
def font(w, s):
    p={"r":"JetBrainsMonoNerdFont-Regular.ttf","m":"JetBrainsMonoNerdFont-Medium.ttf","b":"JetBrainsMonoNerdFont-Bold.ttf"}[w]
    return ImageFont.truetype(FD+p, s)
F_TITLE=font("b",22); F_SUB=font("r",14); F_HEAD=font("b",15); F_TAG=font("b",30)
F_DESC=font("m",13); F_SM=font("r",11); F_TINY=font("r",9); F_KEY=font("b",13); F_MON=font("m",12)

# ---- layout ----
W,H=900,600
LX=96; TY=104; CW=176; CH=104; GX=14; GY=14
COLS=4; ROWS=4
def colx(i): return LX + i*(CW+GX)
def rowy(j): return TY + j*(CH+GY)

APPS=[("Zed",MAUVE),("Terminal",GREEN),("Browser",BLUE),("Logs",PEACH)]
TAGS=["a","b","c","d"]
DESCS={"a":"skills","b":"bug-1234","c":"refactor","d":"release"}
# occupancy: per task row, the app kind in each column (None = sparse/empty)
OCC={
 "a":["ide","term","browser","logs"],
 "b":["ide","term","browser",None],
 "c":["ide","term",None,None],
 "d":["ide",None,"browser",None],
}

def rr(d,box,r,**k): d.rounded_rectangle(box,r,**k)

def draw_dots(d,x,y):
    for i,c in enumerate([RED,YELLOW,GREEN]):
        d.ellipse([x+i*11,y,x+i*11+6,y+6],fill=c)

def monitor_icon(d,x,y,color):
    # small physical display: screen + neck + base
    rr(d,[x,y,x+18,y+12],2,outline=color,width=2)
    d.line([x+9,y+12,x+9,y+15],fill=color,width=2)
    d.line([x+3,y+16,x+15,y+16],fill=color,width=2)

def cell_ide(d,x,y,w,h):
    rr(d,[x,y,x+w,y+h],7,fill=CRUST,outline=S0,width=1)
    rr(d,[x,y,x+w,y+18],7,fill=S0)             # title strip
    d.rectangle([x,y+10,x+w,y+18],fill=S0)
    rr(d,[x+8,y+4,x+92,y+16],4,fill=S1)        # file tab
    d.text((x+14,y+10),"grid.lua",font=F_SM,fill=MAUVE,anchor="lm")
    gy=y+26
    for i in range(6):                          # code lines with syntax-ish tokens
        ly=gy+i*12
        d.text((x+6,ly),str(i+1),font=F_TINY,fill=OV0,anchor="lm")
        ox=x+20+ (8 if i in (2,3,4) else 0)
        toks=[(MAUVE,14),(TEXT,26),(GREEN,30)] if i%3==0 else \
             [(BLUE,20),(TEXT,18),(PEACH,22)] if i%3==1 else [(TEXT,22),(TEAL,34)]
        cx=ox
        for c,ww in toks:
            if cx+ww>x+w-8: break
            rr(d,[cx,ly-3,cx+ww,ly+3],2,fill=c); cx+=ww+6
    d.rectangle([x+w-14,gy+3*12-4,x+w-11,gy+3*12+4],fill=MAUVE)  # cursor

def cell_term(d,x,y,w,h):
    rr(d,[x,y,x+w,y+h],7,fill=(12,12,20),outline=S0,width=1)
    d.text((x+8,y+11),"",font=F_SM,fill=OV1,anchor="lm")
    d.text((x+22,y+11),"~/dev/hyprgrid",font=F_SM,fill=OV1,anchor="lm")
    lines=[(GREEN,"$",TEXT,"lua run.lua"),(SUB,"",SUB,"  17 passed, 0 failed"),
           (GREEN,"$",TEXT,"jj status"),(SUB,"",PEACH,"  M workspace-grid.lua"),
           (GREEN,"$",None,"")]
    for i,(pc,pr,tc,tx) in enumerate(lines):
        ly=y+30+i*13
        cx=x+8
        if pr: d.text((cx,ly),pr,font=F_SM,fill=pc,anchor="lm"); cx+=12
        if tx: d.text((cx,ly),tx,font=F_SM,fill=tc,anchor="lm")
    d.rectangle([x+20,y+30+4*13-5,x+28,y+30+4*13+4],fill=GREEN)  # block cursor

def cell_browser(d,x,y,w,h):
    rr(d,[x,y,x+w,y+h],7,fill=(23,23,36),outline=S0,width=1)
    rr(d,[x,y,x+w,y+22],7,fill=MANTLE)         # chrome
    d.rectangle([x,y+14,x+w,y+22],fill=MANTLE)
    rr(d,[x+6,y+4,x+78,y+18],4,fill=S1)        # active tab
    d.text((x+12,y+11),"Docs",font=F_SM,fill=BLUE,anchor="lm")
    rr(d,[x+84,y+5,x+w-6,y+17],6,fill=CRUST)   # url bar
    d.text((x+90,y+11),"",font=F_TINY,fill=GREEN,anchor="lm")
    d.text((x+100,y+11),"hypr.land",font=F_TINY,fill=SUB,anchor="lm")
    rr(d,[x+8,y+30,x+w-8,y+52],5,fill=S0)       # hero block
    d.text((x+16,y+41),"Workspace Grid",font=F_SM,fill=TEXT,anchor="lm")
    for i in range(3):                          # text lines
        rr(d,[x+8,y+60+i*11,x+w-8-(i*18),y+64+i*11],2,fill=S1)

def cell_logs(d,x,y,w,h):
    rr(d,[x,y,x+w,y+h],7,fill=CRUST,outline=S0,width=1)
    rows=[("12:04:01","INFO",GREEN,"agent started"),("12:04:03","INFO",GREEN,"build ok"),
          ("12:04:07","WARN",YELLOW,"retry x2"),("12:04:09","ERR ",RED,"flaky test"),
          ("12:04:11","INFO",GREEN,"green")]
    for i,(t,lv,c,msg) in enumerate(rows):
        ly=y+12+i*14
        d.text((x+8,ly),t,font=F_TINY,fill=OV0,anchor="lm")
        rr(d,[x+52,ly-5,x+52+30,ly+5],3,fill=c)
        d.text((x+55,ly),lv,font=F_TINY,fill=CRUST,anchor="lm")
        d.text((x+88,ly),msg,font=F_TINY,fill=SUB,anchor="lm")

def cell_empty(d,x,y,w,h):
    # sparse: faint outline + centered muted glyph
    for seg in range(0,2*(w+h),18):            # simple dashed border
        pass
    rr(d,[x,y,x+w,y+h],7,outline=(52,54,72),width=1)
    d.text((x+w/2,y+h/2-2),"·",font=F_TAG,fill=(60,62,84),anchor="mm")

CELL={"ide":cell_ide,"term":cell_term,"browser":cell_browser,"logs":cell_logs}

def chevron(d,cx,cy,size,down,color,alpha):
    col=color+(alpha,)
    s=size
    if down: pts=[(cx-s,cy-s*0.5),(cx,cy+s*0.5),(cx+s,cy-s*0.5)]
    else:    pts=[(cx-s,cy+s*0.5),(cx,cy-s*0.5),(cx+s,cy+s*0.5)]
    d.line(pts,fill=col,width=3,joint="curve")

def render(focus, vel):
    img=Image.new("RGBA",(W,H),BASE+(255,))
    d=ImageDraw.Draw(img,"RGBA")
    # title
    d.text((LX,26),"hyprgrid",font=F_TITLE,fill=TEXT,anchor="lm")
    d.text((LX+120,32),"each tag = a task · every monitor moves together",font=F_SUB,fill=SUB,anchor="lm")
    # monitors: columns 1-3 each live on a physical monitor; column 4 is an extra lane (no monitor)
    for i in range(3):
        x=colx(i)
        monitor_icon(d,x,50,SAPPH)
        d.text((x+26,56),f"Monitor {i+1}",font=F_MON,fill=SAPPH,anchor="lm")
    # column headers (apps)
    for i,(name,c) in enumerate(APPS):
        x=colx(i)
        d.ellipse([x,TY-22,x+9,TY-13],fill=c)
        d.text((x+16,TY-17),f"{i+1} · {name}",font=F_HEAD,fill=TEXT,anchor="lm")
    # cells (full brightness) + a small workspace-id badge on each occupied one (each is its own workspace)
    for j,tag in enumerate(TAGS):
        for i in range(COLS):
            x,y=colx(i),rowy(j); kind=OCC[tag][i]
            if kind:
                CELL[kind](d,x,y,CW,CH)
                wid=f"{i+1}{tag}"; pw=len(wid)*7+12
                rr(d,[x+CW-pw-3,y+3,x+CW-3,y+18],4,fill=CRUST+(235,),outline=S1,width=1)
                d.text((x+CW-pw/2-3,y+11),wid,font=F_SM,fill=LAV,anchor="mm")
            else:
                cell_empty(d,x,y,CW,CH)
    # dim overlay per row by distance from focus
    ov=Image.new("RGBA",(W,H),(0,0,0,0)); od=ImageDraw.Draw(ov)
    for j in range(ROWS):
        dist=abs(j-focus); bright=max(0.30,1-dist*0.85)
        a=int((1-bright)*150)
        if a>2: od.rectangle([0,rowy(j)-6,W,rowy(j)+CH+6],fill=BASE+(a,))
    img=Image.alpha_composite(img,ov); d=ImageDraw.Draw(img,"RGBA")
    # task labels (left gutter, left-aligned)
    for j,tag in enumerate(TAGS):
        dist=abs(j-focus); on=dist<0.5
        y=rowy(j)+CH/2
        d.text((14,y-9),tag,font=F_TAG,fill=(ACCENT if on else OV0),anchor="lm")
        d.text((15,y+16),DESCS[tag],font=F_DESC,fill=(TEXT if on else OV0),anchor="lm")
    # focus band outline at interpolated position (glow behind, crisp edge on top)
    fy=TY + focus*(CH+GY); box=[colx(0)-7,fy-7,colx(3)+CW+7,fy+CH+7]
    rr(d,box,11,outline=ACCENT+(55,),width=8)   # soft glow
    rr(d,box,11,outline=ACCENT+(255,),width=3)  # crisp edge
    # direction chevrons (all columns move together)
    if abs(vel)>1e-3:
        down=vel>0; a=170
        for i in range(COLS):
            cx=colx(i)+CW/2
            chevron(d,cx,fy-16 if not down else fy+CH+16,8,down,ACCENT,a)
        # gutter arrow
        chevron(d,30,fy+CH+30 if down else fy-14,10,down,ACCENT,220)
    # keycap hint
    d.text((LX,H-26),"Super+Ctrl+J",font=F_KEY,fill=GREEN,anchor="lm")
    d.text((LX+118,H-26)," ↓   /   ",font=F_SUB,fill=SUB,anchor="lm")
    d.text((LX+178,H-26),"Super+Ctrl+K",font=F_KEY,fill=GREEN,anchor="lm")
    d.text((LX+296,H-26)," ↑   move to the next / previous task",font=F_SUB,fill=SUB,anchor="lm")
    return img

if __name__=="__main__":
    mode=sys.argv[1] if len(sys.argv)>1 else "preview"
    if mode=="preview":
        render(1.0,0).convert("RGB").save(sys.argv[2] if len(sys.argv)>2 else "preview.png")
        print("wrote preview")
    else:
        # animation: sweep focus b->c->d->c->b->a and loop
        keys=[1,2,3,2,1,0]; HOLD=4; TRANS=6
        frames=[]
        def ease(t): return t*t*(3-2*t)
        for k in range(len(keys)):
            a=keys[k]; b=keys[(k+1)%len(keys)]
            for _ in range(HOLD): frames.append(render(a,0))
            for f in range(1,TRANS+1):
                t=ease(f/(TRANS+1)); frames.append(render(a+(b-a)*t, (b-a)))
        pal=[fr.convert("RGB").convert("P",palette=Image.ADAPTIVE,colors=128) for fr in frames]
        pal[0].save(sys.argv[2] if len(sys.argv)>2 else "grid.gif",save_all=True,append_images=pal[1:],
                    duration=90,loop=0,optimize=True,disposal=2)
        print(f"wrote gif, {len(frames)} frames")
