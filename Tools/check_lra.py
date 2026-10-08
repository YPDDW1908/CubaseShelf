import sys,pathlib,json
b=pathlib.Path(__file__).resolve().parent;sys.path.insert(0,str(b/'validation-deps'))
import pyloudnorm as pyln
from scipy.io import wavfile
r=json.loads((b/'accuracy-results.json').read_text())
for row in r:
 rate,a=wavfile.read(b/'signals'/(row['name']+'.wav'));m=pyln.Meter(rate)
 lra=float(m.loudness_range(a.astype('float64')))
 row['pyloudnorm_LRA']=lra
 print(row['name'],row['ours']['range'],lra,abs(row['ours']['range']-lra),flush=True)
(b/'accuracy-with-lra.json').write_text(json.dumps(r,indent=2))
