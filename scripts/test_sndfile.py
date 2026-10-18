#!/usr/bin/env python3
"""Run crafted WAV/IRCAM regressions against a chosen source-built decoder."""
import argparse
from pathlib import Path
import struct
import subprocess
import tempfile
ROOT=Path(__file__).resolve().parents[1]
def chunk(tag,data):
    return tag+struct.pack('<I',len(data))+data+(b'\0' if len(data)%2 else b'')
def main():
    parser=argparse.ArgumentParser()
    parser.add_argument('--build',type=Path,required=True,help='Output of rebuild_sndfile.py --sanitize')
    args=parser.parse_args();build=args.build.resolve()
    with tempfile.TemporaryDirectory(prefix='hermeneus-sndfile-test-') as directory:
        work=Path(directory)
        for name,label in [('short',b'X'),('long',b'L'*300)]:
            data=b'WAVE'+chunk(b'fmt ',struct.pack('<HHIIHH',1,1,16000,32000,2,16))+chunk(b'cue ',struct.pack('<I',1)+struct.pack('<II4sIII',7,0,b'data',0,0,0))+chunk(b'LIST',b'adtl'+chunk(b'labl',struct.pack('<I',7)+label))+chunk(b'data',b'\0'*320)
            (work/(name+'.wav')).write_bytes(b'RIFF'+struct.pack('<I',len(data))+data)
        (work/'misalign.wav').write_bytes(bytes.fromhex('524946462400000057415645666d7420100000005500010044ac000044ac000001000800646174610110e503'))
        subprocess.run(['/usr/bin/clang','-fsanitize=address,undefined,float-cast-overflow','-fno-sanitize-recover=all',
            '-I',str(build/'libsndfile-1.2.2/include'),str(ROOT/'tests/sndfile_security.c'),
            str(build/'build/libsndfile.dylib'),'-Wl,-rpath,'+str(build/'build'),'-o',str(work/'probe')],check=True)
        subprocess.run([str(work/'probe'),*[str(work/(name+'.wav')) for name in ('misalign','short','long')]],check=True)
        subprocess.run(['/usr/bin/clang','-fsanitize=address,undefined,float-cast-overflow','-fno-sanitize-recover=all',
            '-I',str(build/'libsndfile-1.2.2/include'),str(ROOT/'tests/sndfile_counts.c'),
            str(build/'build/libsndfile.dylib'),'-Wl,-rpath,'+str(build/'build'),'-o',str(work/'counts')],check=True)
        subprocess.run([str(work/'counts')],check=True,timeout=10)
        for endian,magic in [('<',b'\x64\xa3\x03\x00'),('>',b'\x64\xa3\x02\x00')]:
            for name,rate,channels,size in [('valid',16000.,1,1056),('nan',float('nan'),1,1056),
                    ('inf',float('inf'),1,1056),('negative',-16000.,1,1056),('zero',0.,1,1056),
                    ('int-boundary',2147483648.,1,1056),('huge',1e30,1,1056),
                    ('channels-zero',16000.,0,1056),('truncated',16000.,1,32)]:
                path=work/(name+('-le' if endian=='<' else '-be')+'.ircam')
                header=magic+struct.pack(endian+'fii',rate,channels,2)
                path.write_bytes(header+bytes(size-len(header)))
                subprocess.run([str(work/'counts'),str(path)],check=True,timeout=10)
        print('PASS: little/big endian IRCAM compatibility and 16 malformed header regressions')
if __name__=='__main__':main()
