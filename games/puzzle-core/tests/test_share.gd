# test_share.gd — 分享 / 挑战链接的纯逻辑测试（headless）。
# 链接会被人手改、被聊天软件加尾巴、被截断，所以解析必须**容错**：这一层边界要盯死。
extends SceneTree

const Share = preload("res://meta/share.gd")

const BASE := "https://example.com/game/"

var checks: int = 0
var failures: int = 0


func _init() -> void:
	_test_url()
	_test_text()
	_test_parse()
	_test_roundtrip()
	_test_lines()

	var result: Dictionary = {
		"suite": "test_share",
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
		printerr("FAIL: " + msg)


func _test_url() -> void:
	check(Share.challenge_url(BASE, 12, 9) == BASE + "?level=12&moves=9", "基本形式")
	check(Share.challenge_url(BASE, 12, -1) == BASE + "?level=12", "不带步数时只有 level")
	check(Share.challenge_url(BASE, 1, 0) == BASE + "?level=1", "moves=0 视为没有步数")
	# 关号从 1 开始（对外可读），并且不允许出现 0 或负数
	check(Share.challenge_url(BASE, 0, 5).contains("level=1"), "关号下限为 1")
	check(Share.challenge_url(BASE, -3, 5).contains("level=1"), "负关号也归到 1")
	# 没有 base（原生包内分享）→ 落回公网 Web 版，绝不能生成一个空链接
	check(Share.challenge_url("", 3, 4).begins_with(Share.DEFAULT_BASE), "空 base 落回默认地址")
	check(Share.challenge_url("   ", 3, 4).begins_with(Share.DEFAULT_BASE), "空白 base 也落回默认")
	# 已经有查询串的 base（例如带了 ?lite=1）→ 用 & 续接
	var with_q: String = Share.challenge_url("https://x.test/g/?lite=1", 7, 3)
	check(with_q.contains("?lite=1&level=7&moves=3"), "已有查询串时应以 & 续接（实际 %s）" % with_q)
	# 末尾没有斜杠的 base 也要能用
	check(Share.challenge_url("https://x.test/game", 2, 2) == "https://x.test/game/?level=2&moves=2",
		"base 无尾斜杠时补一个")


func _test_text() -> void:
	var url: String = Share.challenge_url(BASE, 12, 9)
	var t: String = Share.share_text(12, 9, 21400, url)
	check(t.contains("第 12 关"), "文案要有关号")
	check(t.contains("9 步"), "文案要有步数")
	check(t.contains("21.4 秒"), "文案要有用时")
	check(t.contains(url), "文案必须带上链接（否则分享了也没法点）")
	# 没有成绩时也要成立（「这关好难」也值得分享）
	var t2: String = Share.share_text(12, -1, -1, url)
	check(t2.contains("卡住了"), "没有成绩时用另一种说法")
	check(not t2.contains("—"), "没有成绩时不该出现占位符")


func _test_parse() -> void:
	var ok: Dictionary = Share.parse_challenge("?level=12&moves=9", 20)
	check(int(ok.get("level", 0)) == 12, "解析关号")
	check(int(ok.get("moves", -1)) == 9, "解析步数")
	# 各种形态
	check(int(Share.parse_challenge("level=5", 20).get("level", 0)) == 5, "无问号也能解析")
	check(int(Share.parse_challenge("?moves=3&level=5", 20).get("moves", -1)) == 3, "参数顺序无关")
	check(int(Share.parse_challenge("?level=5&moves=3#frag", 20).get("moves", -1)) == 3, "忽略 # 片段")
	check(int(Share.parse_challenge("https://x.test/g/?level=8", 20).get("level", 0)) == 8, "整条 URL 也能解析")
	check(int(Share.parse_challenge("?LURE=8".replace("LURE", "LEVEL"), 20).get("level", 0)) == 8,
		"键名大小写不敏感（有人会手改成大写）")
	# 缺步数
	check(int(Share.parse_challenge("?level=8", 20).get("moves", -99)) == -1, "缺步数 → -1")
	# 容错：越界、非数字、空、垃圾、截断
	check(Share.parse_challenge("?level=999", 20).is_empty(), "关号越界 → 视为无挑战（不偷偷 clamp）")
	check(Share.parse_challenge("?level=0", 20).is_empty(), "关号 0 → 无挑战")
	check(Share.parse_challenge("?level=abc", 20).is_empty(), "非数字 → 无挑战")
	check(Share.parse_challenge("?moves=3", 20).is_empty(), "只有步数没有关号 → 无挑战")
	check(Share.parse_challenge("", 20).is_empty(), "空串 → 无挑战")
	check(Share.parse_challenge("???", 20).is_empty(), "垃圾串 → 无挑战")
	check(Share.parse_challenge("?level=", 20).is_empty(), "只有键没有值 → 无挑战")
	check(Share.parse_challenge("?level=12&moves=", 20).has("level"), "步数为空但关号有效 → 仍可挑战")
	check(int(Share.parse_challenge("?level=12&moves=", 20).get("moves", -99)) == -1, "空的步数 → -1")
	check(Share.parse_challenge("?level=5&level=9", 20).get("level", 0) == 9, "重复键取后一个")
	check(Share.parse_challenge("?level=5", 0).is_empty(), "关卡表为空时不做挑战")


func _test_roundtrip() -> void:
	# 生成的链接必须能被自己解析回来 —— 这是分享功能的最低要求
	for lv in [1, 7, 20]:
		for mv in [-1, 3, 15]:
			var url: String = Share.challenge_url(BASE, lv, mv)
			var back: Dictionary = Share.parse_challenge(url, 20)
			check(int(back.get("level", 0)) == lv, "第 %d 关往返一致" % lv)
			check(int(back.get("moves", -2)) == mv, "第 %d 关 %d 步往返一致" % [lv, mv])


func _test_lines() -> void:
	var line: String = Share.challenge_line(12, 9)
	check(line.contains("第 12 关") and line.contains("9 步"), "挑战目标行要有关号与目标")
	check(not Share.challenge_line(12, -1).contains("目标"), "没有目标步数时不写目标")

	# 输赢必须说清：只说「你用了 10 步」玩家不知道自己赢了没有
	check(Share.result_line(7, 12000, 9).contains("赢过对方 2 步"), "步数更少 = 赢")
	check(Share.result_line(9, 12000, 9).contains("打平"), "同样步数 = 打平")
	check(Share.result_line(11, 12000, 9).contains("对方是 9 步"), "步数更多 = 提示对方成绩")
	check(Share.result_line(11, 12000, 9).contains("再试试"), "步数更多时给出再试的引导")
	check(Share.result_line(11, 12000, -1).contains("11 步"), "没有目标时只报成绩")
	check(Share.result_line(11, -1, 9).contains("11 步"), "没有用时也成立")
