"""Pinned native-listener changes for the reviewed Ollama source layout."""
import hashlib
from pathlib import Path
import shutil


def native_patch_digest(root):
    files = [root/'runtime/ollama/hermeneus_access.go', root/'scripts/ollama_patches.py',
             root/'runtime/ollama/hermeneus_listener.go', root/'runtime/ollama/hermeneus_native_socket.go', root/'runtime/ollama/hermeneus_mlx_version_test.go']
    files += sorted(path for path in (root/'runtime/ollama/orderedmap').rglob('*') if path.is_file())
    digest = hashlib.sha256()
    for path in files:
        digest.update(str(path.relative_to(root)).encode()+b'\0'+path.read_bytes())
    return digest.hexdigest()


def apply_native_patches(source, root):
    shutil.copytree(root/'runtime/ollama/orderedmap', source/'internal/hermeneusorderedmap')
    # Keep launch configuration on the maintained YAML v3 API.
    launch = source / 'cmd/launch'
    for path in launch.glob('*.go'):
        content = path.read_text()
        if '"gopkg.in/yaml.v3"' in content:
            path.write_text(content.replace('"gopkg.in/yaml.v3"', '"go.yaml.in/yaml/v3"'))
    destination = source/'internal/hermeneusaccess';destination.mkdir(parents=True)
    for name in ['hermeneus_access.go','hermeneus_access_test.go','hermeneus_native_socket.go','hermeneus_native_socket_test.go']:
        shutil.copy2(root/'runtime/ollama'/name,destination/name)
    def replace(name, before, after):
        path=source/name;content=path.read_text()
        if content.count(before)!=1:raise ValueError('Unrecognized native source anchor: '+name)
        path.write_text(content.replace(before,after))
    def replace_between(name, first, last, after):
        path=source/name;content=path.read_text()
        if content.count(first)!=1 or content.count(last)!=1:raise ValueError('Unrecognized native source block: '+name)
        start=content.index(first);end=content.index(last,start)
        path.write_text(content[:start]+after+content[end:])
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
        'hermeneusaccess.ServeNativeUnix(mux)')
    replace_between('llm/llama_server.go', '\t// Allocate a port\n', '\n\t// Build CLI flags',
        '\tendpoint, err := hermeneusaccess.NewNativeEndpoint()\n\tif err != nil { return nil, 0, err }\n\tport = endpoint.Port\n\tdefer func() { if err != nil { hermeneusaccess.ReleaseNativeEndpoint(port) } }()\n')
    replace('llm/llama_server.go', '\t\t"--host", "127.0.0.1",', '\t\t"--host", endpoint.Path,')
    replace('llm/llama_server.go', '\t\terr := cmd.Wait()\n\t\ts.doneErr = err', '\t\terr := cmd.Wait()\n\t\thermeneusaccess.ReleaseNativeEndpoint(s.port)\n\t\ts.doneErr = err')
    replace('llm/llama_server.go', '\t"net"\n', '')
    replace_between('mlxrunner/client.go','\t// Find a free port\n','\n\t// Get the current executable path',
        '\tendpoint, err := hermeneusaccess.NewNativeEndpoint()\n\tif err != nil { return nil, err }\n\tport := endpoint.Port\n\tc.port = port\n\tkeepEndpoint := false\n\tdefer func() { if !keepEndpoint { hermeneusaccess.ReleaseNativeEndpoint(port) } }()\n')
    replace('mlxrunner/client.go', '\tcmd.Env = os.Environ()', '\tcmd.Env = append(os.Environ(), "HERMENEUS_NATIVE_SOCKET="+endpoint.Path)')
    replace('mlxrunner/client.go', '\tc.cmd = cmd', '\tc.cmd = cmd\n\tkeepEndpoint = true')
    replace('mlxrunner/client.go', '\t\tc.doneErr = cmd.Wait()', '\t\tc.doneErr = cmd.Wait()\n\t\thermeneusaccess.ReleaseNativeEndpoint(port)')
    replace('mlxrunner/client.go', '\t"math/rand"\n\t"net"\n', '')
    replace('mlxrunner/runner.go', '\t"net"\n', '')

    replace('mlx/dynamic.go', 'metalVer >= 4 && macOSMajorVersion() < 26',
        'metalVer >= 4 && !macOSVersionAtLeast(26, 2)')
    replace('mlx/dynamic.go', '// Metal 4.x requires macOS 26+',
        '// Bundled Metal 4.x libraries require macOS 26.2+')
    darwin = source / 'mlx/dynamic_darwin.go'
    expected = """func macOSMajorVersion() int {
	ver, err := syscall.Sysctl("kern.osproductversion")
	if err != nil {
		return 0
	}
	parts := strings.SplitN(ver, ".", 2)
	major, _ := strconv.Atoi(parts[0])
	return major
}"""
    replace('mlx/dynamic_darwin.go', expected, """func macOSVersionAtLeast(major, minor int) bool {
	ver, err := syscall.Sysctl("kern.osproductversion")
	return err == nil && hermeneusVersionAtLeast(ver, major, minor)
}

func hermeneusVersionAtLeast(version string, minimumMajor, minimumMinor int) bool {
	parts := strings.Split(version, ".")
	major, err := strconv.Atoi(parts[0])
	if err != nil || major < 0 { return false }
	minor := 0
	if len(parts) > 1 {
		minor, err = strconv.Atoi(parts[1])
		if err != nil || minor < 0 { return false }
	}
	return major > minimumMajor || (major == minimumMajor && minor >= minimumMinor)
}""")
    replace('mlx/dynamic_other.go', 'func macOSMajorVersion() int { return 0 }',
        'func macOSVersionAtLeast(major, minor int) bool { return false }')
    shutil.copy2(root/'runtime/ollama/hermeneus_mlx_version_test.go', source/'mlx/hermeneus_version_test.go')
