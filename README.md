# HiFi SRC Bypass · 全机型 USB 直通

> 全机型通用的 Android 模块：**USB 小尾巴 / 有线耳机高解析直通（SRC 绕过）**。
> **两层上限一起解** —— ① 音频策略 XML（框架允许分发什么）② USB HAL 库里的采样率常量表（DAC 实际能开到多少）。
> 档位 96k / 192k / 384k 可选、位深 16 / 24 / 32 bit 可切、全局混音率可对齐 44.1k 消除系统重采样。
> 原厂文件零改写（systemless 绑定挂载），一键还原、卸载自动清理。

本项目是本人 [op13-hifi-src-bypass](https://github.com/lizi600jin/op13-hifi-src-bypass) 的**二改**：
把「一加 13 专用」重做成**不需要任何机型模板**的全机型通用模块 —— 文件在设备上按规则就地改写，
方言自动识别，机型差异交给规则而不是硬编码路径。

---

## 1. 它解决了什么：为什么「改完 XML 还是 96 kHz」

Android 上其实存在**两个互相独立的上限**，绝大多数教程只处理了上面那个。

| 层 | 在哪 | 决定了什么 | 本模块怎么改 |
|---|---|---|---|
| ① 框架层 | `*audio_policy_configuration*.xml` / `audio_module_config_primary.xml` 里的 `samplingRates` | AudioPolicyManager 允许**分发**的上限 | 规则化改写 profile（第 1.1 节） |
| ② **硬件层** | `/vendor/lib{,64}/libalsautils{,v2}.so` 里一张 **52 字节常量表** | USB HAL 实际**打开**的上限 —— **DAC 真正看到的** | 等长原位重排这张表（第 1.2 节）★ |

### 1.1 第一层：策略 XML

模块自动找出本机所有**真正含有 USB / 有线 / DIRECT 输出口**的策略文件并改写：

- 把这些端口的 `samplingRates` 重新封顶到所选档位
- 原厂只声明 16-bit 时，补上 24-bit / 32-bit 的 profile（**只做加法，从不删掉原厂声明的任何格式**）
- 主媒体输出（`low_latency_out` / `deep_buffer_out`）与 `speaker` / `earpiece` 的工作频率对齐到所选混音率，消除 AudioFlinger 重采样

**输入口（麦克风）一律不碰**，`role="source"` 与 `_IN_` / mic 名字会被两层挡住。
改写后还有一份**结构校验器**逐项比对端口与路由，只要发现「除了 profile 内容以外还有任何变化」就**拒绝挂载**。

### 1.2 第二层：USB HAL 库的采样率表 ★

这是本模块相对多数同类做法的关键差异。

AOSP 的 USB 音频 HAL 实现（`libalsautils.so` / `libalsautilsv2.so`）里编译进了一张**固定的采样率表**，
源码位于 `system/media/alsa_utils/alsa_device_profile.c` 的 `std_sample_rates[]`：

```
工厂  : 96000  88200  192000  176400  48000  44100  32000  24000  22050  16000  12000  11025  8000
192 kHz: 192000 176400 96000   88200   48000  44100  32000  24000  22050  16000  12000  11025  8000
384 kHz: 384000 352800 192000  176400  96000  88200  48000  44100  32000  24000  16000  12000  8000
768 kHz: 768000 705600 384000  352800  192000 176400 96000  88200  48000  44100  24000  16000  8000
```

**表里第一项就是它对外宣称的最大值**，绝大多数 ROM 是 `96000`。所以哪怕你把 XML 改成 384k，
DAC 那一侧仍然卡在 96k —— 这就是「改了没用」的根因。

本模块把这张表**原位重排**：

- 四张表**都是 13 项 uint32 = 52 字节**，替换后**文件长度完全不变**，不动任何偏移、不破坏重定位
- 只补丁**本来就存在**的文件，从不凭空创建覆盖层
- 补丁完**必须复核**：文件长度不变 + 前 16 字节 ELF 头逐字节相同 + 原表 0 次 / 新表恰好 1 次 / 偏移与原来一致 + 回读那 52 字节与期望完全一致；任一不符就删掉输出并放弃
- 原表**出现 0 次**（不是 AOSP 表，属厂商自写 HAL）→ 跳过；**出现 2 次以上**（有歧义）→ 拒绝猜测，绝不碰

### 1.3 为什么有的机器「改 XML 完全没用」

本模块在真机上确认了两种会让第一层彻底失效的形态：

1. **USB 输出口没有 profile** —— 有的 ROM 把 `<devicePort tagName="USB Device Out" …>` 写成空元素，
   速率由 HAL 运行时决定。此时 XML 里根本没有东西可改。
2. **Android 13+ 的 AIDL HAL 只把 XML 当骨架** —— 框架 `dumpsys` 里那些端口标着
   `[dynamic format]`，能力由 HAL 运行时上报；甚至 `Config source` 直接回答 `AIDL HAL`（**不是文件路径**）。
   这类机器上，**第二层是唯一有效的杠杆**。

所以本模块把第二层做成一等公民，而不是可选项。

---

## 2. 实测结果

本模块在两台差异很大的真机上完成端到端验证（不是「装上没报错」，而是「实时输出速率确实到了」）：

| | 米系（QTI，HIDL 风格策略） | O 系（QTI，AIDL） |
|---|---|---|
| 设备 | Redmi K20 Pro (`raphael`) | OnePlus 13 (`OP5D0DL1` / `PJZ110`) |
| 平台 / 系统 | SM8150 · Android 16 | SM8750 "sun" · Android 16 |
| 生效的目标文件 | `/vendor/etc/audio_policy_configuration.xml` | **`/odm/etc/audio/audio_module_config_primary.xml`**（+ `/vendor/etc/audio/…`） |
| 框架自报 config source | 文件路径 | **`AIDL HAL`** |
| 方言 | `type` / `format` | **`tagName` / `pcmType` / `connection`** |
| USB HAL 库 | `libalsautils.so` ×2 | `libalsautils.so` + `libalsautilsv2.so`，lib64 + lib **共 4 个** |
| 第一层是否有效 | ❌ 端口无 profile（如 1.3 所述） | ✅ 有效 |
| **实测结果** | **384000 Hz / PCM_32_BIT 实时输出**（连续采样一致） | **384k/32bit 直通无异常；192k/24bit + 混音 44.1k 无异常** |

两台机器的共同点是「**上限都由第二层决定**」，而路径、方言、库数量全不相同，却**没有一行机型专属代码** —— 这是本项目敢说「通用」的依据。

**未验证、不敢承诺的**：MTK 与谷歌 Tensor（USB 硬件 offload 通常只到 96k，且多半没有 `libalsautils*so`，本模块会安全跳过）、三星 One UI、Android 12 及更早的老 ROM。这些都有夹具测试覆盖，但没有真机数据。

---

## 3. 档位、位深与预设

| 项 | 可选值 | 说明 |
|---|---|---|
| 直通上限 `MAX_RATE` | 48000 / 96000 / 176400 / 192000 / 352800 / 384000 | 192k 无论选哪档都会保留 |
| 位深上限 `BIT_DEPTH` | 16 / 24 / 32 | **是上限不是唯一**：16 保持原厂，24 追加 24-bit，32 追加 24+32-bit |
| 混音率 `MIXER_RATE` | 44100 / 48000 | 48000 为原厂典型值；曲库以 44.1k 为主时选 44100 可全局免重采样 |

一键预设：`auto`（读小尾巴上报能力自动配）/ `384k` / `192k` / `96k` / `44k`。

---

## 4. 安装

1. 下载本仓库 `dist/hifi-src-bypass-v1.6.zip`
2. Magisk / KernelSU / APatch → 从本地安装 → 选择 zip
3. 重启
4. 打开模块页 → **WebUI**（KernelSU / APatch 支持；Magisk 用操作按钮或终端）

安装脚本会**报告本机实际有什么**（策略文件、USB HAL 库、DAC），不做任何假定。
升级时 `config.conf` 会被保留。

---

## 5. 使用

### WebUI
一键预设、单独调混音率/上限/位深、**一键还原**、页内一键校验（= `hifi doctor`）。

### 命令行

```sh
H=/data/adb/modules/hifi_src_bypass/bin/hifi

sh $H status            # 当前状态：两层是否生效 + 已识别到的文件 + DAC
sh $H files             # 每个目标文件及其归档、补丁位置
sh $H hal               # USB HAL 库清单与各自当前的上限
sh $H dac               # 探测 USB 小尾巴
sh $H verify            # 检查实际生效的配置与 audioserver 视角
sh $H doctor            # 深度体检：四层证据（配置 / audioserver / 链路 / 内核）
sh $H report [file]     # 生成一份可读诊断快照（默认 /data/local/tmp/，adb pull 即可取）
sh $H rates             # 列出可选档位
sh $H preset auto       # 读小尾巴能力自动配置（推荐）
sh $H set hal 0         # 只改策略层，不动 HAL 库
sh $H apply             # 开启：生成 + 挂载，跨重启保持
sh $H restore           # 关闭：卸载 + 回原厂，模块保留
sh $H uninstall         # 手动全量清理（正常由管理器调用）
```

`hifi missing` / `hifi applied` 返回整数，供开机自检脚本判断「有几个目标掉线了」——
它们会分别校验两层：一份 XML 认文本标记，一个 `.so` 认采样率表。

---

## 6. 文件结构

```
module.prop                 模块元信息
customize.sh                安装脚本（报告本机实情；升级保留配置）
post-fs-data.sh             开机早期挂载（最关键时机）+ 写诊断快照
service.sh                  开机后逐目标校验，真丢了才补挂
action.sh                   管理器操作按钮 = 开/关开关
uninstall.sh                卸载：跨命名空间解除绑定 + 清空全部残留
bin/hifi                    控制器（status/files/hal/dac/verify/doctor/report/
                            rates/set/preset/apply/restore/missing/applied）
bin/probe192.sh             深度校验：四层证据 + 结论（= hifi doctor）
payload/patch_policy.awk    规则化策略改写器（方言自动识别）
payload/check_policy.awk    结构校验器（端口/路由有非预期变化就拒绝挂载）
payload/patch_hal.sh        USB HAL 采样率表的等长原位重排器
webroot/                    KernelSU / APatch WebUI
dist/                       打好的可刷入 zip
```

### 运行时目录（卸载时整体删除）

```
/data/adb/hifi_src_bypass/
├── patched/   生成好的补丁副本（挂载源）
├── stock/     原厂归档（还原与二次生成的基线）
├── config.conf
├── targets.lst        本次决定要补哪些文件（含每层的归档与补丁路径）
├── report.txt         每个文件「被补丁 / 被跳过」及原因
├── last.log
└── loaded_policy.path / config_source.txt   框架自报的配置来源（自动学习）

/data/local/tmp/hifi_src_bypass_report.txt        开机自检写的可读快照
/data/local/tmp/hifi_src_bypass_report_boot.txt   同上（更早的阶段）
```

---

## 7. 安全性与可逆性

- **从不写入 `/odm` `/vendor` `/system`**：只在 `/data/adb/…` 生成副本，用 `mount --bind`
  盖在真实路径上，且在**全局（init）挂载命名空间**里挂，`audioserver` 才看得到
- **还原 = 卸载绑定**，原厂文件一个字节没动过；进不去全局命名空间时还会扫其它命名空间兜底
- 策略改写**先过结构校验**，HAL 表改写**先过四项复核**，任何一项不过就放弃而不是「先挂上再说」
- 判定「是否生效」**分两层**：XML 认文本标记，`.so` 认采样率表 —— 因此开机自检不会误判、
  也不会因为一个 `grep` 不到标记就无限重挂
- 用户把某一层关掉后，**已经被挂上的那一层会被主动卸载**，不留悬挂挂载
- 目标不在列表里了（ROM 升级、层被关闭）也会被卸载

---

## 8. 已知边界

- **不适用**：Android 7 及更早（`audio_policy.conf` 时代，无 XML 策略）→ 安装后保持惰性
- **未验证**：MTK / 谷歌 Tensor（`libalsautils*so` 常缺失，会走「安全跳过」路径）、三星 One UI、Android 12 及更早
- **改不了的情况**：ROM 用的是厂商自写 USB HAL（表不存在）且策略 XML 又是无 profile 的空壳 ——
  此时两层都无从下手，模块会明确报告「本机没有可补丁的目标」而不是假装成功
- **上限高于 DAC 真实能力会导致无声**：请用 `hifi preset auto` 或 WebUI 的小尾巴卡片对齐档位

### 遇到不支持的机型怎么办

在管理器终端（或 adb）跑一次深度校验：

```sh
sh /data/adb/modules/hifi_src_bypass/bin/hifi doctor
```

它的第 **[8] 段「机型适配信息」**就是为这件事准备的，会把三样东西一次列清：

- **策略文件** —— 本机有哪些、模块补了哪一个 / 跳过了哪一个以及原因、每个文件用的是哪种方言
- **策略基线** —— 模块挂载的内容是由哪些原厂件生成的（归档清单与大小）
- **音频输出文件的真实路径** —— 逻辑层（策略里 USB / WIRED / DIRECT 端口分别属于哪个文件）
  + 物理层（内核导出的 `/proc/asound` 声卡与 PCM 节点）+ 框架里绑定的 `card=` 号

把 **[8] 段**和 **[7] 段「排查明细」**一起贴到 issue，再附一句「机型 / 系统版本 / 小尾巴型号 / 现象」，
就能直接定位是**策略路径不认识**、**方言不认识**，还是 **HAL 表对不上**。

想一次性导出成文件的话：

```sh
sh /data/adb/modules/hifi_src_bypass/bin/hifi report
# 写到 /data/local/tmp/hifi_src_bypass_report.txt —— 无需 root 即可 adb pull 取回
```

---

## 9. 致谢与参考

> **说明**：以下只列**真正被采纳**的东西。本项目由本人
> [op13-hifi-src-bypass](https://github.com/lizi600jin/op13-hifi-src-bypass) 二改而来 ——
> 那是本人自己的项目，不再单独致谢；op13 里继承来的第三方署名（Hydro-Br-leur、
> USB_SampleRate_Changer_WebUI）在此保留，属于我应当继承的署名。

### USB Samplerate Unlocker ★ 第二层的来源

仓库：`yzyhk904/usb-samplerate-unlocker`（另有 `geoffferygree`、`SNiTEBoBy` 等镜像，同源）

**本项目的第二层几乎完全建立在它的工作之上**，具体采纳了：

- **核心结论**：`libalsautils{,v2}.so` 里那张 `std_sample_rates[]` 的第一项就是 HAL 对外宣称的上限，
  重排它即可解锁 —— 本项目第 1.2 节整节讲的就是这件事
- **四张表的数值**：本模块 `payload/patch_hal.sh` 里的工厂 / 192k / 384k / 768k 四行常量，
  取自它的替换规则（13 项 uint32，52 字节）
- **AOSP 出处**：它 README 指出的 `system/media/alsa_utils/alsa_device_profile.c`
- **两条设计约束**（来自它的 changelog）：
  - 32 位 arm 设备上「凭空造出 lib64 覆盖层」会导致爆音 → 本项目因此**只补丁已存在的文件，绝不创建覆盖层**
  - Android 12 上 `ro.audio.usb.period_us` 的 SELinux 坑
- **厂商差异**（USB 硬件 offload：Qcomm 到 384k，MTK 与 Tensor 只有 96k）→ 写进了本项目的「已知边界」

**实现上的差异**：它用 `hexdump` 出十六进制再回写成二进制、通过模块覆盖层交付；
本项目改用 `od -An -v -tu1` + 单遍字节匹配**定位**，原位覆盖，并把「52 字节等长 + ELF 头不变 +
原表消失 / 新表唯一 + 回读一致」当成**必须复核的性质**，把「表出现 0 次或 2 次以上」分别做成
「跳过」和「拒绝」，交付方式也改成运行时的绑定挂载。

### Hydro-Br-leur —— 《一加 13T / ColorOS 16 解锁 192 kHz USB 独占模块》

经由本人的 op13 模块继承。采纳：**systemless 绑定挂载音频策略文件**这一整体架构
（以及「策略基线取本机原厂文件」的原则）。

### USB_SampleRate_Changer_WebUI

经由本人的 op13 模块继承。采纳：WebUI 交互形态与 USB DAC 探测（读 `/proc/asound` 判断能力）的思路。

### Android AOSP（官方文档与源码）

- `system/media/alsa_utils/alsa_device_profile.c` —— `std_sample_rates[]` 表内容的权威出处，
  也是本项目用来**反向核对**表是否正确的依据
- `frameworks/av/services/audiopolicy/config/` —— 策略 XML 结构，以及
  `usb_ / a2dp_ / r_submix_ / bluetooth_*_audio_policy_configuration.xml` 的 `<xi:include>` 分工
  （被包含文件的根元素是**裸 `<module>`**，且规范禁止嵌套 include）——
  本项目扫描器的 include 解析就是照这个规范写的
- 官方文档 *Configure audio policies*

### Magisk / KernelSU / APatch

模块框架与生命周期约定（`module.prop`、`post-fs-data.sh` / `service.sh` / `action.sh`、
WebUI 桥接、以及用 `nsenter -t 1 -m` 进入全局挂载命名空间）。

### 明确没有采纳的

除上述以外，没有采纳任何第三方模块的代码、常量或结构。
本项目的**扫描器**（多路径 + `xi:include` 跟随 + 去重）、**方言自动识别**、
两套**规则化 awk 改写 / 校验器**、`patch_hal.sh`、以及全部离线测试与夹具，
都是在本项目里新写的；op13 原先的「模板 + `@TOKEN@` 占位符」方案已被规则化改写取代。
