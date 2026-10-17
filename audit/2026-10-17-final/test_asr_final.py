import json,os,secrets,socket,subprocess,time,urllib.request,urllib.error
from pathlib import Path
root=Path('/tmp/hermeneus-qa-build');res=Path('/tmp/hermeneus-native-audit/mounted-acceptance/Hermeneus.app/Contents/Resources')
def free_port():
 with socket.socket() as s:s.bind(('127.0.0.1',0));return s.getsockname()[1]
http=free_port();ws=free_port();token=secrets.token_urlsafe(32)
env=dict(os.environ,HERMENEUS_ASR_TOKEN=token,ASR_HTTP_PORT=str(http),ASR_WS_PORT=str(ws),
 HF_HOME=str(root/'speech-cache/hf'),MODELSCOPE_CACHE=str(root/'speech-cache/modelscope'),
 HF_HUB_DISABLE_TELEMETRY='1',PYANNOTE_METRICS_ENABLED='0',ASR_DEBUG='0',
 PATH=str(res/'ffmpeg')+':/usr/bin:/bin:/usr/sbin:/sbin',DYLD_FALLBACK_LIBRARY_PATH=str(res/'ffmpeg/lib'))
with (Path('/tmp/hermeneus-native-audit')/'asr-startup.log').open('wb') as log:
 p=subprocess.Popen([str(res/'asr_server')],env=env,stdout=log,stderr=log)
 try:
  for _ in range(600):
   if p.poll() is not None:raise RuntimeError('Frozen ASR exited during model preparation')
   try:
    req=urllib.request.Request(f'http://127.0.0.1:{http}/health',headers={'Authorization':'Bearer '+token})
    with urllib.request.urlopen(req,timeout=2) as response:status=json.load(response)
    if status.get('setup_error'):raise RuntimeError(status['setup_error'])
    if status.get('ready'):
     assert status.get('chinese_streaming') is True,status
     try:urllib.request.urlopen(f'http://127.0.0.1:{http}/health',timeout=2)
     except urllib.error.HTTPError as error:assert error.code==403
     else:raise RuntimeError('Missing IPC credential was accepted')
     (Path('/tmp/hermeneus-native-audit')/'asr-startup-result.json').write_text(json.dumps({'ready':True,'chinese_streaming':True,'whisper_backend':status['whisper_backend'],'unauthorized_request_rejected':True,'private_audio_used':False},indent=2)+'\n');print('PASS: frozen ASR loaded both models, ran warmup, and enforced IPC authentication.');break
   except (urllib.error.URLError,TimeoutError):pass
   time.sleep(1)
  else:raise RuntimeError('Speech model preparation did not complete within ten minutes')
 finally:
  p.terminate()
  try:p.wait(timeout=15)
  except subprocess.TimeoutExpired:p.kill();p.wait()
