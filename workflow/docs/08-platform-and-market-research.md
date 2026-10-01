# 08 · 上架平台与竞品调研

> 调研时间：2026-10。费用与政策会变，**所有条目的官方链接都列出来了，签约前请再点开确认一次**。
> 本文的数据分两类，已分别标注：
> - **【已核实】** = 本次调研直接抓取了官方页面原文（附引用）
> - **【待确认】** = 凭经验判断，官方页面是 JS 单页应用抓不到正文，**需要人工打开链接核对**

---

## 1. 结论速览

| 问题 | 结论 |
|---|---|
| Steamworks 账号要钱吗？ | **要：$100 USD / 每款游戏**（不是年费），达到 $1000 收入后可回收 |
| 能上 Google Play / App Store / 华为吗？ | **都能**，但门槛与成本差别极大：Google $25 一次性 + 12 名测试者 14 天；Apple $99/年 + **必须有 macOS**；华为注册免费但**中国大陆上架游戏要版号**（需中国实体） |
| 技术上我们能不能出移动版？ | **Android 可以**（Linux 就能导出）；**iOS 不行**（Godot 官方硬要求 macOS + Xcode）；**HarmonyOS NEXT 不行**（不吃 APK，Godot 无官方导出） |
| 这些平台有同类竞品吗？ | **有，而且是最有说服力的一种情况**：Google Play 上《Bloxorz - Block And Hole》**1M+ 安装 / 10.5K 评价**，但**评分只有 4.0**，App Store 侧全是评分 3.3 左右、评价个位数到 200 的克隆 —— 说明**需求真实但没人把品质做好** |
| 该不该做移动端？ | **建议暂时不做主渠道**：这个品类在移动端被「免费 + 广告 + 超休闲」统治，我们 20 关的买断式体验在那边卖不动（要做就得扩到 30~50 关并改成广告变现） |

---

## 2. 平台费用与门槛

| 平台 | 一次性 / 年费 | 其他硬门槛 | 主要风险 |
|---|---|---|---|
| **Steam** | **$100 USD / 每款**（可回收） | 付款后 **30 天等待期**；需要商店页素材、税务/银行信息 | 无中文市场的额外牌照要求；但**冷启动没流量**（Steam 上架≠曝光） |
| **Apple App Store** | **$99 USD / 年** | **必须 macOS + Xcode** 才能构建；需签名证书；审核偏主观 | 个人账号可上架；中国大陆区游戏需**版号** |
| **Google Play** | **$25 USD 一次性** | 2023-11-13 之后注册的**个人账号**：必须跑**封闭测试 ≥12 名测试者、连续 ≥14 天**才能申请上架 | 中国大陆不可用（Google Play 不在境内运营） |
| **华为 AppGallery** | **【待确认】注册免费**（无年费、无上架费） | 企业账号需营业执照；**中国大陆上架游戏需版号**；海外分发不需要 | **HarmonyOS NEXT 不再兼容 APK**，华为新机型是另一套包格式 |

### 官方原文引用（【已核实】）

**Steam Direct**（<https://partner.steamgames.com/steamdirect>）

> "In order to get fully set up, you will need to pay a **$100.00 USD fee for each product** you wish to distribute on Steam… This fee is not refundable, but will be **recoupable** in the payment made after your product has at least **$1,000.00 USD Adjusted Gross Revenue**."
> "A **30-day waiting period** between when you paid the app fee and when you can release your game."

**Apple Developer Program**（<https://developer.apple.com/programs/whats-included/>，中文页 <https://developer.apple.com/cn/programs/enroll/>）

> "The Apple Developer Program is **99 USD per membership year**…"
> "Apple Developer Program 每年的会费为 **99 美元**。"（非营利组织/教育机构/政府可申请豁免）

**Google Play 注册费**（<https://support.google.com/googleplay/android-developer/answer/6112435>）

> "There is a **US$25 one-time registration fee**…"

**Google Play 新个人账号的测试要求**（<https://support.google.com/googleplay/android-developer/answer/14151465>）

> "Developers with **personal accounts created after November 13, 2023**, must run a **closed test** for their app with a **minimum of 12 testers** who have been **opted in continuously for at least 14 days**."

> 这条对本项目影响很实际：**找不到 12 个真人测试者就上不了架**（企业账号不受此限，但企业账号需要营业执照等材料）。

**Godot iOS 导出要求**（<https://docs.godotengine.org/en/stable/tutorials/export/exporting_for_ios.html>）

> "**You must export for iOS from a computer running macOS with Xcode installed.**"

**华为 AppGallery 规模**（Wikipedia：<https://en.wikipedia.org/wiki/Huawei_AppGallery>）

> "As of 2022, AppGallery had **580 million monthly active users**"；"launched in 2011 in China and in **2018 internationally**"；
> 且它现在是 "the official app store for the devices running on Huawei **HarmonyOS**"。

**华为开发者账号是否需要费用**：官方页面（<https://developer.huawei.com/consumer/en/>）是 JS 单页应用，抓不到正文，本机搜索也被限流 →
**【待确认】**。按业界普遍说法：**AppGallery Connect 开发者注册不收费**（不收年费、不收上架费），
但**中国大陆上架游戏**需要版号 + 完成工信部 App 备案。请在注册页确认。

---

## 3. 中国市场的特殊门槛（决定「华为应用商城」能不能做）

1. **版号（游戏出版物号）**：在中国大陆**通过任何安卓商店分发的游戏都需要版号**，
   申请主体必须是持有《网络出版服务许可证》的**中国境内企业**，个人与境外主体无法直接申请。
   → 结论：**中国大陆渠道基本不适合个人/海外开发者独立上架**。
2. **App 备案**：2023 年起，所有在境内上架的 App（含游戏）需完成工信部移动互联网应用程序备案。
3. **海外分发不需要版号**：AppGallery 在 170+ 国家/地区运营，
   走**海外**（非中国大陆地区）分发可以绕开版号，但面对的是华为机型的海外存量用户。
4. **HarmonyOS NEXT 是另一条技术线**：NEXT 起不再兼容 Android APK，
   Godot **没有官方 HarmonyOS 导出**（只有社区移植），意味着华为新机型要么放弃、要么自研移植。

> 建议：**华为/中国区暂不做**。它的价值主要在「境内安卓用户」，而境内上架的门槛（版号 + 备案 + 中国实体）
> 与我们的体量完全不匹配；海外 AppGallery 的用户价值对一款 20 关解谜也不高。

---

## 4. 移动端技术可行性（针对我们当前项目）

| 目标平台 | 可行性 | 主要工作量 |
|---|---|---|
| **Android**（Google Play / 各安卓商店） | ✅ 现在就能做（Linux 上装 Android SDK + JDK + keystore 即可导出 APK/AAB） | 导出配置 + 图标/启动图 + 签名 + **应用内购/广告 SDK 接入**（真正的成本在这里）+ 上架素材 |
| **iOS** | ⚠️ 有条件 | 必须 macOS + Xcode。变通方案：**GitHub Actions 的 macOS runner**（公开仓库免费）+ App Store Connect API 做签名，但**仍需 $99/年账号** |
| **HarmonyOS NEXT** | ❌ | 无官方 Godot 导出，需要自研/社区移植 |
| **Web** | ✅ 已有 | 已完成（GitHub Pages 在线） |

**好消息**：触屏 UI 这块我们**已经超范围做完了**（D-pad + 滑动映射 + 安全区域 + 竖屏取景 + DPR 预算），
也就是说移动端最容易被低估的「手感与适配」部分是现成的，剩下的是**打包、变现 SDK、内容量**三件事。

---

## 5. 竞品调研

### 5.1 Google Play（数据抓自商店页，可复核）

| 游戏 | 开发者 | 安装量 | 评分 | 变现 | 备注 |
|---|---|---|---|---|---|
| **Bloxorz - Block And Hole** | Superpow | **1M+** | 4.0（10.5K 评价） | 广告 + IAP **$0.99–$7.99** | 200 关；**2026-08 仍在更新**；同时上架 Google Play Games for PC |
| Rolling Cubes: 3D Puzzle | Digintelligence | 100+ | — | 无内购标记 | 玩法最接近我们的一个（立体滚方块解谜） |
| Roll Block Puzzle 3D | Hakan Yuksel | 10+ | — | 无内购标记 | 几乎无人使用 |

### 5.2 App Store（美区，抓自 Apple 官方搜索 API）

| 游戏 | 开发者 | 价格 | 评分（评价数） |
|---|---|---|---|
| Bloxorz path finder | Beijing Tiantian Innov | 免费 | 3.33（**203**） |
| Bloxorz Magic | Dong Tran | 免费 | 4.24（34） |
| bloxorz | 英科 周 | **$0.99** | 4.20（46） |
| Bloxorz HD Rolling Block | Hakan Kokarcalı | 免费 | 5.00（3） |
| Bloxorz 2 Path Finder | Hakan Kokarcalı | 免费 | 3.00（2） |
| Crazy Bloxorz | Cornelius Alistair Hav | 免费 | 0（0） |

> 注意：**原始 Bloxorz（2007 Flash，Damien Clarke）从未有官方移动版**，
> 而且这个名字**没有被有效维权** —— 大量第三方克隆直接用 "Bloxorz" 上架，其中一个还卖 $0.99。

### 5.3 App Store（中国区）

| 游戏 | 开发者 | 评分（评价数） |
|---|---|---|
| 3D推方块 | 亚州 王 | 3.93（**88**） |
| 滚方块 - 益智过关游戏 | 亚州 王 | 4.75（4） |
| BLOXROLL - 3D | Jamiu Awoke | 0（0） |
| 滚动块 / Roll The Block | Ruslan Goncharenko | 0（0） |

> 同一个中国开发者（亚州 王）在美区和中区各放了多个同类产品，都是「免费 + 评分一般」，
> 说明这条路**被验证可行但没被认真做**。

### 5.4 相邻品类（说明「方块」很卷，但「滚动机制」不卷）

「block puzzle」这个词在移动端被**消方块（1010!/Block Blast 类）**彻底占据：
`Wood Block Puzzle Games` 42.9 万条评价、`Block Puzzle Westerly` 4434、`Block Puzzle: Star Finder` 3094……
这些和我们的玩法完全不同，但会**抢走所有搜索流量**（搜 "block puzzle" 搜不到我们）。

---

## 6. 判断与建议

### 6.1 品类验证结论

- **需求真实**：Google Play 上有一个 **1M+ 装机**的直接竞品，且**仍在更新**（2026-08）。
- **品质门槛极低**：它的评分只有 4.0，App Store 侧最好的克隆是 3.33 分 / 203 条评价 ——
  竞品普遍是「能玩但不好玩」。我们已有的东西（平滑难度爬坡、庆祝、回放、安全区适配、
  动画质量、99 分位的分辨率策略）在这个赛道里属于**明显高于平均线**。
- **但同时要清醒**：移动端这个品类的赢法是「免费 + 广告 + 超休闲」，而不是「20 关精心设计的买断制体验」。

### 6.2 优先级建议

| 优先级 | 渠道 | 理由 |
|---|---|---|
| **1** | **Steam** | $100 一次性、最匹配买断制、包已经能出（只需重出 + 商店页 + 素材）；风险是冷启动没流量 |
| **2** | **Web（已有）** | 当作试玩/引流与传播载体（Challenge Link 分享最省事） |
| **3** | **Android**（若要做） | 技术无阻塞，但需要：改造成免费+广告模式、内容扩到 30~50 关、满足 12 名测试者 14 天的上架门槛 |
| **4** | **iOS** | 需要 $99/年 + macOS（可用 GitHub Actions macOS runner 变通）；内容量同样是问题 |
| **5** | **华为 / 中国区** | **暂不做**：需要中国实体 + 版号 + 备案；HarmonyOS NEXT 还要另一套包格式 |

### 6.3 如果要做移动端，必须先解决「内容量」

移动端玩家的期待是**几十到上百关**（竞品 200 关），我们现在 **20 关**。
好消息：内容扩充的成本被我们的流水线压得很低（`tools/build_level_set.gd` = 声明式曲线 + 可复现种子 +
自动求解验证 + 曲线单调校验，改几行参数就能出 60 关并保证「可解、平滑、无退化」）。
坏的提醒：**生成出来的关卡不等于好玩** —— 立项文档「六·3」的流程里最后一步是**人工精选**，
这一步没法自动化，是内容扩充的真实瓶颈。

---

## 7. 数据来源清单

| 来源 | 用途 | 链接 |
|---|---|---|
| Steamworks 官方 | Steam Direct 费用与等待期 | <https://partner.steamgames.com/steamdirect> |
| Apple 官方 | 会员年费 | <https://developer.apple.com/programs/whats-included/> · <https://developer.apple.com/cn/programs/enroll/> |
| Google 官方帮助 | Play 注册费 | <https://support.google.com/googleplay/android-developer/answer/6112435> |
| Google 官方帮助 | 新个人账号测试门槛（12 人 / 14 天） | <https://support.google.com/googleplay/android-developer/answer/14151465> |
| Godot 官方文档 | iOS 必须 macOS + Xcode | <https://docs.godotengine.org/en/stable/tutorials/export/exporting_for_ios.html> |
| Wikipedia | AppGallery 规模与属性 | <https://en.wikipedia.org/wiki/Huawei_AppGallery> |
| Apple Search API | App Store 竞品（美区 / 中国区） | <https://itunes.apple.com/search?term=bloxorz&entity=software&country=us> |
| Google Play 商店页 | 竞品装机与变现 | <https://play.google.com/store/apps/details?id=com.superpow.bloxorz> |

> 竞品数据是本次调研现场抓取的（脚本见提交记录），可随时重跑复核；
> **费用与政策条款请以签约当天的官方页面为准**。
