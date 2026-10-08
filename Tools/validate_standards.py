import sys, pathlib, json, subprocess, re, math
base=pathlib.Path(__file__).resolve().parent
sys.path.insert(0,str(base/'validation-deps'))
import numpy as np
import pyloudnorm as pyln
from scipy.io import wavfile
ffmpeg=next((base/'validation-deps/imageio_ffmpeg/binaries').glob('ffmpeg-macos-*'))
fixtures=base/'signals';fixtures.mkdir(exist_ok=True)
report=[]
def check(name,data,rate,expected=None):
    data=np.asarray(data,dtype=np.float32)
    if data.ndim==1:data=data[:,None]
    raw=fixtures/(name+'.f32le');wav=fixtures/(name+'.wav')
    data.astype('<f4').tofile(raw);wavfile.write(wav,rate,data)
    own=json.loads(subprocess.check_output([str(base/'MeterCheck'),str(raw),str(rate),str(data.shape[1])]))
    ff=subprocess.run([str(ffmpeg),'-hide_banner','-nostdin','-i',str(wav),'-af','ebur128=peak=true','-f','null','-'],capture_output=True,text=True,check=True).stderr
    (fixtures/(name+'-ffmpeg.txt')).write_text(ff)
    summary=ff.rsplit('Summary:',1)[-1]
    def value(pattern):
        m=re.search(pattern,summary);return float(m.group(1)) if m else None
    reference={'integrated':value(r'I:\s+([-\d.]+) LUFS'),'range':value(r'LRA:\s+([-\d.]+) LU'),'truePeak':value(r'Peak:\s+([-\d.]+) dBFS')}
    independent=float(pyln.Meter(rate).integrated_loudness(data.astype(np.float64)))
    if not math.isfinite(independent):independent=None
    deltas={k:abs(own[k]-v) for k,v in reference.items() if own[k] is not None and v is not None}
    if independent is not None and own['integrated'] is not None:deltas['pyloudnorm']=abs(own['integrated']-independent)
    limits={'integrated':0.1,'range':1.0,'truePeak':0.3,'pyloudnorm':0.1}
    passed=all(d<=limits[k] for k,d in deltas.items())
    if expected:
        passed=passed and all(own[k] is not None and abs(own[k]-v)<=t for k,(v,t) in expected.items())
    row={'name':name,'rate':rate,'channels':data.shape[1],'seconds':len(data)/rate,'ours':own,'ffmpeg':reference,'pyloudnorm_LUFS':independent,'absolute_differences':deltas,'pass':passed}
    report.append(row);(base/'standards-results.json').write_text(json.dumps(report,indent=2,allow_nan=False))
    print(name, 'PASS' if passed else 'FAIL',json.dumps(deltas),flush=True)
    # Large intermediate PCM is reproducible; preserve WAV inputs and exact logs.
    raw.unlink()

def tone(rate,seconds,db=-20,freq=1000,channels=2,phase=0):
    a=10**(db/20)*np.sin(2*np.pi*freq*np.arange(round(seconds*rate))/rate+phase)
    return np.repeat(a[:,None],channels,axis=1)
# Synthesis from public EBU Tech 3341 table; not the downloaded official files.
for name,segments in [('ebu_I1',[(20,-23)]),('ebu_I2',[(20,-33)]),('ebu_I3',[(10,-36),(60,-23),(10,-36)]),('ebu_I4',[(10,-72),(10,-36),(60,-23),(10,-36),(10,-72)]),('ebu_I5',[(20,-26),(20.1,-20),(20,-26)])]:
    data=np.concatenate([tone(48000,t,db=db) for t,db in segments])
    check(name,data,48000,{'integrated':(-33 if name=='ebu_I2' else -23,0.1)})
for number,divisor,phase,amplitude,expected in [(15,4,0,.5,-6),(16,4,45,.5,-6),(17,6,60,.5,-6),(18,8,67.5,.5,-6),(19,4,45,1.41,3)]:
    signal=tone(48000,5,db=20*np.log10(amplitude),freq=48000/divisor,phase=phase*np.pi/180)
    fade=np.linspace(0,1,480);signal[:480]*=fade[:,None];signal[-480:]*=fade[::-1,None]
    check('ebu_TP'+str(number),signal,48000,{'truePeak':(expected,0.4)})
print('STANDARDS RESULTS SAVED',flush=True)
