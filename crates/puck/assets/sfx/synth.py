import numpy as np, wave, sys, os, json, base64
SR=24000
out=sys.argv[1]
rng=np.random.default_rng(7)
def t(d): return np.arange(int(SR*d))/SR
def env(n,a=.003,d=.2):
    x=np.arange(n)/SR; return np.minimum(x/a,1)*np.exp(-x/d)
def pad(x,d): return np.concatenate([x,np.zeros(int(SR*d))])
def mix(*parts):
    L=max(o+len(p) for o,p in parts); y=np.zeros(L)
    for o,p in parts: y[o:o+len(p)]+=p
    return y
def at(s): return int(SR*s)
def verb(x,mix_=.18,tail=.6):
    n=at(tail); ir=rng.standard_normal(n)*np.exp(-np.arange(n)/SR/(tail/5))
    # darken the tail
    k=np.ones(12)/12; ir=np.convolve(ir,k,'same'); ir/=np.abs(ir).sum()**.5*8
    w=np.convolve(x,ir); w=np.pad(w,(0,max(0,len(x)+n-len(w))))[:len(x)+n]; return np.concatenate([x,np.zeros(n)])*(1-mix_)+w*mix_
def marimba(f,d=.5,amp=1):
    x=t(d); return amp*(np.sin(2*np.pi*f*x)*env(len(x),.002,d/3)+.25*np.sin(2*np.pi*4*f*x)*env(len(x),.001,d/14))
def droplet(f0,f1,d=.12,amp=1):
    x=t(d); f=f0*(f1/f0)**(x/d); ph=2*np.pi*np.cumsum(f)/SR
    return amp*np.sin(ph)*env(len(x),.002,d/2.5)
def croak(f=520,pulses=7,rate=55,amp=1,bright=1.0):
    # frog call = a train of glottal pulses through two formants
    d=pulses/rate+.03; x=t(d); src=np.zeros(len(x))
    for i in range(pulses):
        o=at(i/rate); w=t(.006); src[o:o+len(w)]+=np.sin(np.pi*w/.006)*(1-.4*abs(i-pulses/2)/pulses)
    y=np.zeros(len(x))
    for fc,bw,g in [(f,90,1),(f*2.3,160,.5*bright),(f*4.1,300,.2*bright)]:
        r=np.exp(-np.pi*bw/SR); th=2*np.pi*fc/SR; a1,a2=-2*r*np.cos(th),r*r
        z=np.zeros(len(x))
        for n in range(len(x)):
            z[n]=src[n]-a1*(z[n-1] if n else 0)-a2*(z[n-2] if n>1 else 0)
        y+=g*z/np.abs(z).max()
    return amp*y*env(len(x),.004,d/1.5)
def tick(f=1900,amp=1):
    x=t(.05); n=rng.standard_normal(len(x))*env(len(x),.0005,.003)
    return amp*(np.sin(2*np.pi*f*x)*env(len(x),.0008,.012)+.3*n)
def norm(y,peak=.8): 
    y=y-np.mean(y); return y/np.abs(y).max()*peak
def fade(y,ms=8):
    n=at(ms/1000); y[-n:]*=np.linspace(1,0,n); return y

S={}
# notes: E5 659, G#5 830, B5 988, E6 1319
S["wake"]=("Wake","“hey frog” heard. A tiny two-part ribbit.",
  verb(mix((0,croak(640,4,70,1)),(at(.11),croak(820,3,80,.8))),.15,.4))
S["listen_start"]=("Listening","Mic opens. A rising droplet.",verb(droplet(500,1300,.11),.2,.4))
S["listen_end"]=("Sent","Mic closes, words sent. The same droplet, falling.",verb(droplet(1200,520,.12,.9),.2,.4))
S["tick"]=("Tool call","Each command frog runs. A soft wooden tick, quiet enough to hear twenty of.",verb(tick(1900,.7),.12,.25))
S["ask"]=("Needs you","Permission request. Two soft knocks on the same note, paired with the haptic tap.",
  verb(mix((0,marimba(988,.35)),(at(.16),marimba(988,.35,.75))),.2,.6))
S["approve"]=("Approved","Slide to run completes. A quick three-note rise.",
  verb(mix((0,marimba(659,.3,.7)),(at(.06),marimba(830,.3,.8)),(at(.12),marimba(988,.5,1))),.2,.6))
S["deny"]=("Declined","You tapped ✕. One low, short note, not a scold.",verb(marimba(330,.3,.9),.15,.4))
S["done"]=("Done","Turn finished. A fifth up and a happy little croak.",
  verb(mix((0,marimba(659,.4,.8)),(at(.12),marimba(988,.6,1)),(at(.34),croak(900,3,90,.35))),.22,.8))
S["error"]=("Oops","Something failed. A low plop, like the frog slipping back under.",
  verb(mix((0,droplet(420,140,.22,1)),(at(.05),droplet(260,90,.25,.5))),.25,.6))
S["chime_other"]=("Other frog","A background conversation needs you. Same knock as ‘needs you’, a fourth lower.",
  verb(mix((0,marimba(740,.35)),(at(.16),marimba(740,.35,.75))),.2,.6))
# boot: surface bloop, bubbles, then a full ribbit
bub=[(at(.25+i*.07),droplet(700+i*260,1500+i*300,.06,.35)) for i in range(3)]
S["boot"]=("Hello","First power on. The frog surfaces: a bloop, bubbles, then a proper ribbit.",
  verb(mix((0,droplet(180,620,.3,1)),*bub,(at(.6),croak(560,6,60,1)),(at(.78),croak(700,5,70,.9))),.25,1.0))

meta=[]
for k,(name,desc,y) in S.items():
    y=fade(norm(y)); pcm=(y*32767).astype('<i2')
    p=os.path.join(out,k+".wav")
    with wave.open(p,'wb') as w: w.setnchannels(1);w.setsampwidth(2);w.setframerate(SR);w.writeframes(pcm.tobytes())
    meta.append(dict(id=k,name=name,desc=desc,ms=round(len(y)/SR*1000),kb=round(os.path.getsize(p)/1024,1),
      b64=base64.b64encode(open(p,'rb').read()).decode(),
      peaks=[round(float(np.abs(c).max()),3) for c in np.array_split(y,64)]))
json.dump(meta,open(os.path.join(out,"sfx.json"),"w"))
print([(m['id'],m['ms'],m['kb']) for m in meta])
