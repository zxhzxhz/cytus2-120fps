# Cytus2-120FPS（Unity 高刷新率 tweak）

把 Unity 游戏（Cytus II）在 iPhone ProMotion / iPad 上的帧率从 60 强制拉到 **120fps**。
支持 **LiveContainer（ElleKit / rootless 越狱）** 和直接装在越狱设备上的游戏本体。

> 原理与完整逆向分析见 `../docs/01-refresh-rate-analysis.md`。
> 一句话：iOS 上 Unity 的帧率完全由 `CADisplayLink` 的 preferred rate 决定，
> 而 Cytus II 的 `Rayark.Cytus2.FrameRateAdjuster` 把默认值硬编码成 60。

---

## 1. 这个 tweak 做了什么

| 动作 | 说明 |
|---|---|
| hook `-[UnityAppController callbackFramerateChange:]` | 忽略游戏传入的帧率，改成 120（默认忽略屏幕上限，见下） |
| hook `-[CADisplayLink setPreferredFramesPerSecond:]` / `setPreferredFrameRateRange:` | 保险：只对 Unity 自己那个 display link 生效 |
| il2cpp API 同步 | 调用 `UnityEngine.Application.set_targetFrameRate(120)`，让引擎内部状态一致（不依赖任何硬编码地址） |
| 诊断日志 | 每秒记录真实渲染 FPS + 环境信息到 `Documents/120fps.log` |
| info dict 补丁 | 尝试在内存中把 `CADisableMinimumFrameDurationOnPhone` 设为 true（iPhone 开 120Hz 的系统闸门） |

关键宏（`Tweak.mm` 顶部）：`NPL_TARGET_FPS`(120)、`NPL_IGNORE_SCREEN_MAX`(默认 1，即使系统报告 60 也请求 120，
60Hz 设备会被系统自己夹回，无副作用)、`NPL_SYNC_ENGINE_FPS`(1)、`NPL_MODIFY_ON_DISK_PLIST`(0，需写盘时打开)、
`NPL_ONLY_BUNDLEID`(默认空=所有 Unity 游戏)。

不依赖 `libsubstrate`（直接用 ObjC runtime 换 IMP），
所以 **ElleKit 注入**和 **LiveContainer 自带 TweakLoader** 两种方式都能加载。

---

## 2. 编译

这个仓库的根目录就是 Theos 工程（`Makefile` / `Tweak.mm` / `control` / `Cytus2120FPS.plist`），
`.github/workflows/build.yml` 会在每次 push 时自动出包。

### 方式 A：GitHub Actions（已配置好，Windows 用户推荐）

push 之后到 Actions → Build Tweak → 跑完在 Artifacts 里下载 `cytus2-120fps`：

- `com.zxhzx.cytus2-120fps_1.0.0_iphoneos-arm64.deb` —— 越狱安装用（rootless，装到 `/var/jb/...`）
- `Cytus2120FPS.dylib` —— LiveContainer 的 tweak 文件夹用

### 方式 B：macOS / Linux + Theos

```bash
export THEOS=~/theos        # 已安装 Theos 和 iOS SDK
make package FINALPACKAGE=1 THEOS_PACKAGE_SCHEME=rootless
# 产物: packages/*.deb
# 裸 dylib: .theos/obj/arm64/Cytus2120FPS.dylib
```

> Windows 上可以装 WSL，然后在 Ubuntu 里按 Theos 的 Linux 步骤安装（需要 iOS SDK）。

---

## 3. 安装

### LiveContainer + 越狱（ElleKit, rootless）

- **方法 1（推荐）**：把 `Cytus2120FPS.dylib` 放进 LiveContainer 里给 Cytus II 配置的
  **Tweak Folder**（LiveContainer → 长按 app → Settings → Tweak Folder）。
  这样只影响这一个游戏，最干净。
- **方法 2**：`dpkg -i` 安装 deb（装到 `/var/jb/Library/MobileSubstrate/DynamicLibraries/`），
  过滤器覆盖 `LiveProcess` / `LiveContainer` / `CytusII`。
  注意：ElleKit 是否注入到 LiveProcess（XPC app extension）取决于越狱环境，
  如果没生效就用方法 1。

### 越狱设备上的游戏本体

`dpkg -i` 安装 deb 即可（过滤器匹配 `CytusII` 可执行文件）。

---

## 4. 验证

启动游戏、进一首歌，然后看日志（LiveContainer 的 File Browser 进游戏的 **Data Container →
Documents → 120fps.log**，或者用 Console.app 搜 `Cytus2-120FPS`）。

期望看到：

```
=========== Cytus2-120FPS 载入 ===========
device=iPhone15,3  ios=17.5.1  process=CytusII
mainBundle=com.rayark.cytus2
maximumFramesPerSecond=120  target=120  ->  want=120
CADisableMinimumFrameDurationOnPhone = (missing)
已安装 4 个 hook（UnityAppController=0x...）
il2cpp: 已解析 Application.set_targetFrameRate = 0x...
callbackFramerateChange: 游戏请求 60 → 强制 120（屏幕上限 120, displayLink=0x...）
il2cpp: Application.targetFrameRate 已同步为 120
FPS ≈ 119 link(fps=120, paused=0)
```

关键看两行：

- `maximumFramesPerSecond=` **120** → 系统闸门已开，只剩 Unity 的 60 限制，tweak 应该直接生效。
- `maximumFramesPerSecond=` **60** → 系统层锁死（`CADisableMinimumFrameDurationOnPhone` 没生效），
  需要额外处理（见下面「排查」）。
- `FPS ≈ 119` → 实际渲染帧率（如果只有 ~60，把日志发我）。

---

## 5. 排查

| 现象 | 原因 / 处理 |
|---|---|
| 没有日志、也没有 `已安装 hook` | tweak 没被加载：检查 dylib 路径 / ElleKit 过滤器 / LiveContainer 的 tweak 文件夹 |
| `maximumFramesPerSecond=60`（设备确实是 ProMotion） | 系统闸门没开：主 bundle Info.plist 的 `CADisableMinimumFrameDurationOnPhone` 是 false。LiveContainer 会把 `CFBundleGetMainBundle()` 重定向到 guest app 的 bundle（`CytusII.app/Info.plist`，该键为 false）。把 Tweak.mm 里的 `NPL_MODIFY_ON_DISK_PLIST` 改成 `1` 重新编译安装（会破坏签名，TrollStore 环境没问题），或者在 Filza 里手动往 guest 的 Info.plist 加这个键 |
| `FPS ≈ 60` 但 `maximumFramesPerSecond=120` | 把日志发我，需要进一步分析 |
| 游戏设置里想手动对比 | 本版本（5.2.18）设置界面里**没有** FPS 选项（代码还在，但 UI 没显示），所以只能靠这个 tweak |
| iPad Pro | `CADisableMinimumFrameDurationOnPhone` 只在 iPhone 上生效，iPad 忽略该键 → iPad 上不存在系统闸门，`maximumFramesPerSecond` 应该直接是 120 |

---

## 6. 已知限制

- 强制 120fps 会让设备更热、更耗电；节奏游戏的判定用的是音频时钟（不是帧数），
  但手感/视觉变化请自行确认。
- 过滤器默认对所有 Unity 游戏生效（LiveProcess 是通用宿主）。
  想只对 Cytus II 生效：把 `Tweak.mm` 里的 `NPL_ONLY_BUNDLEID` 改成 `@"com.rayark.cytus2"`。

---

## 更新记录

### v1.1（修复启动闪退）

v1.0 在 iPad Pro M4 / iPadOS 18.6.2 / LiveContainer 3.8.9 上会导致游戏闪退。v1.1 的处理：

| 改动 | 原因 |
|---|---|
| `NPL_SYNC_ENGINE_FPS` 默认 **0**（关闭 il2cpp 同步） | 从「引擎自己的帧率通知」里再调 `Application.set_targetFrameRate` 会重入引擎的 SetTargetFramerate（很可能重复获取同一把锁）；而且渲染节拍由 display link 决定，这个同步本来就多余 |
| `NPL_PATCH_INFOPLIST` 默认 **0**（不再改 CFBundle 内存字典） | 真机日志已确认 iPad 上 `maximumFramesPerSecond=120`，该键在 iPad 上被忽略，完全不需要动它 |
| `NPL_HOOK_CADISPLAYLINK` 默认 **0**（不再 swizzle CADisplayLink） | 已用 xref 验证 `setPreferredFramesPerSecond:`/`setPreferredFrameRateRange:` 全二进制只在 `callbackFramerateChange:` 一处被调用，不必碰系统类 |
| hook 仅在**主线程**安装 | v1.0 在后台队列里 swizzle，可能与主线程的引擎启动竞争 |
| 日志改为**同步写盘** + 信号/异常处理器 | v1.0 是 async 日志，崩溃前几行会丢；现在崩溃会把信号 + 回溯写进同一个 `120fps.log` |
| 一键禁用开关 `Documents/120fps.disable` | 放一个空文件即可让 tweak 完全跳过（用于确认闪退是否由 tweak 引起） |

### v1.0

初版。
