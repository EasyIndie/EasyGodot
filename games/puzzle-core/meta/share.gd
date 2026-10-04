# share.gd — 分享 / 挑战链接的纯逻辑（拼接与解析）。
#
# 与引擎解耦：只做字符串处理，不碰场景、不碰剪贴板 → 可以 headless 单测边界情况。
# 剪贴板/浏览器那一层留在 main.gd（那是平台相关的）。
#
# 为什么这是「传播闭环」的入口：Web 版天然适合发链接 —— 收到链接的人**点开就能直接玩
# 那一关**，不需要先通关前面 11 关。对一个 200 关级别的品类来说，
# 「我 9 步过了第 12 关，你来试试」比任何商店截图都有效。
extends RefCounted

const I18n = preload("res://meta/i18n.gd")

# 没有可用的浏览器地址时（原生包内分享）落回这里：公网 Web 版
const DEFAULT_BASE := "https://easyindie.github.io/EasyGodot/"


static func _base_or_default(base: String) -> String:
	var b: String = base.strip_edges()
	return DEFAULT_BASE if b == "" else b


static func challenge_url(base: String, level_no: int, moves: int = -1) -> String:
	# level_no 是**对外可读的关号**（从 1 开始），不是内部下标。
	# moves <= 0 时不带步数（分享一个「还没通关、只是这关很难」的链接也成立）。
	var url: String = _base_or_default(base)
	if not url.ends_with("/") and not url.contains("?"):
		url += "/"
	var sep: String = "&" if url.contains("?") else "?"
	url += "%slevel=%d" % [sep, maxi(level_no, 1)]
	if moves > 0:
		url += "&moves=%d" % moves
	return url


static func share_text(level_no: int, moves: int, time_ms: int, url: String) -> String:
	# 分享文案：先给成绩，再给链接。步数是主指标（解谜），用时是附带的。
	var who: String = I18n.t("我在《滚方块》第 %d 关") % maxi(level_no, 1)
	var score: String = ""
	if moves > 0:
		score = I18n.t("%d 步") % moves
	if time_ms >= 0:
		var secs: String = I18n.t("%.1f 秒") % (float(time_ms) / 1000.0)
		score = secs if score == "" else (score + "（" + secs + "）")
	var head: String = who + (I18n.t("用了 ") + score if score != "" else I18n.t("卡住了"))
	return head + I18n.t("，试试能不能超过我：\n") + url


static func parse_challenge(query: String, level_count: int) -> Dictionary:
	# 从 URL 查询串里解析挑战参数。**必须容错**：链接会被人手改、被聊天软件加尾巴、
	# 被截断。任何解析不出来的情况都返回空字典（＝按普通启动处理），绝不报错、绝不进入半开状态。
	# 支持 "?level=12&moves=9" / "level=12" / "…#level=12" 等常见形态。
	if level_count <= 0:
		return {}
	var q: String = query
	var hash_i: int = q.find("#")
	if hash_i >= 0:
		q = q.substr(0, hash_i)
	var qm: int = q.find("?")
	if qm >= 0:
		q = q.substr(qm + 1)
	if q == "":
		return {}
	var level: int = 0
	var moves: int = -1
	for pair in q.split("&", false):
		var eq: int = pair.find("=")
		if eq <= 0:
			continue
		var key: String = pair.substr(0, eq).strip_edges().to_lower()
		var val: String = pair.substr(eq + 1).strip_edges()
		if not val.is_valid_int():
			continue
		var n: int = val.to_int()
		if key == "level":
			level = n
		elif key == "moves":
			moves = n
	# 关号越界 → 视为没有挑战（不 clamp：把 999 关悄悄变成第 20 关会让分享者莫名其妙）
	if level < 1 or level > level_count:
		return {}
	if moves <= 0:
		moves = -1
	return {"level": level, "moves": moves}


static func challenge_line(level_no: int, moves: int) -> String:
	# 挑战模式下的目标提示（HUD 用）
	var t: String = I18n.t("好友挑战：第 %d 关") % maxi(level_no, 1)
	if moves > 0:
		t += I18n.t("　·　目标 %d 步") % moves
	return t


static func result_line(moves: int, time_ms: int, target: int) -> String:
	# 挑战完成时的对照文案：**必须说清输赢**，只说「你用了 10 步」等于没说
	var head: String = I18n.t("挑战完成：%d 步") % moves
	if time_ms >= 0:
		head += I18n.t("（%.1f 秒）") % (float(time_ms) / 1000.0)
	if target <= 0:
		return head
	if moves < target:
		return head + I18n.t("　·　赢过对方 %d 步！") % (target - moves)
	if moves == target:
		return head + I18n.t("　·　与对方打平")
	return head + I18n.t("　·　对方是 %d 步，再试试") % target
