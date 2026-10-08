import sys,pathlib,json,subprocess,math
b=pathlib.Path(__file__).resolve().parent;sys.path.insert(0,str(b/'validation-deps'))
import numpy as np
import pyloudnorm as pyln
from scipy.io import wavfile
from scipy.signal import firwin,resample_poly
rows=json.loads((b/'accuracy-with-lra.json').read_text())+json.loads((b/'standards-results.json').read_text())
fir=firwin(16*64+1,1/16,window=('kaiser',10))
def reference_peak(x):
    peak=0.
    for c in range(x.shape[1]):
        for start in range(0,len(x),65536):
            end=min(len(x),start+65536);lo=max(0,start-64);hi=min(len(x),end+64)
            expanded=resample_poly(x[lo:hi,c].astype('float64'),16,1,window=fir)
            usable=expanded[(start-lo)*16:(end-lo)*16]
            peak=max(peak,float(np.abs(usable).max()))
    return 20*np.log10(peak)
results=[]
for row in rows:
    name=row['name'];rate,x=wavfile.read(b/'signals'/(name+'.wav'))
    if x.ndim==1:x=x[:,None]
    raw=b/'signals'/'recheck.f32le';x.astype('<f4').tofile(raw)
    row['ours']=json.loads(subprocess.check_output([str(b/'MeterCheck'),str(raw),str(rate),str(x.shape[1])]))
    raw.unlink()
    row['scipy_16x_truePeak']=float(reference_peak(x))
    if 'pyloudnorm_LRA' not in row:row['pyloudnorm_LRA']=float(pyln.Meter(rate).loudness_range(x.astype('float64')))
    m=row['ours'];diff={'LUFS_FFmpeg':abs(m['integrated']-row['ffmpeg']['integrated']),'LUFS_pyloudnorm':abs(m['integrated']-row['pyloudnorm_LUFS']),'LRA_pyloudnorm':abs(m['range']-row['pyloudnorm_LRA']),'TP_SciPy16x':abs(m['truePeak']-row['scipy_16x_truePeak'])}
    row['reference_differences']=diff
    row['FFmpeg_LRA_difference']=abs(m['range']-row['ffmpeg']['range'])
    row['FFmpeg_TP_difference']=abs(m['truePeak']-row['ffmpeg']['truePeak'])
    row['pass']=diff['LUFS_FFmpeg']<=.1 and diff['LUFS_pyloudnorm']<=.1 and diff['LRA_pyloudnorm']<=1 and diff['TP_SciPy16x']<=.3
    if name.startswith('ebu_I'):
        expected=-33 if name=='ebu_I2' else -23
        row['standard_expected']={'integrated':expected,'tolerance':.1};row['pass'] &= abs(m['integrated']-expected)<=.1
    if name.startswith('ebu_TP'):
        expected=3 if name=='ebu_TP19' else -6
        row['standard_expected']={'truePeak':expected,'lower_tolerance':-.4,'upper_tolerance':.2};row['pass'] &= expected-.4<=m['truePeak']<=expected+.2
    for key in ['absolute_differences']:row.pop(key,None)
    results.append(row);(b/'final-accuracy.json').write_text(json.dumps(results,indent=2))
    print(name,'PASS' if row['pass'] else 'FAIL',json.dumps(diff),flush=True)
print('FINAL',sum(r['pass'] for r in results),'/',len(results),flush=True)
