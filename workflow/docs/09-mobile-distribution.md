# 09 · 移动端发布（Android / iOS）

> 决策背景：Steam 是 **$100/款**；iOS 年费已有账号；Android 技术与成本都低。
> 所以本阶段的主渠道改为 **Android + iOS 应用商店**（见
> [`08-platform-and-market-research.md`](08-platform-and-market-research.md) 的费用与竞品调研）。
>
> 本文是**可执行清单**：每条命令都能直接跑，每个「需要你操作」的地方都标了。

---

## 0. 现状：工程侧已经就绪的部分

| 项 | 状态 |
|---|---|
| 触屏操作（D-pad + 滑动映射 + 手势提示） | ✅ 早就做了（超范围完成） |
| 安全区域（刘海 / 灵动岛 / 底部手势条） | ✅ Web 用 `env()`，原生用 `DisplayServer.get_display_safe_area()` |
| 横竖屏自适应（不锁方向） | ✅ `handheld/orientation=6`，UI 分辨率无关 |
| 应用图标 1024×1024 | ✅ `icon.png`（`tools/make_store_assets.gd` 生成，配色取 `game.gd`） |
| 商店素材（512 图标 / 1024×500 特色图） | ✅ `store_icon_512.png`、`store_feature_1024x500.png` |
| 返回键 / 返回手势 | ✅ 层级式返回（见 §4），不是「一键退出」 |
| 切后台 / 恢复 | ✅ 清掉自适应画质采样，避免回来后画质被一次打到底 |
| 导出预设 | ✅ Android (AAB)、Android (APK)、iOS 三个预设已写好 |
| 守卫测试 | ✅ `tests/test_mobile.gd`（42 断言）：商店格式、包名一致性、素材尺寸 |
| Android 构建 | ✅ **已跑通**（APK 55MB 装真机/模拟器；AAB 51MB 可上架，签名已用 `jarsigner` 验证） |
| iOS 构建 | ⏳ **必须有 macOS**（本文 §2） |
| 上架素材与商店后台 | ⏳ 需要你操作（本文 §3） |
| 内容量（20 关 vs 竞品 200 关） | ⚠️ **上架前要扩**（本文 §5） |

---

## 1. Android：现在就能出（只差 SDK/JDK）

### 1.1 装 JDK 17 与 Android SDK（一次）

```bash
sudo apt install -y openjdk-17-jdk unzip
# cmdline-tools（约 130MB），装到 ~/android-sdk
mkdir -p ~/android-sdk/cmdline-tools && cd ~/android-sdk/cmdline-tools
curl -LO https://dl.google.com/android/repository/commandlinetools-linux-11076708_latest.zip
unzip -q commandlinetools-linux-*.zip && mv cmdline-tools latest && rm *.zip
export ANDROID_SDK_ROOT="$HOME/android-sdk"
yes | "$ANDROID_SDK_ROOT/cmdline-tools/latest/bin/sdkmanager" --licenses >/dev/null
"$ANDROID_SDK_ROOT/cmdline-tools/latest/bin/sdkmanager" "platform-tools" "build-tools;34.0.0" "platforms;android-34"
```

### 1.2 告诉 Godot 路径（它只认编辑器设置，不读环境变量）

```bash
workflow/scripts/gf-android-env.sh ~/android-sdk /usr/lib/jvm/java-17-openjdk-amd64
```

> 这个脚本会自动备份原设置、幂等写入两个键。**不要手改** ——
> 写坏 `editor_settings-4.tres` 会让编辑器启动异常。

### 1.3 AAB 需要 Gradle 构建模板（一次）

```bash
workflow/godot-bin/godot --headless --path games/puzzle-core --install-android-build-template
```

会在工程里生成 `android/build/`（已加进 `.gitignore`，不要提交）。

### 1.4 生成**发布签名**（一次，且必须永久保存）

```bash
keytool -genkeypair -v -keystore puzzle-core-release.keystore \
  -alias puzzlecore -keyalg RSA -keysize 2048 -validity 10000 \
  -storepass '<你的口令>' -keypass '<你的口令>' \
  -dname "CN=EasyIndie, OU=Games, O=EasyIndie, L=, S=, C=CN"
```

然后把路径与口令填进 `export_presets.cfg` 的 `keystore/release*` 三项
（或用 CI secrets，见 §6）。

> ⚠️ **keystore 丢失 = 这个应用再也无法更新**（Google Play 只接受同一签名的新版本；
> Play App Signing 可以缓解但不能完全免掉）。至少备份两处，且**不要提交进仓库**。

### 1.5 出包

```bash
# 本机试玩（debug 签名，可直接 adb install）
workflow/scripts/gf-export.sh games/puzzle-core android-apk

# 上架用（AAB，release 签名）
workflow/scripts/gf-export.sh games/puzzle-core android
```

`gf-export.sh` 会在动手前做前置检查（SDK 路径、构建模板），
缺什么就直接告诉你补哪一条命令 —— 而不是让你在导出中途看一句天书。

---

### 1.6 实测结果（本机已跑通，2026-10）

```
build/android/puzzle-core.apk   55MB   ABI: arm64-v8a + x86_64     签名: debug（CN=Godot）
build/android/puzzle-core.aab   51MB   ABI: arm64-v8a + armeabi-v7a 签名: jar verified ✓
包名 com.easyindie.puzzlecore · versionCode=1 · versionName=0.1.0 · minSdk=24 · targetSdk=36
应用名 Puzzle Core · 权限: 无 · screenOrientation=13（fullUser，横竖屏都允许）
```

装到手机上试玩：

```bash
adb install -r games/puzzle-core/build/android/puzzle-core.apk
# 或者直接把 build/android/puzzle-core.apk 拷到手机点开安装（需允许“未知来源”）
```

核验成品（包名一致性 / 64 位 / 图标 / 权限 / 方向 / 签名）——**导出成功不等于能上架**，所以这条要单独跑：

```bash
workflow/scripts/gf-android-verify.sh            # 自动挑 build/android 下的产物
workflow/scripts/gf-android-verify.sh <包路径>
```

### 1.7 实测踩到的四个坑（都已修，别再踩）

| 坑 | 症状 | 结论 |
|---|---|---|
| `--install-android-build-template` 单独用 | 毫无输出、也不生成 `android/`，退出码 0 | 它是**编辑器**开关，必须与导出一起用：`--headless --editor --install-android-build-template --export-release "Android (AAB)" …` |
| **缺 ETC2/ASTC 设置** | 导出直接被拒：`ETC2/ASTC texture compression is required for Android export` | 必须开 `rendering/textures/vram_compression/import_etc2_astc=true`（已写进 project.godot，并有测试守着） |
| **ABI 没显式声明** | 出包只有 `arm64-v8a`（模板里其实有 4 个 ABI） | Godot 读的是预设里的 `architectures/<abi>` 键，**必须显式写**；上架包给 arm64+armv7，试玩包给 arm64+x86_64 |
| 编辑器设置文件名写死 | 明明配好了却报「没有配置 Android SDK」 | 文件名是**版本化**的（`editor_settings-4.7.tres`），要 glob 找最新的那个（`gf-export.sh` 已修） |

另外两条经验：
- `aapt2 dump badging` 里 minSdk 那行**两种拼写**都出现过（`sdkVersion:'24'` / `minSdkVersion:'24'`），
  只匹配一种会静默取到空值 —— `gf-android-verify.sh` 现在两种都接受。
- **AAB 不需要你手工做任何签名工作**（Play App Signing 会托管最终签名），
  但上传包必须用你的 key 签过 —— `jarsigner -verify` 能验（看到 `jar verified.` 即可）。

## 2. iOS：**必须有 macOS**（技术上绕不过）

Godot 官方文档原话：

> "**You must export for iOS from a computer running macOS with Xcode installed.**"

我们的预设已经写好并在 Linux 上通过校验（`gf-export.sh games/puzzle-core ios` 在非 macOS 上会明确拒绝，
而不是产出一个装不上的包）。三条可行路径：

| 方案 | 成本 | 适合 |
|---|---|---|
| 一台 Mac（哪怕是旧 Mac mini） | 硬件成本 | 长期做 iOS，最省心 |
| **GitHub Actions 的 `macos-latest` runner** | **公开仓库免费** | 我们仓库已是 public → 首选（见 §6） |
| 云 Mac（MacinCloud / MacStadium / AWS EC2 mac） | 按小时/按月 | 偶尔构建 |

在 macOS 上要做的（一次性）：

1. 装 Xcode（含 command line tools）+ Godot 4.7.2（macOS 版）+ 导出模板
2. 在 `export_presets.cfg` 里填 `application/app_store_team_id`（Apple Developer 的 10 位 Team ID）
3. 确保 App ID 已在 Apple Developer 后台注册（bundle id = `com.easyindie.puzzlecore`）
4. 签名用 Xcode 的自动管理（Godot 导出时留空 code sign identity / provisioning 即可）
5. `workflow/scripts/gf-export.sh games/puzzle-core ios` → 产出 `.ipa`
6. 用 Transporter / `xcrun altool` / Xcode 上传到 App Store Connect → TestFlight 内测

---

## 3. 商店后台清单（**需要你操作**）

### Google Play（`Play Console`）

| 项 | 说明 |
|---|---|
| 注册费 | **$25 一次性** |
| 新个人账号门槛 | **封闭测试 ≥12 名测试者、连续 ≥14 天** 才能申请上架（2023-11-13 后注册的账号） |
| 商店页图标 | `workflow/store/…store_icon_512.png` → 上传 512×512 |
| 特色图片 | `store_feature_1024x500.png` → 上传 1024×500 |
| 截图 | 手机截图至少 2 张（建议 4~8 张）。用 `workflow/scripts/gf-shot.sh` 出图，覆盖：第 1 关、难度高的关、选关界面、庆祝界面 |
| 隐私政策 URL | 无联网、无账号、只存本机进度 → 一页静态说明即可（可放在 Pages 上） |
| 数据安全表单 | 声明「不收集数据」（我们只写 `user://progress.json` 本机文件） |
| 内容分级 | 填 IARC 问卷（本作无暴力/无用户内容 → 通常全年龄） |
| 广告声明 | 无广告（除非后续接广告 SDK） |
| 目标 API 级别 | Play 会要求较新的 targetSdk（用 Godot 默认值通常够；不够就在预设里显式填 `gradle_build/target_sdk`） |

### Apple App Store（`App Store Connect`）

| 项 | 说明 |
|---|---|
| Bundle ID | `com.easyindie.puzzlecore`（必须先注册 App ID） |
| App 图标 | 1024×1024（Godot 会从 `icon.png` 生成各尺寸） |
| 截图 | 6.7" 与 6.5" 为必填（横竖屏都可，我们支持双向） |
| 隐私 | 「不收集数据」；`privacy/*` 那些键全留空即可 |
| 年龄分级 | 4+（无暴力/无用户内容） |
| 定价 | 见 §5 的变现建议 |

---

## 4. 移动端行为约定（已实现，改动前先看这里）

**返回键 / 返回手势**（`main.gd::back_action()`，纯判断 + 副作用分离，便于测试）：

| 当前状态 | 返回键做什么 |
|---|---|
| 庆祝层打开 | 关闭庆祝层 |
| 选关界面打开 | **退出游戏**（选关 = 本作主页，这里才是「退出」的语义位置） |
| 回放中 | 停止回放并复位到关卡起点 |
| 对局中（含通关/坠落动画） | 打开选关界面 |
| 过渡动画中 | 忽略 |

> 关键：`project.godot` 里 `application/config/quit_on_go_back=false`。
> 默认值 `true` 会让引擎**直接退出** —— 玩家看到的就是「按一下返回 = 闪退」。

**切后台 / 恢复**：清空自适应画质的采样累加器。不清的话，回来第一帧的 `delta` 可能是几百毫秒，
平均帧时间一次超标 → 画质档位直接被打到底（弱机型尤其明显）。

**屏幕方向**：`6`（传感器，横竖屏都允许）。理由是 UI 分辨率无关且触屏控件会重排，
锁方向只会白白丢掉一半使用场景。

**图标**：`tools/make_store_assets.gd` 生成，**不要手工 P 图** —— 它直接引用
`game.gd` 的配色常量，改了游戏配色重跑脚本即可保持一套色。

```bash
DISPLAY=:0 workflow/scripts/gf-run.sh -p games/puzzle-core res://tools/make_store_assets.gd
```

---

## 4b. 电视（Android TV / Google TV / 电视盒子）

**结论：能玩，而且大部分是现成的** —— 但有两类工作必须补，否则电视玩家会卡死或看不清。

### 4b.1 已经就绪的部分

| 项 | 为什么本来就对 |
|---|---|
| 不显示触屏控件 | 判定是 `DisplayServer.is_touchscreen_available()`，电视没有触摸屏 → 触屏层自动不显示（**不是**按平台名判断的） |
| 方向键移动 | 遥控器方向键在 Android 上被 Godot 上报成普通按键（`KEY_UP/DOWN/LEFT/RIGHT`），与键盘同一路径 |
| 选关界面导航 | 它用的是 Godot 内置焦点系统（`grab_focus()` + Button 默认 `ui_accept`），`ui_*` 默认就含手柄 D-pad 与 A 键 |

### 4b.2 这次补的部分

1. **手柄 / 遥控器的三种上报形式都要走通**（`game.gd::event_to_dir`）：
   - 键盘按键（遥控器方向键）✓
   - `InputEventJoypadButton` 的 D-pad（部分遥控器/蓝牙手柄）
   - 左摇杆：**只在越过阈值那一刻**触发一次（直接按阈值判断会「一推走好几格」——轴事件每帧都来）
2. **确认键必须是上下文相关的**（`main.gd::primary_action()`）——这是电视能不能玩下去的关键：
   遥控器上没有 `R` 键，**不处理的话掉下去就卡死了**。
   | 状态 | 确认键（遥控器 OK / Enter / 手柄 A） |
   |---|---|
   | 已坠落 | 重开 |
   | 已通关 | 下一关 |
   | 回放中 | 停止回放 |
   | 其余 | 什么都不做（刻意的：对局中弹选关太意外，选关有专门入口） |
3. **庆祝层的按钮改为可聚焦 + 打开时给初始焦点**：原来写的是 `FOCUS_NONE`，
   在电视上那就是一个「按什么都没反应」的死界面。
4. **过扫描（overscan）兜底**：电视会裁掉四周约 5%，而系统安全区在电视上通常报 0
   → `UiLayout.apply_tv_floor()` 给每边一个「短边 5%」的下限。
5. **10 尺 UI 缩放**：电视观看距离是手机的十倍，4K 电视上按像素等比会让字小到看不清。
   用 `Window.content_scale_factor` 整体放大（1080p ×1.15 / 4K ×1.45），
   3D 仍按原生分辨率渲染（棋盘不会变形），HUD/选关/庆祝层一起变大。
6. **电视首页入口**：AAB 预设开启 `package/show_in_android_tv=true`（leanback 启动器），
   否则电视上根本找不到这个应用。

### 4b.3 怎么在显示器上预览电视布局

桌面二进制的 `OS.has_feature("mobile")` 永远为假，所以给了显式开关（也是截图测试用的手段）：

```bash
GF_FORCE_TV=1 DISPLAY=:0 workflow/godot-bin/godot --path games/puzzle-core --resolution 1920x1080
```

### 4b.4 电视渠道还需要你操作的部分

- Play Console 里勾选 **Android TV** 表单（并按它的要求补 TV 截图 1920×1080）
- 商店页的 **TV banner 320×180**：已生成 `store_tv_banner_320x180.png`（Play 的 TV 商店页要用）
- 注意：**Godot 不会把 banner 打进 APK**（Android 导出没有 banner 选项），
  所以电视首页上显示的是**应用图标**。要换成真正的电视 banner，需要在 Gradle 构建里加
  `res/drawable-xhdpi/banner.png` 与 `android:banner` 属性（属于自定义构建范畴，暂未做）
- 电视盒子芯片普遍偏弱 → 我们的自适应画质会自动降档（`render_quality.gd`）；
  如果某些盒子连最低档都卡，用 `?lite=1` 的等价物：目前原生侧没有 URL，需要时可以加环境变量开关

### 4b.5 明确没做的（别以为是 bug）

- 遥控器的**长按/双击**语义（本项目都是单次按键）
- 电视上的**多人/手柄热插拔**处理
- **TV 专属布局**（例如把 HUD 放到更靠内、按钮更大）：现在是同一套 UI + 缩放

## 5. ⚠️ 上架前必须解决：内容量只有 20 关

竞品参照（见 08）：Google Play 上的《Bloxorz - Block And Hole》是 **200 关**；
移动端玩家对「关卡数」的期待是几十到上百。

**好消息**：我们的流水线把扩充成本压得很低 ——
`tools/build_level_set.gd` 是「声明式曲线 + 可复现种子 + 自动求解验证 + 曲线单调校验」，
改几行参数就能出 60 关并且保证「可解、平滑、无退化」。

**坏提醒**：**生成出来的关卡不等于好玩**。立项文档「六·3」流程的最后一步是**人工精选**，
这一步没法自动化，是真实瓶颈。建议：

1. 用生成器批量产出（例如 120 关候选），按「盘面尺寸 + 洞密度 + 最优步数」筛出一批
2. 人工按顺序试玩，保留 40~60 关作为首发内容（含一个平滑爬坡的曲线）
3. 把「哪些关卡好玩」的判断标准写下来 —— 下一款游戏就能复用这套标准

**变现选择**：

| 方案 | 工作量 | 说明 |
|---|---|---|
| **买断制**（$2.99 左右） | 最低（现在就能上） | 与竞品（免费+广告）差异化；但下载量会低 |
| 免费 + 激励广告（提示/跳关） | 中（要接广告 SDK，改 UI 加提示系统） | 移动端主流；但会把「纯解谜」变成「看广告」 |
| 免费 + 一次性内购解锁全部 | 中低（要接 IAP） | 折中；需实现 IAP 插件与恢复购买 |

---

## 6. CI（可选，但强烈建议先做 Android）

GitHub Actions 两个 job（公开仓库免费）：

- **android**（`ubuntu-latest`）：装 JDK17 + Android SDK → `gf-android-env.sh` →
  `--install-android-build-template` → base64 解出 keystore → `gf-export.sh … android` → 上传 artifact
- **ios**（`macos-latest`）：装 Godot macOS 版 + 导出模板 → `gf-export.sh … ios` →
  用 App Store Connect API Key 上传 TestFlight

需要的 secrets：`ANDROID_KEYSTORE_BASE64`、`ANDROID_KEYSTORE_PASSWORD`、
`APPLE_TEAM_ID`、`APP_STORE_CONNECT_KEY`（以及 `.p8` 与 issuer id）。

> 注意：CI 上**不能**用 `--export-debug` 冒充发布包（Play 会拒），也别把 keystore 提交进仓库。

---

## 7. 命令速查

```bash
# 生成图标与商店素材（改配色后重跑）
DISPLAY=:0 workflow/scripts/gf-run.sh -p games/puzzle-core res://tools/make_store_assets.gd

# 配置 Android SDK / JDK 路径（写编辑器设置，自动备份）
workflow/scripts/gf-android-env.sh [SDK目录] [JDK目录]

# 装 Android 构建模板（AAB 需要，一次）
workflow/godot-bin/godot --headless --path games/puzzle-core --install-android-build-template

# 出包
workflow/scripts/gf-export.sh games/puzzle-core android-apk   # 本机试玩
workflow/scripts/gf-export.sh games/puzzle-core android       # 上架用 AAB
workflow/scripts/gf-export.sh games/puzzle-core ios           # 仅 macOS

# 核验成品包（包名一致性 / 64 位 / 图标 / 权限 / 方向 / 签名）
workflow/scripts/gf-android-verify.sh

# 装到手机（或把 apk 拷过去直接点安装）
adb install -r games/puzzle-core/build/android/puzzle-core.apk

# 移动端配置守卫（商店格式 / 包名 / ABI / ETC2 / 素材尺寸）
workflow/scripts/gf-run.sh -p games/puzzle-core res://tests/test_mobile.gd
```

---

## 8. 提交前必须记住的三件事

1. **包名一旦上架就不能改**（改 = 换一个 App，老用户不会自动迁移）。
   当前是 `com.easyindie.puzzlecore`，`tests/test_mobile.gd` 会强制 iOS/Android 保持一致。
2. **keystore 与 App Store Connect 私钥绝不入库**（`.gitignore` 已挡；CI 用 secrets）。
3. **`android/build/`（Gradle 构建模板）不入库**，用一条命令随时重装。
