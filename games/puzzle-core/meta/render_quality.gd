# render_quality.gd — 画质档位与自适应降级的**纯逻辑**（不依赖场景树，可 headless 单测）。
#
# 为什么要有这一层：
#   画质不是“越高质量越好”，而是“在不掉帧的前提下尽量高”。不同设备（手机 / 笔记本 /
#   台式独显）差异极大，写死一个档位必然有一半设备不满意。于是：
#     1) 按设备类别给一个**起始档位**（触屏设备保守一点）
#     2) 运行时按实测帧时间自适应升降（带滞回，避免抖动）
#   纯函数化是为了能测：这里的每条规则都有断言，而不是“上线看看会不会卡”。
extends RefCounted

const I18n = preload("res://meta/i18n.gd")

# 档位：0 = 最低（关阴影/关 MSAA），3 = 最高（4x MSAA + 阴影 + 高光效果）
const TIERS: int = 4
# 帧时间阈值（毫秒）：超过 HIGH_MS 降档，低于 LOW_MS 且稳定才升档
const SLOW_MS: float = 30.0
const FAST_MS: float = 15.0
# 升降档前的观察时长（秒）：太短会被偶发卡顿带着乱跳
const SAMPLE_SEC: float = 1.5

# 起始档位：桌面默认最高；触屏设备从中间起步（先亮起来，稳住了再升上去）
const TIER_DESKTOP: int = 3
const TIER_TOUCH: int = 2
const TIER_LITE: int = 0


static func initial_tier(is_touch: bool, lite: bool) -> int:
	if lite:
		return TIER_LITE
	return TIER_TOUCH if is_touch else TIER_DESKTOP


static func msaa(tier: int) -> int:
	# 对应 Viewport.MSAA_* 枚举：0=关 1=2x 2=4x 3=8x
	# 只用到 关/2x/4x 三档：8x 的收益远小于代价
	match clampi(tier, 0, TIERS - 1):
		0:
			return 0
		1:
			return 0
		2:
			return 1
		_:
			return 2


static func shadows(tier: int) -> bool:
	return clampi(tier, 0, TIERS - 1) >= 1


static func backdrop(tier: int) -> bool:
	# 渐变幕布（挂在相机前的一个 quad）：档位 0 时省掉这一次全屏绘制
	return clampi(tier, 0, TIERS - 1) >= 1


static func glow(tier: int) -> bool:
	# 逐帧材质更新（目标格呼吸发光）：最低档也保留 —— 它是**玩法信息**（目标在哪），
	# 不该因为省性能而消失，代价也可以忽略。
	return true


static func next_tier(tier: int, avg_frame_ms: float, elapsed: float) -> int:
	# 自适应：观察满 SAMPLE_SEC 才动一次。降档积极、升档保守（滞回区间 FAST_MS..SLOW_MS），
	# 否则会在阈值附近来回跳，玩家看到画质闪烁。
	if elapsed < SAMPLE_SEC or avg_frame_ms <= 0.0:
		return clampi(tier, 0, TIERS - 1)
	var t: int = clampi(tier, 0, TIERS - 1)
	if avg_frame_ms > SLOW_MS:
		return maxi(t - 1, 0)
	if avg_frame_ms < FAST_MS:
		return mini(t + 1, TIERS - 1)
	return t


static func tier_label(tier: int) -> String:
	# 给诊断/日志用的可读名字
	match clampi(tier, 0, TIERS - 1):
		0:
			return I18n.t("省电")
		1:
			return I18n.t("流畅")
		2:
			return I18n.t("标准")
		_:
			return I18n.t("精细")
