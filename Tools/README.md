# 音频精度验证复现

验证环境：Apple Silicon Mac。验证脚本需要 Python 3.12+，依赖只用于开发测试，不进入 app。

在仓库根目录执行：

```sh
python3 -m pip install --target Tools/validation-deps imageio-ffmpeg==0.6.0 pyloudnorm==0.2.0 numpy==2.5.3 scipy==1.18.1
swiftc -O Source/TruePeak.swift Source/Loudness.swift Source/MeterCheck.swift -o Tools/MeterCheck
python3 Tools/validate.py
python3 Tools/check_lra.py
python3 Tools/validate_standards.py
python3 Tools/recheck.py
```

如需增加自有音频，在 validate.py 后传入音频绝对路径。默认生成 29 组信号；本次另外对照 1 条私有音乐，共 30 组。私有音乐不分发。脚本调用 FFmpeg、pyloudnorm 和 SciPy，仅本地处理。

初轮 validate.py 将 FFmpeg 所有指标用于筛选，可能因 LRA 尾部窗口和峰值边界处理差异标记 FAIL；最终 recheck.py 保留这些差异，另按 LUFS 与两套参考 ≤0.1 LU、LRA 与 pyloudnorm ≤1 LU、True Peak 与 SciPy 16× ≤0.3 dB 的判据复核，并检查公开标准描述的相应指标预期。不能把不同判据混为一谈，也不能据此宣称完整标准认证。

标准信号由公开描述合成，不是 EBU 下载文件。生成的 signals、JSON、日志、MeterCheck 与 validation-deps 不应提交到仓库或放入安装包。


## 大工程库基准

在源码根目录运行以下命令，两个变量均使用绝对路径，夹具目录必须是专用临时目录：

```sh
CUBASESHELF_BUILD_DIR=/tmp/CubaseShelf-perf-build \
CUBASESHELF_PERF_DIR=/tmp/CubaseShelf-perf-fixture \
bash Tools/performance.sh
```

程序创建 1,000 个模拟工程（每个 4 KiB 占位 CPR、20 个空备份、一个空试听和一个应排除的 Audio 文件），只验证索引逻辑，不播放占位音频。另生成 5,000 条内存记录、模拟目录暂时离线、移动身份匹配和扫描期间编辑。会在专用夹具内创建、改写并删除测试文件；不要指向用户工程。不会读取默认应用资料库。

输出为单次墙钟测量，受系统负载和缓存影响；不是跨机器性能承诺。完整 EBU 音频分析验证仍是单独工具，不由本基准替代。


## v0.7 的 5.1 文件对照

`AudioFileCheck.swift` 调用应用实际的 WaveformReader，验证 WAV/CAF 读取和声道布局；单独编译，不加入 app 主入口。以源码根目录为当前目录：

```sh
swiftc -O -swift-version 5 Source/{ProjectMetadata,Library,Relocation,TruePeak,Loudness,Alignment,ChannelLayout,Theme,Audio}.swift Tools/AudioFileCheck.swift -o /tmp/AudioFileCheck
```

运行 `validate_surround.py <专用输出目录>` 前设置环境变量：`CUBASESHELF_VALIDATION_DEPS`（含 NumPy、pyloudnorm 的目录）、`CUBASESHELF_FFMPEG`（ffmpeg 可执行文件绝对路径）、`CUBASESHELF_AUDIOCHECK`（上述测试程序绝对路径）。脚本会创建五个合成 5.1 WAV，对照 FFmpeg 与 pyloudnorm；不要指向用户音频目录。MeterCheck 的可选第五个参数 `5.1` 声明原始 PCM 顺序为 L R C LFE Ls Rs。

## 应用图标

在 macOS 上运行 `swift Tools/GenerateIcon.swift Resources/BrandLogo.png Resources/LifelineIcon.icns` 可重建圆角、多尺寸 ICNS。保留原始标志，仅增加圆角底板与透明外边距。
