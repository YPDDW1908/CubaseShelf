from pathlib import Path
import sys,subprocess,json,re,os
base=Path(sys.argv[1]).resolve();base.mkdir(parents=True,exist_ok=True)
sys.path.insert(0,os.environ['CUBASESHELF_VALIDATION_DEPS'])
import numpy as np
import pyloudnorm as pyln
ff=Path(os.environ['CUBASESHELF_FFMPEG'])
rate=48000;t=np.arange(int(4.37*rate))/rate
rows=[]
for name,active in [('front',[0]),('center',[2]),('surround',[4]),('all',[0,1,2,3,4,5]),('lfe',[3])]:
 x=np.zeros((len(t),6),dtype=np.float32)
 for c in active:x[:,c]=.1*np.sin(2*np.pi*(1000+100*c)*t)
 raw=base/(name+'.f32le');wav=base/(name+'.wav');x.astype('<f4').tofile(raw)
 subprocess.run([str(ff),'-hide_banner','-loglevel','error','-y','-f','f32le','-ar',str(rate),'-ac','6','-channel_layout','5.1','-i',str(raw),'-c:a','pcm_f32le',str(wav)],check=True)
 ours=json.loads(subprocess.check_output([os.environ['CUBASESHELF_AUDIOCHECK'],str(wav)]))
 log=subprocess.run([str(ff),'-hide_banner','-i',str(wav),'-af','ebur128=peak=true','-f','null','-'],capture_output=True,text=True,check=True).stderr
 (base/(name+'-ffmpeg.txt')).write_text(log)
 summary=log[log.rfind('Summary:'):]
 reference=float(re.search(r'I:\s+([-\d.]+) LUFS',summary)[1])
 peak=float(re.search(r'Peak:\s+([-\d.]+) dBFS',summary)[1])
 py=float(pyln.Meter(rate).integrated_loudness(x[:,[0,1,2,4,5]].astype(float))) if name!='lfe' else None
 good=ours['layoutSupported'] and (ours['integrated'] is None if name=='lfe' else abs(ours['integrated']-reference)<=.1 and abs(ours['integrated']-py)<=.1) and abs(ours['truePeak']-peak)<=.3
 rows.append(dict(name=name,ours=ours,ffmpeg_LUFS=reference,ffmpeg_TP=peak,pyloudnorm_LUFS=py,passed=bool(good)))
 print(name,good,ours,reference,flush=True)
(base/'surround-results.json').write_text(json.dumps(rows,indent=2))
assert all(r['passed'] for r in rows)
