from pathlib import Path
import subprocess,json,shlex
src=Path('/tmp/hermeneus-native-audit/sherpa-rebuild/k2-fsa-sherpa-onnx-11afbd0');b=next((src/'build').glob('temp.*'));ort=b/'_deps/onnxruntime-src'
entries=json.loads((b/'compile_commands.json').read_text());entry=next(x for x in entries if x['file'].endswith('/offline-transducer-model.cc'))
flags=shlex.split(entry['command']);out=[];skip=False
for x in flags[1:]:
 if skip:skip=False;continue
 if x=='-o':skip=True;continue
 if x=='-c' or x==entry['file']:continue
 out.append(x)
cmd=[flags[0],*out,'-O1','-g','-fsanitize=address,undefined','-fno-omit-frame-pointer','/tmp/hermeneus-native-audit/transducer-regression.cc',str(src/'sherpa-onnx/csrc/offline-transducer-model.cc'),str(src/'sherpa-onnx/csrc/offline-transducer-greedy-search-decoder.cc'),*[str(p) for p in (b/'lib').glob('*.a')],str(ort/'lib/libonnxruntime.dylib'),'-Wl,-rpath,'+str(ort/'lib'),'-framework','Accelerate','-o','/tmp/hermeneus-native-audit/transducer-regression']
subprocess.run(cmd,cwd=entry['directory'],check=True)
subprocess.run(['/tmp/hermeneus-native-audit/transducer-regression','/tmp/hermeneus-native-audit/transducer-fixtures'],check=True)
