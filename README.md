# HiFi SRC Bypass v2.0.0 — Smart PA 功率层 · 全机型适配

> 全机型通用的 Android 音频模块：USB 小尾巴 / 有线耳机高解析直通（SRC 绕过）。
> v2.0.0 在 v1.9.2 基础上新增 **Smart PA 功率层（实验 · 多品牌适配）**，
> 并为全部档位补齐「超越原厂 / 操作路径 / 防负优化」三段式指引。
> 原厂文件零改写（systemless 绑定挂载），一键还原、卸载自动清理。

## 测试设备

| 设备 | 官方名称 | 系统 | 方言 |
|---|---|---|---|
| 一加 13 | **OnePlus 13（一加 13）** | Android 16（ColorOS16） | QTI AIDL |
| 红米 K20 Pro | **Redmi K20 Pro（红米 K20 Pro）** | Android 16 移植澎湃 OS（HyperOS 3） | QTI HIDL |

**测试小尾巴（USB DAC 线）**：CX31993（Conexant）+ MAX97220（Maxim）方案小尾巴、MOONDROP FreeDSP Mini 小尾巴

**测试耳机**：MOONDROP Aria 2（咏叹调 2）真红限定版、MOONDROP 竹 III（CHU III）

---

## 版本亮点

### 🔊 Smart PA 功率层（实验）
- `hifi pa` / `pa status`：读取 smart PA 型号（TFA9874 等）、增益、boost 档、VI 反馈、保护算法状态
- `hifi pa gain 0..6|reset`：外放 PA 增益逐档调节（+1dB 起步，每档听够 24h 再加）
- `hifi pa boost 1|2|reset`：升压上限档
- `hifi pa vi on|off`：电压电流回读开关（数据口 `/dev/tfa_rw`，需自行解析 DSP 帧）
- `PA_GAIN=` / `PA_BOOST=` 写入 config.conf，`hifi apply` 时带警示注入
- **WebUI「Smart PA 功率」卡片**：红色警示边框 + 风险文案（功率超限可造成不可逆硬件损伤），7 档 pill + 二次确认
- **硬编码拒绝**：ALGO_STATUS(3178) / SmartPA Mute(3175) / Calibration(3177) / TFA Stop(3176) / Profile 换挡 —— 永不提供
- 仅运行时 tinymix 读写，零文件改动；兼容新旧两代 tinymix 语法（旧版 BOOL 只收数字写入）

### 🛡️ 开机安全网 P0（真机熔断测试后的热修）
- `service.sh` 全部 11 处控制器调用（apply / restore / missing / set / report）统一包 `hifi_t` 超时包装（probe/set 10s、apply/restore 30s），冲突模块把控制器拖挂时不再逐处各卡 90s
- `post-fs-data.sh` 尾部 report 调用同样包 15s 超时
- K20 Pro 真机实测：三层熔断（boot 超时 / 不健康卸载 / 连续两次自动禁用）+ 恢复路径全部按设计工作；最坏情况只是多等约 2 分钟开机 + 补丁未生效，不卡死引导

### 🖼️ WebUI 背景图系统
- **固定背景层**：背景图铺满视口、不随页面滚动移动，卡片浮于其上
- **默认背景**：「誓死效忠水月吉米」开箱即生效
- **6 槽预设**：3 个内置（誓死效忠水月吉米 / 誓死效忠水月雨 / 誓死效忠天使吉米，均可重命名）+ 3 个自定义槽（从相册选图）
- **相册式裁切编辑器**：固定裁切框（9:19.5 / 9:16 / 3:4 / 1:1 / 自适应本机实测视口），框内即最终背景（所见即所得），单指拖动 + 双指/滚轮缩放，框外遮罩变暗，只导出框内像素
- **面板透明度滑杆**（默认 50%）：背景开启时卡片半透明、文字恒不透明，0–100% 自主调节
- **无损优先**：默认 PNG 无损导出、不自动缩放；仅超 2.5MB 存储预算才提示后单次降采样；JPEG 原图保持 q0.92
- 设置持久化于 localStorage，覆盖安装/重启后保留

### 🩺 自检 doctor 增强
- 深度校验 `[1]–[7]`：新增 ⑥ DSP 位宽注入状态、⑦ P0 开机安全网（bootmode / bootfail 熔断计数 / boot_degraded 标记）
- 机型适配校验 `[8]–[9]`：逐策略文件补丁结论 + 厂商 DSP（杜比类）检测

### 📝 WebUI 档位指引重写
- 五个档位（混音率 / HiFi 通道率 / 扬声器档位 / DSP 位宽 / 扬声器一键优化）hint 均为三段式：
  - **超越原厂**：原厂做不到什么、本档位超越点在哪
  - **操作**：怎么达成 + 用「深度校验」哪一段确认达成
  - **防负优化**：什么场景会变差 + 回退基准（147:160 非整数重采样等机制事实）

---

## 真机测试记录

### 一加 13（OnePlus 13 · QTI AIDL · Android 16）

- 覆盖安装 + 重启自愈：策略 **10/10** + **4/4 HAL** 全部解锁并挂载生效
- 档位切换全回归：混音率 / HiFi 通道率 / 上限 / 位深 / 扬声器档位 / 扬声器位深 / DSP 位宽逐档切换 + 非法值拒绝，全部生效并正确落盘
- `hifi preset 384k` / `preset auto`（无 DAC 优雅降级）/ `hifi scan` 回归通过
- `hifi restore` 一键还原正常
- `hifi doctor` 退出码 **rc=0**

### 红米 K20 Pro（Redmi K20 Pro · QTI HIDL · Android 16 移植澎湃 OS HyperOS）

- **三层熔断测试全过**：boot 挂死超时自保、audioserver 不健康立即卸载、连续两次不健康自动禁用（`BOOTFAIL-CIRCUIT-BREAK`）
- **恢复路径验证**：健康开机后自动清计数 / 清标记 / 恢复挂载，ENABLED=1、audioserver running
- **PA 失败路径正确**：Smart PA 控件不存在 / 写入失败时明确报错，不假装成功
- **WebUI 透明度跟随修复**：面板透明度滑杆与 Smart PA 卡片状态联动交互已修复（commit `82bafef`）

---

## 已知限制（如实）

- **Smart PA 增益档位按后端能力分**：TFA9874 / Qualcomm WSA883x-884x 机型可调（gain/vi），awinic / Cirrus / MTK 等后端只读（档位未映射，回传 `hifi adapt` 协助适配）
- **每侧独立档位受 ROM 控件层限制**：ROM 只给一套对称音量入口时无法实现（如一加 13），等值联动已覆盖该形态
- **restore 在一加 13 上若提示 partially active 属旧版显示层残留**（本版已加 lazy-umount 兜底修复），功能已还原
- Smart PA 为实验功能，保持出厂 0 档最安全（功率超限可造成不可逆硬件损伤）
- HarmonyOS NEXT 平台不兼容（policy 为二进制非 XML）

---

## 下载与安装

- 下载：[GitHub Release v2.0.0](https://github.com/lizi600jin/hifi-src-bypass/releases/tag/v2.0.0) · `dist/hifi-src-bypass-v2.0.0.zip`
- **KernelSU / Magisk / APatch 通用**：管理器 → 从本地安装 → 选择 zip → 重启
- **覆盖安装保留原 `config.conf`**，已有档位设置自动延续
- 安装后打开模块页 **WebUI**（KernelSU / APatch 支持；Magisk 用操作按钮或终端）
- 安装脚本会报告本机实际有什么（策略文件、USB HAL 库、DAC），不做任何假定；如遇卡屏可进安全模式删除模块

---

## 稳定线 v1.9.2（同 tag 发布，保守推荐）

基于 main 全部 bug 修复，**不含** Smart PA 实验层。
包含 **P0 开机安全网**（冲突模块自动退场）、探测扩展（SmartPA / USB offload 判定）、
`spkdsp` 扬声器 ADSP 位宽强制、报告 HAL 状态词人话解码、WebUI 背景图系统。
适合只要 **SRC 绕过 + 位深补齐** 的保守用户。

---

*发布物：`hifi-src-bypass-v2.0.0.zip`（versionCode 200）· 完整变更与验证记录见项目仓库*

---

### 🔊 Smart PA 全面适配（一加13 真机诊断驱动）
- **PA 后端注册表**（运行时按控件名探测，不写死控件号）：
  | 后端 | 芯片族 | 覆盖机型 | 能力 |
  |---|---|---|---|
  | tfa | NXP TFA9874 | K20 Pro 等老旗舰 | gain / boost / vi 全功能 |
  | wsa | Qualcomm WSA883x/884x | 一加13、小米/三星 2023+ 旗舰 | gain / vi（boost 由固件管理），**多芯片立体声等值联动** |
  | awinic | 艾为 | 红米/小米中低端、荣耀 | 只读（档位未映射） |
  | cirrus | Cirrus Logic CS35Lxx | 小米/一加部分旗舰 | 只读 |
  | mtk | 联发科 SmartPA | 天玑机型 | 只读 |
- **只读后端不盲写**：status 如实展示原值并提示回传 `hifi adapt` 协助适配；未识别 PA 统一降级不误报
- **`hifi adapt` 新增 PA 快照段**：社区用户整段回传即可为新机型补映射
- **真机兼容四轮加固**（一加13 实测驱动）：tfa 探测语义校验（控件名+枚举值双条件）、tinymix dump 双方言解析（厂商 4 字段 / 传统 3 字段）、单控件回读冒号格式（`NAME: VALUE`）取值、回读尾注箭头（`0->124`）不再误截断——最终真机全链：status 84 出厂值 → gain 2 → 80 → reset → 84
- **WSA 多实例**：单扬 / 单芯片双通道 / 多芯片立体声（WSA_ + WSA2_ 多前缀）同一套代码，gain 对**全部实例等值联动写入** + 逐个回读校验，声像平衡不变
- **不对称双扬并非不可用**：PA 调节入口是 ROM 暴露的数字音量控件——只要机型把各扬声器通道映射到 mixer 控件（绝大多数机型如此，含一加 13 的 1012+1115E 异形单元组合），等值联动即可正常启用（同档偏移不改出厂左右/上下差异）。仅当 ROM 不暴露可写音量控件时才降级只读。**每侧独立档位**仅受 ROM 控件层限制——ROM 只给一套对称入口时（如一加 13）无法实现，属系统层边界而非模块不作为；注册表架构已就绪，ROM 暴露多套入口的机型出现即可支持

### 🖼️ WebUI 裁切编辑器修复
- **修复拖动被钉死 + 缩放只朝右下角**：`bgClamp()` 平移夹紧区间倒挂（图片恒被钉在右下对齐），已改为逐轴有序区间夹紧——单指自由拖动、双指/滚轮以触点为不动点缩放全部恢复正常
- 附带加固：双指捏合中抬起一指后，剩余手指重新锚定，不再跳变
- **PA 档位切换结果弹窗**：与采样率切换同款 toast——成功弹「PA 增益已切到 N 档（≈ +N dB），扬声器已生效」/「已恢复出厂」，不支持或失败弹「⚠️ + 具体原因（可回传 `hifi adapt` 协助适配）」

### 🔧 restore 完整卸载
- 修复 busy 文件（被 audioserver mmap）导致的补丁挂载残留：普通 umount 失败后自动 lazy umount 兜底，一加13 实测 restore 后零残留
