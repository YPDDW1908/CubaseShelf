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
    report.append(row);(base/'accuracy-results.json').write_text(json.dumps(report,indent=2,allow_nan=False))
    print(name, 'PASS' if passed else 'FAIL',json.dumps(deltas),flush=True)
    # Large intermediate PCM is reproducible; preserve WAV inputs and exact logs.
    raw.unlink()

def tone(rate,seconds,db=-20,freq=1000,channels=2,phase=0):
    a=10**(db/20)*np.sin(2*np.pi*freq*np.arange(round(seconds*rate))/rate+phase)
    return np.repeat(a[:,None],channels,axis=1)
for rate in [44100,48000,88200,96000,192000]:check('calibration_'+str(rate),tone(rate,5),rate,{'integrated':(-20,0.15),'truePeak':(-20,0.3)})
check('mono_48k',tone(48000,5,channels=1),48000,{'integrated':(-23.01,0.15)})
for freq in [50,100,10000,18000]:check('frequency_'+str(freq),tone(48000,5,freq=freq),48000)
check('gating',np.concatenate([np.zeros((48000*5,2)),tone(48000,5),tone(48000,5,db=-60),np.zeros((48000*5,2))]),48000)
for name,levels,target in [('lra5',[-20,-15],5),('lra10',[-20,-30],10),('lra20',[-40,-20],20),('lra15',[-50,-35,-20,-35,-50],15)]:
    check(name,np.concatenate([tone(48000,20,db=db) for db in levels]),48000,{'range':(target,1)})
for freq,phase in [(12000,np.pi/4),(16000,np.pi/3),(20000,np.pi/6)]:check('intersample_'+str(freq),tone(48000,5,db=-6,freq=freq,phase=phase),48000)
# Broadband deterministic test with dynamics, asymmetric stereo and non-aligned tail.
rng=np.random.default_rng(41);noise=rng.standard_normal((int(13.37*44100),2))*0.03
noise[44100*4:44100*8]*=0.1;noise[:,1]*=0.7
check('dynamic_noise',noise,44100)
for i,path in enumerate(sys.argv[1:]):
    raw=fixtures/'private-input.f32le'
    subprocess.run([str(ffmpeg),'-y','-hide_banner','-loglevel','error','-i',path,'-f','f32le','-ar','48000','-ac','2',str(raw)],check=True)
    samples=np.fromfile(raw,dtype='<f4').reshape(-1,2);raw.unlink()
    check('private_mix_'+str(i+1),samples,48000)
print('RESULT',sum(r['pass'] for r in report),'/',len(report),flush=True)
