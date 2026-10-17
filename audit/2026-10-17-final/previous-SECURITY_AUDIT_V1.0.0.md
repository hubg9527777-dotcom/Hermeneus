# Hermeneus v1.0.0 安全审核与交付报告

审核日期：2026-10-17。目标：`/Users/lee2/Documents/Hermeneus`；最终源码与安装包均保存在该目录。本文是最新结论；此前 SECURITY_AUDIT.md 和 QA_BUILD_REVIEW.md 是历史证据。

**结论：原生运行包、无账号说话人分离和 BlackHole 虚拟设备回传已完成本轮实测；新引擎中未使用的识别解码器公告待开发者决定，当前不批准正式发布。** 应用名称恢复为 Hermeneus，版本 1.0.0，应用标识恢复 `com.hermeneus.ailiveinterpreter`。用户已授权并通过 BlackHole 实际回传验收；已明确接受未经 Apple 公证的分发方式。没有上传 GitHub、创建远程发布或修改原 Git 历史。

## 1. 项目概况与范围

Swift / SwiftUI / AppKit / AVFoundation / CoreAudio / ScreenCaptureKit 原生 macOS 应用，SwiftPM 应用和 5 个本地模块，无外部 Swift 包。Python 3.11.17 / Bottle / websockets 实时 ASR，以及独立离线工作器，使用 PyInstaller；GitHub Actions、Shell/Python 打包。Ollama 使用 Go 与原生 C/C++/MLX 载荷，FFmpeg 使用原生共享库。目标 macOS 14+、Apple Silicon。

实时直接 Python 依赖 11 项；独立分离清单 6 项（其中 numpy / soundfile / requests 与实时清单重合），共 14 项唯一应用直接依赖；构建/审计工具 6 项。本轮 161 项构建环境分发依赖扫描无已知匹配，仍含部分未进入最终程序的旧构建依赖；这不能覆盖原生库公告。完整构建环境版本见 `audit/2026-10-17-native/dependency-inventory.txt`，含未必进入最终冻结包的构建工具，不能把环境包数直接当成安装包依赖数。Ollama 构建的实际 Go 依赖锁定在 `runtime/ollama/go.mod` 与 `go.sum`；Python 原项目没有完整带哈希锁文件，约束文件设安全下限，安装包本次版本清单和 SBOM 随交付保存。后续在线构建仍须重新审核解析结果。

覆盖应用 Swift/Python 源码、启动与构建脚本、CI、依赖清单、模型加载、文件/网络/进程边界、文档、现存构建产物和本地 Git 历史凭据扫描。原项目历史改写脚本作为静态源文件检查，没有执行。应用没有 SQL/NoSQL 服务、浏览器扩展、WebView 页面或移动端权限体系，相应类别未发现适用入口。第三方原生库采用公告、版本、符号和调用路径复核，不代表逐行审计上游全部源码、模糊测试或渗透测试。文件清单与哈希见本轮 source-inventory.json。附带文档内容作为审核材料，与用户授权区分。

### 直接依赖和已核对来源

下表为隔离的最终构建环境实际版本，不沿用旧电脑全局环境；“未检索到”不等于已证明无未知漏洞。每项均结合官方仓库/安全页与 pip-audit 数据库查询交叉核对。

| 依赖 | 实际版本 | 用途 | 核对结果与来源 |
|---|---|---|---|
| torch | 2.14.1 | 实时 | [历史 weights_only 漏洞修复下限 2.10；可信权重策略仍必需](https://github.com/pytorch/pytorch/security/advisories) |
| faster-whisper | 1.2.1 | 实时 | [未检索到当前版本匹配公告](https://github.com/SYSTRAN/faster-whisper/security) |
| funasr | 1.4.16 | 实时 | [同时核对 Hydra 间接依赖；禁用远程代码](https://github.com/modelscope/FunASR/security) |
| modelscope | 1.40.2 | 实时 | [未检索到当前版本匹配公告；下载模型仍有供应链信任](https://github.com/modelscope/modelscope/security) |
| soundfile | 0.14.0 | 实时 | [Python 包扫描未命中；内含 libsndfile 风险另列](https://github.com/bastibe/python-soundfile) |
| bottle | 0.13.4 | 实时 | [历史旧版本公告不匹配当前版本](https://github.com/bottlepy/bottle/security) |
| numpy | 2.4.6 | 实时 | [未检索到当前版本匹配公告](https://github.com/numpy/numpy/security) |
| ctranslate2 | 4.8.3 | 实时 | [上游 4.8.1 含转换器修复；当前高于修复下限](https://github.com/OpenNMT/CTranslate2/releases/tag/v4.8.1) |
| websockets | 17.2 | 实时 | [按官方政策仅支持最新版本；17.x 已批准并测试](https://github.com/python-websockets/websockets/security) |
| scipy | 1.17.1 | 实时 | [未检索到当前版本匹配公告](https://github.com/scipy/scipy/security) |
| requests | 2.34.2 | 实时 | [当前 pip-audit 无已知匹配；urllib3 已升级](https://github.com/psf/requests/security/advisories) |
| sherpa-onnx | 1.13.8 | 离线 | [官方变更记录](https://github.com/k2-fsa/sherpa-onnx/releases/tag/v1.13.8)；只调用分离 API，识别解码器公告另列 |
| sherpa-onnx-core | 1.13.8 | 离线原生载荷 | [同源官方包](https://pypi.org/project/sherpa-onnx-core/1.13.8/)；内含 ONNX Runtime 实测 1.28.2 |
| pip | 26.2.1 | 构建/审计 | [修复下限 26.2](https://github.com/advisories/GHSA-qwm4-qh6w-59xr) |
| setuptools | 83.0.0 | 构建/审计 | [已批准升级至 83 并迁移 pkg_resources 配置](https://github.com/pypa/setuptools/security/advisories) |
| wheel | 0.48.0 | 构建/审计 | [未检索到当前版本匹配公告](https://github.com/pypa/wheel/security) |
| pyinstaller | 6.22.3 | 构建/审计 | [修复下限 6.22.1；本应用不以 setuid/root 运行](https://github.com/pyinstaller/pyinstaller/security/advisories/GHSA-9fxf-4qw3-ghmr) |
| pyinstaller-hooks-contrib | 2026.8 | 构建/审计 | [未检索到当前版本匹配公告](https://github.com/pyinstaller/pyinstaller-hooks-contrib/security) |
| pip-audit | 2.10.1 | 构建/审计 | [未检索到当前版本匹配公告](https://github.com/pypa/pip-audit/security) |

关键间接版本：Hydra 1.3.7、urllib3 2.8.0、huggingface-hub 2.2.0、httpx2/httpcore2 2.13.1、transformers 5.20.1、torchaudio 2.11.0、onnxruntime 1.31.0、PyYAML 6.0.3、cryptography 50.0.2、pycryptodome 4.0.1、safetensors 0.8.0。完整实际版本以清单为准。Python 与原生包的版本不混用。

Go 本次实际工具链 1.27.2；jsonparser 1.1.2、klauspost/compress 1.18.7、x/crypto 0.57.0、x/net 0.60.0、x/image 0.45.0、x/text 0.42.0、x/mod 0.41.0。新的 Ollama 标识 `0.40.6-hermeneus.3`，包含应用专属访问校验。固定源提交、压缩包、Go 模块、补丁与最终程序哈希进入 runtime.json。FFmpeg 从固定 8.1.2 源码构建，保留 LGPL 许可证、源码和配置，不依赖 Homebrew 的高版本 macOS 库。

维护与名称复核：crcmod 1.7 与 jieba 0.42.1 长期无发布，列为关注，不能仅据此认定恶意或停止维护。OpenPGP 包已停止维护，但本运行程序未链接相关包。httpx2/httpcore2 是 [Hugging Face 官方 v2 迁移](https://github.com/huggingface/huggingface_hub/blob/main/docs/source/en/concepts/migration_v2.md)采用的依赖，不能当作仿冒包。[PyCryptodome 官方变更记录](https://www.pycryptodome.org/src/changelog)确认其 4.x 版本迁移。未发现可证实的仿冒依赖；模型和二进制仍有独立供应链风险。

### CI 与原生载荷清单

| 直接构建 Action | 固定提交 |
|---|---|
| actions/attest-build-provenance | `e8998f949152b193b063cb0ec769d69d929409be` |
| actions/checkout | `11d5960a326750d5838078e36cf38b85af677262` |
| actions/setup-python | `a26af69be951a213d495a4c3e4e4022e16d87065` |
| actions/upload-artifact | `ea165f8d65b6e75b540449e92b4886f43607fa02` |

FFmpeg 8.1.2、Ollama 官方基线 0.40.6 及修补 Go CLI 的实际文件哈希见 native-runtime-files.json / runtime.json。MLX、MLX-C、llama.cpp、ggml、XGrammar 与内嵌第三方库的实际提交、版本、公告逐项对应及测试见 NATIVE_SECURITY_REVIEW.md。主程序和 llama.cpp 已重建，MLX 库保留已核对的官方载荷；没有声称逐行审计上游全部源码。

## 2. 问题汇总

| 编号 | 类别 | 严重级别 | 位置 | 状态 |
|---|---|---|---|---|
| D01 | 依赖 | High | constraints-security.txt:3、asr_server/asr_server.spec | 已修复；setuptools 83 迁移 |
| D02 | 依赖 | High | constraints-security.txt:4 | 已修复；Hydra 1.3.7 |
| D03 | 依赖 | High | constraints-security.txt:5 | 已修复；urllib3 2.8.0 |
| D04 | 依赖 | Medium | .github/workflows/build_dmg.yml | 已修复；pip >=26.2 |
| D05 | 依赖 | High | constraints-security.txt:9 | 已修复；PyInstaller >=6.22.1 |
| D06 | 依赖 | Medium | requirements.txt:10 | 已修复；已批准 websockets 17 并验证 |
| D07 | 依赖 | Medium（暂定） | asr_server/server.py，SoundFile / libsndfile 1.2.2 | 建议关注；按用户决定保留，公告未审核、修复版本待确认 |
| D08 | 依赖 | High（暂定） | runtime/ollama/go.mod、scripts/rebuild_ollama.py | 已复核并重建 Go / llama；具体公告与调用路径见原生报告 |
| D09 | 代码 | High | asr_server/offline_diarization_worker.py:15、asr_server/public_diarization_models.py:25 | 已替换为无账号 ONNX；完整模型实测通过 |
| C01 | 代码 | Medium | asr_server/server.py:661、asr_server/asr_security.py | 已修复；ASR HTTP/WS 鉴权与来源边界 |
| C02 | 代码 | Medium | asr_server/server.py:128 | 已修复；解析前上传、时长、会话限制 |
| C03 | 代码 | Medium | asr_server/offline_batch_worker.py:83 | 已修复；离线 URL、代理、重定向、鉴权边界 |
| C04 | 代码 | Medium | asr_server/secure_paths.py:13 | 已修复；目录包含校验、私有原子文件 |
| C05 | 代码 | Medium | HermeneusApp/App/Sources/ConversationContextEngine.swift:315 | 已修复；内容日志默认关闭 |
| C06 | 代码 | Medium | HermeneusApp/App/Sources/OfflineToolsPrototype.swift:313 | 已修复；取消未经验证的加密承诺 |
| C07 | 代码 | Medium | HermeneusApp/Packages/AudioCore/Sources/AudioCore/SCKAudioCapturer.swift:166 | 已修复；复制音频内存边界 |
| C08 | 代码 | Medium | .github/workflows/build_dmg.yml | 已修复；固定 Action SHA、消除标签插值风险 |
| C09 | 代码 | Low | HermeneusApp/App/Sources/OfflineBatchRunner.swift:7 | 已修复；子进程管道有界排空 |
| C10 | 代码 | Low | HermeneusApp/Packages/TTSKit/Sources/TTSKit/BlackHoleTTSEngine.swift:133 | 已修复；稳定设备 UID、绑定读回、缓冲与超时 |
| C11 | 代码 | Medium | runtime/ollama/hermeneus_security.go:14 | 已修复；私有端口之外增加访问凭据 |
| C12 | 代码 | Low | .github/workflows/build_dmg.yml:4 | 已修复；自动发布移除，仅人工构建、只读内容权限 |
| C13 | 代码 | Low | scripts/sign_full_bundle.sh:12 | 已修复；分别记录编译哈希与签名后哈希 |
| C14 | 代码 | Low | scripts/package_local.py:38 | 已修复；本地组装过滤 AppleDouble，补齐主许可证 |
| D10 | 依赖 | Medium | sherpa-onnx-core 1.13.8：未启用 ASR transducer | 待开发者决定；应用调用路径不适用，库内代码未修复 |
| N01 | 代码 | Medium | scripts/ollama_patches.py、runtime/ollama/hermeneus_access.go | 已修复；原生后端鉴权与重定向边界 |
| N03 | 依赖 | Medium（公告未审核） | scripts/rebuild_native_ollama.py；mtmd-helper.cpp:35 | 已按批准关闭 GIF，重建与负向测试通过 |
| S01 | 密钥 | Low | .gitignore:48、.env.example | 已加固忽略规则；凭据扫描结果另见证据 |

没有证实当前应用存在可直接利用的 Critical 漏洞。暂定级别用于尚未证明完整调用路径的风险，不作为 CVE 或利用证明。旧修复位置可能随本轮新增代码偏移，具体函数与旧报告详细条目交叉参照。

## 3. 已修复内容、利用条件与依据

D01–D06：构建期恶意下载源/打包输入、间接 Hydra 解析、HTTP 处理和受影响特权冻结程序分别是相应公告的必要条件；本应用不以 root/setuid 运行，也未直接调用 setuptools PackageIndex。仍通过安全版本下限减少供应链暴露。原锁定 setuptools 69.5.1 已按批准升级，删除 pkg_resources 兼容配置；websockets 13/14 限制已按批准迁移并以真实本机握手回归。具体公告和原始证据保留在旧报告及 audit/2026-10-17：

- [setuptools 路径穿越，78.1.1 修复](https://github.com/advisories/GHSA-5rjg-fvgr-3xxf)；[Unicode 排除绕过，83.0.0 修复](https://github.com/advisories/GHSA-h35f-9h28-mq5c)。旧 69.5.1 对另一条命令注入公告范围的文字/版本表差异仍不编造确定结论，升级已避免该区间。
- [Hydra 配置执行问题](https://github.com/advisories/GHSA-c3wx-c55w-pxjq)、[补充修复](https://github.com/advisories/GHSA-mwj6-rfh8-7qf4)，安全下限 1.3.7。
- [urllib3 公告](https://github.com/advisories/GHSA-vxq7-64xx-v4gw)及同轮其他公告见旧报告，安全下限 2.8.0。
- pip 与 PyInstaller 的官方公告链接见依赖表，补丁/小版本升级已直接执行。

D08 / C11：原官方 Ollama 编译入旧 Go 标准库和依赖，Python 升级无法修复。已固定官方源码和 SDK，升级有明确修复版的 Go 模块后重建。私有动态端口与精确版本检查避免复用旧服务。本轮进一步增加 32 字节随机能力凭据，仅在内存中生成、经子进程环境传递；服务端拒绝缺失/错误凭据、任何 Origin（包括 null）、非环回调用，使用常量时间比较。Swift 模型检测、下载、翻译和离线工作器同步更新，凭据只发往预期环回端口。模型/文字翻译正常请求通过，无凭据和网页来源实测 403。威胁条件是恶意网页或本机其他未获凭据的进程访问服务；已控制同一用户账户的恶意程序仍可读取该用户进程信息，不能视为强用户隔离。

D09：按用户最新要求，移除 pyannote.audio Community-1 的动态加载和 pickle 路径，采用 sherpa-onnx 官方公开转换的 segmentation-3.0 与 NVIDIA TitaNet Small。两份 ONNX 只通过固定 HTTPS 公开来源下载，不使用 HF Token / .netrc；每次加载先校验大小及 SHA-256，再复制到 0700 私有快照。下载禁用隐式环境认证，逐跳限制 HTTPS 主机、体积和超时，不解压任意路径或链接。界面选择双人模式后确认首次下载；缓存损坏确认后自动重新下载；后续可完全离线。音频先由私有 FFmpeg 转为最多两小时的单声道 16kHz PCM，工作文件保存在作业目录并清理；不上传录音。分离只能区分匿名 A/B，不能保证噪音、重叠和所有真人声线的准确率。新增直接/间接依赖已逐项查询官方公告和 pip-audit；内含 ORT 1.28.2 与环境 Python ORT 1.31.0 分别记录，未混用版本。

D10：[上游问题 #3983](https://github.com/k2-fsa/sherpa-onnx/issues/3983) / [NVD CVE-2026-108954](https://nvd.nist.gov/vuln/detail/CVE-2026-108954) 描述 OfflineTransducerGreedySearchDecoder 使用不一致的 decoder/joiner 元数据导致越界，最新正式 1.13.8 仍受影响，未确认正式修复版。当前 worker 只构造 OfflineSpeakerDiarization，不构造识别/Transducer/TTS 对象、不接受任意模型或配置；只有两份已校验的分离模型到达原生解析。应用未提供公告利用入口，不能把未调用组件写成“库已修复”。已依用户规则询问保留受限分离并记录风险，或另行补丁重建。另一条第三方分离索引越界预公告指向 <=1.13.0；已读取 1.13.8 源码确认 ReLabel、SortBySpeaker、标签/采样索引有边界检查，未编造 CVE。Microsoft 官方公开安全公告 API 当前返回空数组，不等同未知漏洞不存在。

C01–C04：原环回服务未鉴权，可被网页/其他本机进程调用；超大请求能在限额检查前被解析，离线地址/输出路径不严可导致本地请求滥用或覆盖文件。现为逐进程内存令牌、Host/Origin/peer/path 检查、预解析体积上限、有界内存音频及并发、UUID 作业与目录包含关系、0700 目录和0600原子文本写入。HTTP 代理和跨端点重定向关闭；URL 不接受远程、凭据或任意路径。

C05–C10：会话日志可能泄露敏感内容，默认关闭；不再宣称任意用户目录已加密；音频内存复制检查格式和边界；子进程错误输出有界排空避免死锁。BlackHole 按稳定 UID 绑定设备并读回，缺设备拒绝播放，界面显示错误/超时；语音缓冲用真实字节与对象预算，修复短句也容易溢出的旧限制。设备选择、刷新、测试和确认可在界面完成，用户不需要终端配置设备。

C08/C12：CI 固定第三方 Action 提交、禁用持久 checkout 凭据，去除未受约束的标签命令插值。本轮移除 tag 自动发布和 Release 写入步骤，仅保留手动构建/上传构建工件，避免用户复制 Git 推送命令后意外触发公开发包。安全门禁没有被改成“已批准”。

C13/C14：签名会修改 Mach-O 字节，原先构建哈希不能直接当作安装包内哈希；现在保留编译哈希，另记 packaged_cli_sha256，并在应用封签前写入。最终镜像校验两种来源记录。实际挂载检查还发现本地临时运行目录含有会被制盘移除的 AppleDouble 旁文件，本地打包入口已与安全提取入口一致过滤这些文件。缺少的 Ollama 主许可证从固定官方源码补入版本控制和运行包。影响是交付可验证性、签名完整性与许可证合规，无需假设远程代码利用。失败的中间镜像未交付。

S01：本轮补充忽略未跟踪的 `.local_test/` 大型旧二进制与临时复制文件，避免 `git add .` 上传本地测试产物。`.env*` 已忽略，仅变量名示例允许提交。没有把测试凭据当作生产凭据或写入示例。若今后确认某密钥曾提交或公开，必须在对应平台作废并重新生成，仅删代码不够；当前扫描未确认需要轮换的真实密钥。另对两套冻结程序内的 63,541 个归档条目/模块、约 2.59GB 解压内容进行只读扫描；52 个匹配逐一复核均为上游文档占位数据库口令、环境变量/HTTP 头名称、提供商示例 API-key 占位文字或 cryptography 的 SSH PEM 起始标记，不是用户生产凭据。复核证据保留文件位置和指纹，不输出潜在密钥原文。

## 4. 开发者决定与剩余风险

已执行的决定：setuptools 大版本迁移、websockets 17；libsndfile 无确认修复版时保留导入并记录风险；Ollama 修补重建；按批准关闭 GIF；按最新要求改为无需账号的离线分离；接受未做 Developer ID / Apple 公证的分发限制。没有上传 GitHub、接受 gated 账户条款、轮换凭据或修改原 Git 历史。

1. **待开发者决定：D10 未使用的识别解码器公告**。推荐保留仅分离入口、固定模型校验，报告记录未调用组件风险；另可补丁重建 sherpa。该决定到达前，保持 release_approved=false，不提供正式发布命令。
2. **已接受剩余风险：libsndfile 1.2.2**。公告未审核、修复版本待确认；保留可信文件导入与独立进程/体积时长限制，工作进程不是操作系统安全沙箱。
3. **已接受分发限制：未做 Apple 公证**。仅临时签名完整性检查，不代表 Apple 认证；按 [Apple 官方说明](https://support.apple.com/zh-cn/102445)对单个应用“仍要打开”，不关闭 Gatekeeper 或 SIP。
4. **验收范围限制**。当前 Apple M4 测试通过；没有第二台全新 macOS 14/M1，不能声称新电脑与所有会议软件完成实机验收。BlackHole 虚拟输入有实际信号，不等于远端会议另一人确认听到。

## 5. 本轮最终验证

- Swift Release、26 项 Python 回归、音频设备路由与翻译流检查通过。
- Go 主程序与原生后端鉴权、安全重定向及真实 Qwen 中译西通过；llama 固定源码 GGUF 189/189 回归通过，GIF 排除/普通图像保留负向测试通过。
- 无账号空缓存下载、源码及冻结程序禁止联网/禁止 Homebrew 的西语 A/B/A/B 实测通过；官方中文四人样本 10 段、4 人及重现关系匹配。模型缓存大小/SHA/链接/未确认下载等保护有测试。
- 当前正式 AudioReturnProbe / TTSKit 的 BlackHole 2ch 实测通过：48kHz、220800 帧、基线 RMS=0、语音 RMS=0.07933、有效语音 2.9 秒；未保存音频。
- 本轮最终 DMG 的挂载、深层完整性、内置服务启动及离线任务结果追加于下方交付记录；不能沿用旧 DMG 校验和。

以下是前轮验证历史，当前组件变化与结论以本节及 NATIVE_SECURITY_REVIEW.md 为准。

## 6. 构建、测试和交付证据

本轮 Python 25 项测试通过；Swift Release 构建通过；流式完成/截断/错误/空响应测试与真实设备绑定读回通过。真实 Swift 客户端在私有端口完成鉴权、精确安全版本校验与固定中译西流式请求。pip check 无冲突；完整 Python 依赖扫描和 SBOM、Go 扫描、密钥扫描及最终镜像验收结果见本轮 audit 目录。

安装包：`dist/v1.0.0/Hermeneus-v1.0.0-Full.dmg`。干净源码导出：`dist/v1.0.0/source/Hermeneus/`，没有复制旧 Git 历史、旧标签、模型、用户音频和运行日志。原项目 `.git` 和旧 QA 镜像保留。最终镜像哈希在同目录 SHA256SUMS。发布命令仅写入 GITHUB_UPLOAD.md，未执行。

具体最终构建/扫描统计在本文件后续“最终结果”中记录；不要把先前 QA 镜像测试当成本次镜像测试。

### 最终结果

- 安装镜像：Hermeneus-v1.0.0-Full.dmg，993,839,897 字节。SHA-256：`025e249562811ca051167c01996c039c3c6fe571356f5e74362b4488b6840ace`。
- 最终只读挂载后的深层临时签名、应用名称/版本和签名后 CLI 哈希检查均通过；没有将失败中间镜像交付。
- 禁止读取 `/opt/homebrew` 与 `/usr/local` 后，最终包的 ASR 导入及离线分离器合成 WAV 实际解码通过。
- 最终镜像中的真实中/西语 ASR 模型加载与静音预热通过，未授权 HTTP 请求返回 403；Ollama 固定文字中译西通过，缺失/错误凭据及浏览器来源被拒绝。没有使用私人音频或麦克风。
- Python 25 项测试、Swift Release 与流式/设备绑定测试通过，162 项构建环境依赖 pip-audit 无已知匹配，pip check 无冲突。
- 原工作区扫描 19,040 个文件约 6.04GB、125 个历史 blob；本轮源码与冻结产物扫描 189 个文件约 783MB；另展开两套冻结程序 63,541 个条目约 2.59GB 并复核 52 个误报，未确认真实凭据泄露。各视图存在重叠，不能相加作为唯一文件数；扫描不保证穷尽所有编码/隐藏秘密。
- BlackHole 输入、真实 gated 分离模型、原生载荷复核和正式签名公证保持待确认。安全门禁仍为未批准，最后提供的 GitHub 命令仅创建草稿。
