# 依赖与实际版本清单（2026-10-17）

此清单区分源码约束、实际构建环境和原生二进制。没有把 requirements 范围下限当作锁文件。当前 Swift Package 只有本地包依赖，无远程 Package.resolved。

## Python 直接依赖（13 个）

| 包 | 声明约束 | 实际版本 |
|---|---|---|
| torch | `torch>=2.14.1,<3` | 2.14.1 |
| torchaudio | `torchaudio>=2.11.0,<3` | 2.11.0 |
| faster-whisper | `faster-whisper>=1.2.1,<2` | 1.2.1 |
| funasr | `funasr>=1.4.16,<2` | 1.4.16 |
| modelscope | `modelscope>=1.40.2,<2` | 1.40.2 |
| soundfile | `soundfile>=0.14.0,<0.15` | 0.14.0 |
| bottle | `bottle>=0.13.4,<0.14` | 0.13.4 |
| numpy | `numpy>=2.4.6,<3` | 2.4.6 |
| ctranslate2 | `ctranslate2>=4.8.3,<5` | 4.8.3 |
| websockets | `websockets>=17.2,<18` | 17.2 |
| scipy | `scipy>=1.17.1,<2` | 1.17.1 |
| requests | `requests>=2.34.2,<3` | 2.34.2 |
| sherpa-onnx | `sherpa-onnx==1.13.8+hermeneus.1` | 1.13.8+hermeneus.1 |

实际构建环境共 163 个 distribution（含构建工具/训练依赖），完整清单见 `dependencies/python-installed.json`、`dependencies/python-resolved.txt`。pip-audit 对该清单未报告已知漏洞，但无法解析本地 URL 安装的定制 sherpa wheel；这不是全部原生 C/C++ 组件无漏洞的结论。

## 关键 Python 间接/构建依赖

| 包 | 实际版本 |
|---|---|
| av | 18.1.0 |
| onnxruntime | 1.31.0 |
| transformers | 5.20.1 |
| huggingface-hub | 2.2.0 |
| pyyaml | 6.0.3 |
| hydra-core | 1.3.7 |
| urllib3 | 2.8.0 |
| cryptography | 50.0.2 |
| pycryptodome | 4.0.1 |
| httpx2 | 2.13.1 |
| httpcore2 | 2.13.1 |
| safetensors | 0.8.0 |
| aiohttp | 3.14.5 |
| setuptools | 83.0.0 |
| pip | 26.2.1 |
| wheel | 0.48.0 |
| pyinstaller | 6.22.3 |
| pyinstaller-hooks-contrib | 2026.8 |

## Go 直接依赖（33 个）

go.mod 共 82 个模块，其中 49 个 indirect；完整实际版本见 `dependencies/go-modules.json`。go.sum 是校验账本，含历史/测试依赖的条目不代表其全部进入最终二进制。

| 模块 | 实际选择版本 |
|---|---|
| github.com/TheTitanrain/w32 | v0.0.0-20180517000239-4f5cfb03fabf |
| github.com/containerd/console | v1.0.3 |
| github.com/gin-gonic/gin | v1.12.0 |
| github.com/google/go-cmp | v0.7.0 |
| github.com/google/uuid | v1.6.0 |
| github.com/ledongthuc/pdf | v0.0.0-20250511090121-5959a4027728 |
| github.com/mattn/go-sqlite3 | v1.14.52 |
| github.com/olekukonko/tablewriter | v0.0.5 |
| github.com/spf13/cobra | v1.7.0 |
| github.com/stretchr/testify | v1.11.1 |
| github.com/x448/float16 | v0.8.4 |
| golang.org/x/sync | v0.23.0 |
| golang.org/x/sys | v0.48.0 |
| github.com/agnivade/levenshtein | v1.1.1 |
| github.com/charmbracelet/bubbletea | v1.3.10 |
| github.com/charmbracelet/lipgloss | v1.1.0 |
| github.com/d4l3k/go-bfloat16 | v0.0.0-20211005043715-690c3bdd05f1 |
| github.com/emirpasic/gods/v2 | v2.0.0-alpha |
| github.com/klauspost/compress | v1.18.7 |
| github.com/mattn/go-runewidth | v0.0.16 |
| github.com/pelletier/go-toml/v2 | v2.2.4 |
| github.com/pkg/browser | v0.0.0-20240102092130-5ac0b6a4141c |
| github.com/tkrajina/typescriptify-golang-structs | v0.2.0 |
| github.com/tree-sitter/go-tree-sitter | v0.25.0 |
| github.com/tree-sitter/tree-sitter-cpp | v0.23.4 |
| github.com/wk8/go-ordered-map/v2 | v2.1.8 |
| go.yaml.in/yaml/v3 | v3.0.4 |
| golang.org/x/image | v0.45.0 |
| golang.org/x/mod | v0.41.0 |
| github.com/gin-contrib/cors | v1.7.2 |
| golang.org/x/crypto | v0.57.0 |
| golang.org/x/term | v0.46.0 |
| golang.org/x/text | v0.42.0 |

## 关键 Go 间接依赖

| 模块 | 实际选择版本 |
|---|---|
| github.com/bytedance/sonic/loader | v0.5.0 |
| github.com/goccy/go-yaml | v1.19.2 |
| github.com/quic-go/qpack | v0.6.0 |
| github.com/quic-go/quic-go | v0.59.1 |
| github.com/bytedance/sonic | v1.15.0 |
| github.com/go-playground/validator/v10 | v10.30.1 |
| golang.org/x/net | v0.60.0 |
| google.golang.org/protobuf | v1.36.10 |
| gopkg.in/yaml.v3 | v3.0.1 |

`gopkg.in/yaml.v3` 仍由测试依赖引入，但实际主程序 package 清单不包含它；应用/有序映射运行时使用 `go.yaml.in/yaml/v3 v3.0.4`。官方声明该 v3 分支只接收安全修复，v4 才是新功能分支，不能把“安全维护中”误报为“完全停止维护”。

## 原生与工具链

| 组件 | 核实版本/来源 | 限制 |
|---|---|---|
| CPython | 3.11.17 | 安全维护阶段 |
| Go SDK | go1.27.2 | 固定 SHA-256 |
| CMake | 4.4.4 | 原生构建配方固定 |
| Ollama | 0.40.6-hermeneus.6；源码 2476d5ead197abe04629651028f83d48dc75d2b2 | 自维护 IPC 补丁 |
| llama.cpp | 620d2225cc436ab0b001e3200e590e3b286ef9ab | 自构建；RPC 与 GIF 关闭 |
| SQLite | 3.53.4（go-sqlite3 v1.14.52 的 sqlite3-binding.c） | Go 扫描不完整覆盖该 C 层 |
| libsndfile | 1.2.2-hermeneus.2 | WAV 标签与对齐修复、IMA 三处乘法修复、IRCAM 解析加固；更广泛公告影响待确认 |
| 私有 FFmpeg | 8.1.2 | disable-network；与 PyAV 内嵌库分开核查 |
| PyAV 内嵌 FFmpeg | 8.1.2；avutil 60.26.102 / avcodec 62.28.102 / avformat 62.12.102 / avfilter 11.14.102 | 不能用系统 ffmpeg 的版本替代 |
| sherpa-onnx | 1.13.8+hermeneus.1 | 源码与 transducer 边界补丁固定 |
| sherpa 内嵌 ONNX Runtime | 1.28.2；来源/下载哈希来自固定 sherpa CMake 配方 | 与 Python onnxruntime 1.31.0 不同 |
| xgrammar（Ollama MLX payload） | v0.2.7 | 官方 GHSA-3gmq-qh92-5grm 标明 0.2.6 修复；当前 0.2.7；未发现首方调用 DeserializeJSON |
| MLX-C | a341b4925024b88b2c593468f16e12f5e17315da（源码固定值） | 实际官方 payload 的所有传递原生构建细节未独立复现 |

## 检索记录与维护状态

13 个 Python 直接包、33 个 Go 直接模块及上述关键间接/原生组件均进行了逐项查询；查询结果保留在 `web-search-evidence.json`。版本精确查询无结果时，没有据此宣称无漏洞；同时交叉核对扫描器及官方安全页。

- `httpx2/httpcore2` 已核对 Pydantic 官方仓库和 Hugging Face 官方依赖迁移，未发现仅因名称相似就足以判定仿冒的证据。
- `golang.org/x/crypto/openpgp` 已弃用，官方认为设计不安全；当前实际包清单不包含它，govulncheck 只给出模块级 GO-2026-5932。
- `gopkg.in/yaml.v3` 原仓库已停止维护，仅测试链保留；维护中的替代路径见上。
- TheTitanrain/w32 的固定提交来自 2018 年，float16 v0.8.4 发布较早，有序映射上游 v2.1.8 较旧：列为低更新频率/维护状态待持续确认；没有把“多年未发版”直接等同于恶意包或已确认漏洞。
- tablewriter 新主版本与当前 v0.0.5 API 不兼容；本轮未为追新擅自升级主版本。


## 重发复核补充

构建环境实数为 163 个 distribution；早先文字中的 160 是计数笔误，已按完整 JSON 纠正，没有因此新增或替换运行时依赖。2026-10-17 再次逐项检索 13 个 Python 直接包与 33 个 Go 直接模块，并复跑 pip-audit 与 govulncheck。精确版本查询无结果不等于没有漏洞；扫描器和原生人工审查同时使用。

- CPython ssl 实际 OpenSSL 3.5.9；cryptography 实际 OpenSSL 4.0.3，均已达到 2026-09-29 公告修复版本。[官方公告](https://openssl-library.org/news/vulnerabilities/)
- NumPy、SciPy 的 BLAS/LAPACK 实测为系统 Accelerate，不应虚构 OpenBLAS 版本。系统框架由 macOS 更新负责。
- TorchAudio 2.11.0 已进入维护阶段，官方支持 torch 2.11 及后续版本；2.14.1/2.11.0 组合安装检查与实际导入通过。[官方兼容说明](https://github.com/pytorch/audio)
- ModelScope PR #1759 尚未合并，涉及恶意模型配置进入图像/动态实例化路径；本应用调用模型下载与固定语音模型，设置 trust_remote_code=False，未发现调用这些图像 pipeline 的路径。不能用“没有发布 advisory”替代这项风险判断。[官方候选讨论](https://github.com/modelscope/modelscope/pull/1759)
- go-tree-sitter #55 的 ParseWithOptions 回调句柄泄漏目前只在构建生成器依赖中识别到 go-tree-sitter，本地运行时主程序 package 清单未包含该模块，没有把它写成应用可利用漏洞。[上游问题](https://github.com/tree-sitter/go-tree-sitter/issues/55)
- 兼容 orderedmap 模块已补齐维护中 YAML 的 go.sum 校验及独立测试依赖；go test -mod=readonly 独立运行通过。根模块实际选择版本不变，Ollama 已按更新后的完整来源记录重建。
- 完整 SBOM 含 Python 构建环境、Go 模块和已识别原生组件；不是所有静态/传递 C/C++ 组件均已独立复现的声明。

最终兼容修订 .6：对官方 MLX Metal 4 动态库的 macOS 26.2 最低版本进行主/小版本判断，旧系统保留 Metal 3；库本身未被宣称可在 macOS 14 加载，Metal 4 为条件使用的可选变体。
