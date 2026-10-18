# Hermeneus v1.0.0（build 2）安全审核报告

审核日期：2026-10-17（本地时区）。本报告用于重新发布 v1.0.0。结论限定于本次受审源码、固定依赖和对应安装包，不是“零漏洞”保证。

## 1. 项目与范围

项目为 Apple Silicon/macOS 14+ 桌面应用。界面与音频管线采用 Swift/SwiftUI、Foundation、AVFoundation、ScreenCaptureKit、CoreAudio；Swift Package Manager 仅引用 5 个本地包，没有远程 Swift 锁文件。语音工作器采用 Python 3.11、Bottle、websockets、PyTorch/FunASR、faster-whisper、sherpa-onnx，以 PyInstaller 冻结。翻译运行时为 Go/Ollama 与 C/C++/Metal 原生推理组件。原生构建使用 CMake/Make，发布自动化为 GitHub Actions 与本地 Python/Shell。

直接 Python 运行时依赖 13 个；实际构建环境 163 个 distribution（包括构建/间接依赖）。Go 直接模块 33 个、间接模块 49 个，共 82 个。无 npm、Cargo、Maven、Podfile 项目，不机械运行不适用的扫描器。完整直接依赖、关键间接版本与原生版本见发布附件 `DEPENDENCIES.md`（仓库为 `docs/DEPENDENCIES_2026-10-17.md`），全部解析版本与 258 项已识别组件见 `dependencies/`。

范围包括第一方 Swift、Python、Go 通信补丁、构建/打包脚本、现用 GitHub 工作流、模型校验、许可证配套源码、本机 Git 历史与最终源码 ZIP/应用资源。此前同日逐文件审核的未变文件以 SHA-256 复核；新增、变更文件重新审阅，重点追踪输入到进程、网络、文件与原生解码器的路径。第三方大型上游仓库采用依赖公告/扫描、相关调用链与补丁审查；没有声称逐行人工复核全部第三方 C/C++/Go 源码。

**结论：本轮范围内未确认仍可利用的 Critical/High 应用漏洞。已识别且可安全修复的问题已处理。部分原生公告的更广泛影响仍为待确认，下文保留边界。**

## 2. 问题汇总

下表同时包含为本次重发累计完成的修复与本轮新发现。原生库级严重性不等于应用默认入口已可利用。

| 编号 | 类别 | 级别 | 位置（仓库相对路径） | 状态 |
| --- | --- | --- | --- | --- |
| S-01 | 代码 | High | `HermeneusApp/Packages/AudioCore/Sources/AudioCore/LocalServiceAccess.swift:8`；`HermeneusApp/App/Sources/SetupAssistant.swift:130`；`runtime/ollama/hermeneus_native_socket.go:41` | 已修复：父进程持续持有监听句柄；原生服务私有 Unix socket，无任意 TCP 回退 |
| S-02 | 代码 | Medium | `asr_server/asr_security.py:6`；`server.py:683`；`runtime/ollama/hermeneus_security.go:16` | 已修复：capability、loopback、Host/Origin 边界和重定向拒绝 |
| D-01 | 依赖 | High | 原生 `src/ima_adpcm.c:167,235,241`；`runtime/libsndfile/ima-counts-1.2.2.patch` | 已修复已知三处整数乘法；默认应用利用链待确认 |
| D-02 | 依赖 | Medium | 原生 `src/ircam.c:164`；`runtime/libsndfile/ircam-bounds-1.2.2.patch:16` | 已加固已知转换路径；公告中更广泛内存破坏说法待确认 |
| D-03 | 依赖 | Medium | `runtime/libsndfile/cue-label.patch`；`unaligned-1.2.2.patch` | 已回移并验证标签未初始化字节/终止符与非对齐访问修复 |
| D-04 | 依赖 | High | `runtime/sherpa/transducer-bounds.patch`；`scripts/record_diarizer.py` | 已修复并固定自构建 transducer 边界补丁与二进制来源 |
| C-01 | 代码 | Medium | `HermeneusApp/Packages/AudioCore/Sources/AudioCore/PrivateLogFile.swift:7`；`SetupAssistant.swift:101` | 已修复：现有目录 0700、文件 0600，拒绝符号/硬链接及非普通文件 |
| C-02 | 代码 | Medium | `scripts/vendor_sndfile.py:34,64`；`scripts/record_decoders.py:8` | 已修复：实际提取两个冻结组件中的库并核对指纹，拒绝旧组件混入 |
| C-03 | 代码 | Low | `HermeneusApp/App/Sources/OfflineToolsPrototype.swift:242`；`asr_server/secure_paths.py:14` | 已修复：私有任务目录、受限路径与原子私有输出 |
| R-01 | 代码 | Medium | `scripts/check_release_security.py:14`；`scripts/release_source.py:40` | 本轮修复：发布许可同时绑定受审源码和解码/FFmpeg/Ollama 版本配方 |
| R-02 | 代码 | Medium | `scripts/verify_release.py:18`；`scripts/publish_v1.py:45` | 本轮修复：拒绝旧/替换/额外附件与过期源码，上传草稿校验后才公开 |
| R-03 | 依赖 | Low | `runtime/ollama/orderedmap/go.mod:16`；`go.sum` | 本轮修复：补齐独立 YAML 模块校验与测试依赖；重新构建 Ollama |
| R-04 | 代码 | Medium | `README.md:5` | 本轮修复：旧仓库下载链接可能使用户获取错误/未修订版本，改为当前仓库 |
| R-05 | 代码 | Low | `.github/workflows/build_dmg.yml:182,231` | 本轮修复：使用系统磁盘映像工具，移除未固定的额外 create-dmg/Homebrew 工具链 |
| R-06 | 代码 | Low | `scripts/ollama_patches.py`；生成后的 `mlx/dynamic.go:280` | 本轮修复：Metal 4 组件要求 macOS 26.2，上游仅检查主版本；已增加小版本判断，保留 Metal 3 |
| N-01 | 依赖 | Low | `runtime/ollama/go.mod` | 建议关注：弃用 OpenPGP/旧 YAML 仅模块或测试链存在，不在实际主程序 package 清单 |
| N-02 | 依赖 | Low | `requirements.txt`；`runtime/ollama/go.mod` | 建议关注：维护阶段/低频更新依赖；没有仅凭名称相似判定仿冒包 |

## 3. 风险、利用条件与具体改动

### 本机通信与输入边界

旧协议可能先向固定端口上的未知本机进程发送内部凭据。本地其他进程抢占端口即可伪装服务。现在由应用先创建并持续保有动态监听句柄，通过标准描述符交给子进程；子进程退出不会释放父进程保有的端口。llama/MLX 使用 0700 私有目录中的 Unix socket；没有登记的目标直接拒绝连接。只向符合本次端口/地址的请求附加随机 capability，不跟随重定向、不继承本机代理与 cookie 状态。

HTTP/WS 和原生服务限制 loopback 来源、capability、Origin，HTTP/WS 进一步检查 Host/路径；输入帧、会话时长、缓存与并发有界。HTTP 媒体解析在鉴权后执行，默认上传最多 4 MiB；外部媒体的 FFmpeg 路径限制协议、时长和输出。测试包括外部播放列表不能触发网络请求。没有把这些限制当作原生库补丁的替代品。

私有目录保护其他账户，并不意味着能隔离已完全控制同一用户账户的恶意程序。应用不具备操作系统级进程沙箱的全部保护。

### 原生依赖与维护状态

- **IMA ADPCM**：回移官方 `9a829113c88a51e57c1e46473e90609e4b7df151` 与 `cdadf9a65fdc1f28da9d235eb443d5f5e57010d2`，三处帧数乘法先转换为 sf_count_t。旧库可复现 `505 * 5000000` 有符号溢出，新库正确返回 2525000000 帧。使用有限内存虚拟 I/O，不创建巨型输入。应用 HTTP 默认大小限制与离线 FFmpeg 归一化限制实际可达性，未证明默认应用攻击链。[官方合并修复](https://github.com/libsndfile/libsndfile/pull/1123)
- **IRCAM**：参考尚未合并的 `c69a058fdf70c9995ee15a3747af1d372452824d`，适配 1.2.2 并修正候选补丁将 INT_MAX 转为 float 后向上舍入的缺口。先以 double 比较范围，再转 int；校验声道、块宽和固定数据区域。旧库复现 float-cast-overflow，新库拒绝。没有把候选补丁描述成官方发布，也没有声称证明或全面排除 CVE-2025-52194 所述内存破坏。[官方讨论](https://github.com/libsndfile/libsndfile/pull/1099)
- **libsndfile `.2`** 同时保留对齐与 cue 标签补丁；外部 FLAC/Vorbis/Opus/MPEG 库关闭，压缩音频保留已有 FFmpeg 路线。完整基线源码、适配补丁、上游原补丁和许可证随应用提供。
- **SQLite** 实际为 go-sqlite3 v1.14.52 内嵌 3.53.4，已替换较旧 C 代码；不能只看 Go 扫描器判断 SQLite。[官方变更](https://sqlite.org/releaselog/3_53_4.html)
- **FFmpeg** 私有运行时与 PyAV 内嵌版本均为 8.1.2，分别核实；前者禁用网络。此前 vf_swaprect 相关公告对应视频滤镜，当前路径为音频处理，未发现调用该滤镜；仍保留上游原生层关注项。[官方安全记录](https://ffmpeg.org/security.html)
- **OpenSSL** 实测 CPython 3.5.9、cryptography 4.0.3，达到官方 2026-09-29 修复版本。[官方安全公告](https://openssl-library.org/news/vulnerabilities/)
- **ModelScope #1759** 的未合并候选涉及恶意配置进入图像/动态实例化路径；当前固定语音模型设置 trust_remote_code=False，未识别出相应图像 pipeline 调用。保留潜在供应链风险，不据“无 advisory”下安全结论。[官方候选](https://github.com/modelscope/modelscope/pull/1759)
- **go-tree-sitter #55** 的非空 options 回调句柄泄漏在本项目构建生成器依赖中识别到，主程序 package 清单不包含该模块；未发现运行时受影响调用。[上游问题](https://github.com/tree-sitter/go-tree-sitter/issues/55)
- `gopkg.in/yaml.v3` 原仓库停止维护，但仅测试链保留；运行时使用维护中的 `go.yaml.in/yaml/v3 v3.0.4`。后者 v3 仅安全维护，不应误报为完全停维。TorchAudio 2.11 进入维护阶段，官方支持后续 torch；较老 w32/float16/orderedmap 版本列为维护关注。httpx2/httpcore2 已核对官方迁移来源，未发现仿冒证据。

### 日志、输出与构建来源

默认诊断不记录转写全文；已有日志目录也收紧权限，使用目录描述符与 openat/O_NOFOLLOW，验证所有者、普通文件与单一硬链接。离线导出限制在所选根目录，任务 ID 规范化，写入采用 0600 临时文件和原子替换。

两个冻结工作器重新核对实际内嵌的唯一解码库。提取后仅移除副本 ad-hoc 签名，比较所有剩余字节的 SHA-256；来源库不修改。构建记录绑定配方、源码、补丁、库与工作器哈希；打包后另记录重签名哈希。

### 本轮发布流程修复

原发布许可只绑定 Ollama，不能充分阻止其他代码在审核后变化。本轮加入受审源码指纹与原生版本/配方绑定。成品附件采用固定集合与逐文件 SHA-256；源码 ZIP 与当前公开清单逐项一致，拒绝本地审计、日志、个人音频、环境文件与符号链接。内部构建号升为 2，公开版本仍是用户要求的 1.0.0。

`publish_v1.py` 默认仅检查。带 `--publish` 才提交受控源码、备份旧本地标签、将 v1.0.0 指向新提交并推送；不强推远程 main/tag，不覆盖已有公开 Release。先上传草稿，通过 GitHub digest 或回下载核对，再公开；失败保留草稿。临时本地 Git 仓库测试覆盖真实提交、标签备份、推送与上传校验失败与中断草稿重试行为，测试未修改实际 GitHub 仓库。

当前根 GitHub 工作流没有 pull_request_target、没有外部 PR 写权限路径，第三方 Actions 固定提交，checkout 不保留凭据。手动构建也执行安全门禁；使用 macOS 自带 hdiutil，避免额外未固定工具下载。嵌套第三方 CircleCI 文件是保留的上游材料，不是本仓库激活的 CI。

## 4. 依赖扫描与密钥检查

13 个 Python 与 33 个 Go 直接依赖逐项 Web 检索，优先核对官方、GitHub Advisory、OSV/Go 公告与 NVD；同时复用同日未变版本的完整审查证据。版本精确查询无结果不证明无漏洞。

- pip-audit：实际构建环境中 162 个可识别包未报告已知漏洞；自构建 sherpa-onnx 1.13.8+hermeneus.1 单独按来源补丁/原生验证处理，不虚报自动扫描覆盖。pip check 无破损依赖。
- govulncheck：仅剩 GO-2026-5932 的模块级提示；无受影响函数 trace，实际链接包清单无弃用 OpenPGP。没有把模块包含误当成已确认应用可利用漏洞。
- 秘密扫描：当前 168 个文件、本地全部 refs 的 125 个 Git 文件对象、两工作器 34,883 个解压条目。23 个匹配逐项核验为公开示例占位符、配置键名与 SSH 格式定界符；未确认真实 API Key、密码或私钥。`.env` 与私钥文件被忽略，没有发现已跟踪的这类敏感文件；`.env.example` 仅变量名。
- 最终附件另外校验内容清单、压缩包路径与完整性，避免扫描范围之外的文件被打包。

未确认泄露，故本轮没有擅自轮换任何凭据。如果维护者发现曾提交或泄露的真实密钥，必须到对应平台作废并重建；删代码、删 Release 或删标签不能使已泄露密钥失效。

## 5. 构建、测试与发布验收

- 38 项 Python 回归通过，包括发布审批、附件变化、额外文件、过期源码、真实临时 Git 重发与失败草稿保留。
- Swift Release 构建通过；字幕流完整性、音频路由、私有日志与真实 HTTP/WebSocket IPC 回归通过。
- 固定源码重建 Ollama 后，cmd、cmd/launch、internal/hermeneusaccess 回归通过；orderedmap 独立 `go test -mod=readonly` 通过。
- libsndfile AddressSanitizer/UndefinedBehaviorSanitizer/float-cast-overflow 下 143/143 上游测试通过；异常 WAV、cue 标签、64 位 IMA 帧数、大小端 IRCAM 正常兼容与 16 个异常头用例通过。
- 完整 Go server 上游路由测试此前有 36 项因未携带 Hermeneus 内部鉴权而失败，.4/.5 对照一致。本报告没有将其描述为全套 Go 上游测试全绿；真实鉴权路径另有测试。
- 安装包的最终启动、离线流程、签名、挂载验证以发布附件清单与本地最终验收记录为准。SHA-256 记录在 `release-manifest.json` 与 `SHA256SUMS`，避免报告自身哈希循环。

## 6. 需要决定与剩余风险

本轮未遗留要求擅自升级主版本、删除业务功能或轮换密钥的已确认漏洞。此前开发者已授权本地原生补丁路线并接受未采用 Developer ID/公证的分发限制；本次明确要求重新发布 v1.0.0，发布配置记录该范围，不将未执行的硬件测试标为通过。

1. **硬件验收**：当前为 Apple M4 本地验收，未完成第二台 macOS 14/M1、真实麦克风/会议软件端到端回传。可按明确限制发布后补测，或自行延后发布到硬件验收完成；本次命令仍由维护者执行。音频路由自动测试没有播放私人音频。
2. **原生与模型供应链**：尚未独立复现官方 MLX payload 每个传递原生组件的完整构建；扫描器也不完整覆盖所有 C/C++ 静态代码。模型必须来自可信官方来源，勿以此报告为理由加载任意陌生模型/可执行配置。
3. **自维护补丁**：libsndfile 候选硬化与 sherpa 补丁需跟踪上游，后续优先迁移正式修复；IRCAM 更广泛公告影响仍为待确认。
4. **发行认证**：应用仅 ad-hoc 签名，无 Apple Developer ID/公证；本地手动构建不宣称具有 GitHub Actions 构建证明或 SLSA 等级。校验和保证核对一致性，不替代可信发布者身份。
5. **安全结论时效**：新公告、依赖变化、源码变化或重新构建均应重新检查。发布脚本遇到源码或附件不一致会拒绝执行。


### 最终成品结果

本轮全新 build 2 安装包已完成启动/资源门禁与 deep/strict 签名检查。包内实际组件通过 qwen2.5:3b 推理、原生 Unix socket 无凭据/错误凭据拒绝，以及合成对话的完整离线转写、双人分离、翻译和 TXT 导出：7 段转写、2 位说话人，未使用私人音频、未下载新模型。只读挂载后，95 个普通文件与已签名的受测应用逐项一致，同时核对内部符号链接；最终构建号确认为 2。原生资源补扫未检出所设规则下的密钥材料。


### 最低系统与可选原生变体

逐一检查应用与冻结组件中 510 个 Mach-O 映像的最低系统版本。4 个 `mlx_metal_v4` 动态库要求 macOS 26.2，其余未高于声明的 macOS 14。上游默认选择器只检查主版本 26，可能在 26.0/26.1 上选择不兼容库；本轮 `.6` 修订增加主/小版本检查，失败或低于 26.2 时跳过 Metal 4，保留 Metal 3。该检查不提高应用的 macOS 14 最低要求。14 组版本边界与 Metal 3 保留测试用于验证判断，不等于在所有对应系统上实机运行。

最终重新验收使用 Ollama `0.40.6-hermeneus.6`：38 项 Python 回归、MLX 14 组版本边界与 Metal 3 保留测试、Go 启动/鉴权测试通过；.6 包内完整离线流程再次得到 7 段、2 位说话人、双语导出。新桌面可执行文件与新 Ollama 的最低系统均为 macOS 14.0，其余原生资源与已检查的版本逐字节一致。
