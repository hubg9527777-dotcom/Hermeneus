"""Pinned native-listener changes for the reviewed Ollama source layout."""
import hashlib
from pathlib import Path
import shutil


def native_patch_digest(root):
    files = [root/'runtime/ollama/hermeneus_access.go', root/'scripts/ollama_patches.py']
    digest = hashlib.sha256()
    for path in files:
        digest.update(str(path.relative_to(root)).encode()+b'\0'+path.read_bytes())
    return digest.hexdigest()


def apply_native_patches(source, root):
    destination = source/'internal/hermeneusaccess';destination.mkdir(parents=True)
    for name in ['hermeneus_access.go','hermeneus_access_test.go']:
        shutil.copy2(root/'runtime/ollama'/name,destination/name)
    def replace(name, before, after):
        path=source/name;content=path.read_text()
        if content.count(before)!=1:raise ValueError('Unrecognized native source anchor: '+name)
        path.write_text(content.replace(before,after))
    for name in ['llm/llama_server.go','mlxrunner/client.go','mlxrunner/runner.go']:
        replace(name,'import (','import (\n "github.com/ollama/ollama/internal/hermeneusaccess"')
    replace('llm/llama_server.go',
        'return &http.Client{\n\t\tTransport: &http.Transport{\n\t\t\tDisableKeepAlives: true,\n\t\t\tProxy:             nil,\n\t\t},\n\t}',
        'return hermeneusaccess.NewClient(true)')
    replace('llm/llama_server.go',
        'SetupLlamaServerCommandEnv(cmd, exe, launch.gpuLibs, launch.extraEnvsForStart())',
        'SetupLlamaServerCommandEnv(cmd, exe, launch.gpuLibs, launch.extraEnvsForStart())\n\tcmd.Env = append(cmd.Env, "LLAMA_API_KEY=" + os.Getenv("HERMENEUS_OLLAMA_TOKEN"))')
    replace('mlxrunner/client.go','client:            http.DefaultClient,','client:            hermeneusaccess.NewClient(false),')
    replace('mlxrunner/runner.go','http.ListenAndServe(net.JoinHostPort(host, port), mux)',
        'http.ListenAndServe(net.JoinHostPort(host, port), hermeneusaccess.Protect(mux))')
