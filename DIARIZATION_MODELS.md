# 无需账号的离线说话人分离

普通用户选择本地文件，选择“双人说话”，点击“开始本地转译”，阅读说明后点“确认并开始”。首次从官方公开 GitHub Release 下载约 47 MB；模型进入所选存储目录的 `Hermeneus Data/model-cache/onnx-diarization-v1`。以后断网使用；缓存损坏时确认后重新下载。无需 Hugging Face 账号、Token 或终端。

音频仅在本地独立工作进程中处理。下载只传输模型请求，不上传录音。模型格式为 ONNX，不运行远程 Python 代码、YAML 类名或 pickle。固定大小和 SHA-256 校验后复制到私有快照，再交给推理库。

- 分段：pyannote segmentation 3.0，由 sherpa-onnx 官方转换并公开分发，MIT；版权全文见 `licenses/diarization/SEGMENTATION_LICENSE`。
- 声纹：NVIDIA TitaNet Small，由 sherpa-onnx 官方转换并公开分发；NVIDIA 模型卡说明适用 NeMo Toolkit 许可，Apache 2.0；全文见 `licenses/diarization/NEMO_LICENSE`。
- 推理：sherpa-onnx 1.13.8+hermeneus.1（固定源码、包含元数据越界补丁的独立构建，不使用未修补的 PyPI core）；其中 ONNX Runtime 实际为 1.28.2。应用只调用 OfflineSpeakerDiarization，不创建其 ASR / TTS / Transducer 对象。模型清单在 `asr_server/public_diarization_models.py`。

官方来源：[下载与使用说明](https://k2-fsa.github.io/sherpa/onnx/speaker-diarization/models.html)、[NVIDIA 模型卡](https://catalog.ngc.nvidia.com/orgs/nvidia/teams/nemo/models/titanet_small)、[NeMo 1.19.0 许可证](https://github.com/NVIDIA/NeMo/blob/v1.19.0/LICENSE)。首次确认下载即选择使用上述许可下的模型，无须注册服务账户。

这是匿名区分 A / B，不能识别真人身份。重叠讲话、很短的话音、噪音和声线相似时可能分错；双轨录音优先用轨道来源。西语双声线合成样本实测通过不等于真实会议全场景准确率保证。
