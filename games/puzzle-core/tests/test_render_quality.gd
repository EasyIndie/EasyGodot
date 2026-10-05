# test_render_quality.gd — 画质档位与自适应降级的测试（headless，纯逻辑）。
#
# 这一层被单独测试的原因：它的规则看起来“只是几个阈值”，但一旦出错，表现是
# 「某些设备上莫名很卡」或「画面在阈值附近来回闪」—— 这两类问题在真机上极难复现。
extends SceneTree

const RQ = preload("res://meta/render_quality.gd")

var checks: int = 0
var failures: int = 0


func _init() -> void:
	_test_initial_tier()
	_test_feature_mapping()
	_test_adaptation()
	_test_no_flapping()

	var result: Dictionary = {
		"suite": "test_render_quality",
		"checks": checks,
		"failures": failures,
		"status": "ok" if failures == 0 else "fail",
	}
	print(JSON.stringify(result))
	quit(0 if failures == 0 else 1)


func check(cond: bool, msg: String) -> void:
	checks += 1
	if not cond:
		failures += 1
		push_error("FAIL: " + msg)


func _test_initial_tier() -> void:
	# 桌面从最高档起步（大多数桌面 GPU 撑得住，先给最好的），
	# 触屏设备从中间档起步（保守一点，稳住了再往上爬），
	# ?lite=1 直接最低档。
	check(RQ.initial_tier(false, false) == RQ.TIER_DESKTOP, "桌面应默认最高档")
	check(RQ.initial_tier(true, false) == RQ.TIER_TOUCH, "触屏应默认中高档")
	check(RQ.initial_tier(false, true) == RQ.TIER_LITE, "lite 模式应最低档")
	check(RQ.initial_tier(true, true) == RQ.TIER_LITE, "触屏 + lite 也应最低档")
	check(RQ.initial_tier(false, false) > RQ.initial_tier(true, false), "桌面档位应不低于触屏")


func _test_feature_mapping() -> void:
	# 档位 → 具体特性的映射必须单调：档位越高，特性只会变多，不会变少。
	# （否则“升档”反而会关掉阴影，玩家看到画面变差，非常费解）
	var prev_msaa: int = -1
	var prev_shadow: bool = false
	var prev_backdrop: bool = false
	for tier in range(RQ.TIERS):
		var m: int = RQ.msaa(tier)
		var sh: bool = RQ.shadows(tier)
		var bd: bool = RQ.backdrop(tier)
		check(m >= prev_msaa, "MSAA 应随档位单调不降（tier=%d）" % tier)
		check(m == 0 or m == 1 or m == 2, "MSAA 只用到 关/2x/4x 三档，got=%d" % m)
		check(sh or not prev_shadow, "阴影应随档位单调（tier=%d）" % tier)
		check(bd or not prev_backdrop, "幕布应随档位单调（tier=%d）" % tier)
		prev_msaa = m
		prev_shadow = sh
		prev_backdrop = bd
	check(RQ.msaa(RQ.TIERS - 1) == 2, "最高档应是 4x MSAA")
	check(RQ.msaa(0) == 0, "最低档应关 MSAA")
	check(RQ.shadows(0) == false, "最低档应关阴影")
	check(RQ.backdrop(0) == false, "最低档应关渐变幕布")
	# 目标格发光是**玩法信息**（目标在哪），任何档位都不能丢
	for tier in range(RQ.TIERS):
		check(RQ.glow(tier), "任何档位都应保留目标格发光（玩法信息，不能省）")
	check(RQ.tier_label(0) != "" and RQ.tier_label(RQ.TIERS - 1) != "", "档位应有可读名字")
	check(RQ.tier_label(99) == RQ.tier_label(RQ.TIERS - 1), "越界档位应夹取到最高档")
	check(RQ.msaa(-5) == RQ.msaa(0), "越界档位应夹取到最低档")


func _test_adaptation() -> void:
	# 观察时长不足时不该动档位（否则一帧卡顿就会降档）
	for tier in range(RQ.TIERS):
		check(RQ.next_tier(tier, 999.0, 0.1) == tier, "观察时间不足时不应改档")
		check(RQ.next_tier(tier, 0.0, 5.0) == tier, "帧时间无效时不应改档")

	# 持续卡顿 → 降档（直到最低）
	var t: int = RQ.TIERS - 1
	check(RQ.next_tier(t, 22.1, 2.0) == RQ.TIERS - 2, "持续低于约 45fps 应及时降一档")
	t = RQ.next_tier(t, 60.0, 2.0)
	check(t == RQ.TIERS - 2, "卡顿应降一档，got=%d" % t)
	t = RQ.next_tier(t, 60.0, 2.0)
	check(t == RQ.TIERS - 3, "继续卡顿应继续降档")
	t = 0
	check(RQ.next_tier(t, 60.0, 2.0) == 0, "最低档不应再降（不能降到负）")

	# 非常流畅 → 升档（有上限）
	t = 0
	check(RQ.next_tier(t, 8.0, 2.0) == 1, "流畅应升一档")
	t = RQ.TIERS - 1
	check(RQ.next_tier(t, 8.0, 2.0) == RQ.TIERS - 1, "最高档不应再升（不能越界）")

	# 处在滞回区间（FAST..SLOW）→ 保持不动
	var mid: float = (RQ.FAST_MS + RQ.SLOW_MS) * 0.5
	for tier in range(RQ.TIERS):
		check(RQ.next_tier(tier, mid, 2.0) == tier, "滞回区间内应保持档位不变")


func _test_no_flapping() -> void:
	# 关键回归：如果升档阈值 >= 降档阈值，就会在边界附近来回跳（画质闪烁）。
	check(RQ.FAST_MS < RQ.SLOW_MS, "升档阈值必须严格小于降档阈值（否则会抖动）")
	check(RQ.SLOW_MS > 16.6, "降档阈值应高于 60fps 的帧时间，否则正常设备也会被降档")
	# 刚好 60fps（16.7ms）不应触发降档（否则大量正常设备会一直往下降）
	check(RQ.next_tier(3, 16.7, 2.0) == 3, "60fps 不应被判定为卡顿")
