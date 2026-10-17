import json,os,subprocess,socket,time,urllib.request
from pathlib import Path
root=Path('/tmp/hermeneus-qa-build');runtime=Path(os.environ.get('HERMENEUS_TEST_RUNTIME',str(root/'staged-runtime')))
with socket.socket() as s:s.bind(('127.0.0.1',0));port=s.getsockname()[1]
base=f'http://127.0.0.1:{port}'
capability='hermeneus-test-capability-1234567890abcdef'
env=dict(os.environ,HERMENEUS_OLLAMA_TOKEN=capability,HERMENEUS_OLLAMA_PORT=str(port),OLLAMA_HOST=f'127.0.0.1:{port}',OLLAMA_MODELS=str(root/'models'),OLLAMA_NO_CLOUD='1',OLLAMA_MAX_QUEUE='8',OLLAMA_NUM_PARALLEL='1',OLLAMA_MAX_LOADED_MODELS='1')
def request(path,body=None):
 req=urllib.request.Request(base+path,data=json.dumps(body).encode() if body else None,headers={'Content-Type':'application/json','Authorization':'Bearer '+capability})
 with urllib.request.urlopen(req,timeout=180) as res:return json.load(res)
with (Path('/tmp/hermeneus-native-audit')/'ollama-test-server.log').open('wb') as log:
 p=subprocess.Popen([str(runtime/'ollama'),'serve'],env=env,stdout=log,stderr=log)
 try:
  for _ in range(40):
   if p.poll() is not None:raise RuntimeError('Patched runtime exited')
   try:version=request('/api/version');break
   except OSError:time.sleep(.25)
  else:raise RuntimeError('Server readiness timeout')
  from urllib.error import HTTPError
  for headers in [{}, {'Authorization': 'Bearer wrong'}, {'Authorization': 'Bearer '+capability, 'Origin':'https://evil.invalid'}, {'Authorization': 'Bearer '+capability, 'Origin':'null'}]:
   try: urllib.request.urlopen(urllib.request.Request(base+'/api/version',headers=headers),timeout=5)
   except HTTPError as e: assert e.code==403
   else: raise AssertionError('Unauthorized request accepted')
  models=request('/api/tags')['models'];names=[x['name'] for x in models if not x.get('remote_host') and not x['name'].endswith((':cloud','-cloud'))]
  selected=next((n for n in ['qwen2.5:3b','qwen3:4b-instruct','qwen2.5:7b'] if n in names),None)
  downloaded=False
  if not selected:
   selected='qwen2.5:3b'
   req=urllib.request.Request(base+'/api/pull',data=json.dumps({'model':selected,'stream':True}).encode(),headers={'Content-Type':'application/json','Authorization':'Bearer '+capability})
   with urllib.request.urlopen(req,timeout=600) as stream:
    for line in stream:
     item=json.loads(line)
     if item.get('error'):raise RuntimeError(item['error'])
   downloaded=True
  response=request('/api/generate',{'model':selected,'prompt':'Translate this Chinese sentence into Spanish. Output only the translation: 你好，今天我们测试语音翻译。','stream':False,'keep_alive':'30s','options':{'temperature':0,'num_predict':80}})
  import re
  logfile=Path('/tmp/hermeneus-native-audit/ollama-test-server.log').read_text()
  matches=re.findall(r'--port (\d+)',logfile)
  assert matches, 'Native listener port not found'
  native='http://127.0.0.1:'+matches[-1]
  for headers in [{}, {'Authorization':'Bearer wrong'}]:
   try: urllib.request.urlopen(urllib.request.Request(native+'/tokenize',data=b'{"content":"Hola"}',headers=dict(headers,**{'Content-Type':'application/json'})),timeout=10)
   except urllib.error.HTTPError as e: assert e.code==401
   else: raise AssertionError('Unauthenticated native tokenizer accepted')
  req=urllib.request.Request(native+'/tokenize',data=b'{"content":"Hola"}',headers={'Content-Type':'application/json','Authorization':'Bearer '+capability})
  with urllib.request.urlopen(req,timeout=10) as result: assert json.load(result).get('tokens')
  print('PASS: native llama-server tokenizer rejects absent/wrong credentials and accepts the private capability.')
  import shutil
  jobroot=Path('/tmp/hermeneus-native-audit/offline-e2e-acceptance-root');jobroot.mkdir(exist_ok=True)
  cache=jobroot/'Hermeneus Data/model-cache/onnx-diarization-v1'
  if not cache.exists():shutil.copytree('/tmp/hermeneus-native-audit/account-free-cache',cache)
  resources=runtime.parent
  batchenv=dict(env,HF_HOME='/tmp/hermeneus-qa-build/speech-cache/hf',HF_HUB_OFFLINE='1',HF_HUB_DISABLE_TELEMETRY='1',PATH=str(resources/'ffmpeg')+':/usr/bin:/bin',DYLD_FALLBACK_LIBRARY_PATH=str(resources/'ffmpeg/lib'))
  with Path('/tmp/hermeneus-native-audit/final-offline-e2e.log').open('wb') as batchlog:
   subprocess.run([str(resources/'asr_server'),'--offline-batch','--input','/tmp/hermeneus-native-audit/diarization-fixture/two-speakers.wav','--secure-root',str(jobroot),'--model',selected,'--ollama-url',base+'/api/generate','--diarization','--diarization-executable',str(resources/'offline_diarizer')],env=batchenv,stdout=batchlog,stderr=batchlog,check=True,timeout=600)
  records=[json.loads(line) for file in jobroot.glob('Hermeneus Data/jobs/*/transcript.jsonl') for line in file.read_text().splitlines() if line]
  assert len(records)>=2,records
  speakers={r.get('speaker') for r in records}
  assert len(speakers)==2,speakers
  exports=[str(p.relative_to(jobroot)) for p in jobroot.glob('Hermeneus Data/exports/**/*') if p.is_file()]
  assert any(x.endswith('.txt') for x in exports),exports
  assert all(r.get('source_text','').strip() and r.get('translation_text','').strip() for r in records), records
  Path('/tmp/hermeneus-native-audit/final-offline-e2e-result.json').write_text(json.dumps(dict(passed=True,segments=len(records),speakers=sorted(speakers),exports=exports,synthetic_audio_only=True),ensure_ascii=False,indent=2)+'\n')
  print('PASS: final mounted bundle transcribes, separates speakers, translates and exports the bilingual document from a synthetic Spanish conversation.')

  assert response.get('done') and response.get('response','').strip(),response
  result=dict(version=version,model=selected,translated_text=response['response'],done=True,model_downloaded=downloaded,private_audio_used=False)
  (Path('/tmp/hermeneus-native-audit')/'ollama-functional-test.json').write_text(json.dumps(result,ensure_ascii=False,indent=2)+'\n');print(json.dumps(result,ensure_ascii=False))
 finally:
  p.terminate()
  try:p.wait(timeout=15)
  except subprocess.TimeoutExpired:p.kill();p.wait()
