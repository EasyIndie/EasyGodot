# 首发内容门禁：解法与缓存一致、曲线递增、终章中的每种机关真正影响路线。
extends SceneTree

const Loader = preload("res://core/level_loader.gd")
const Solver = preload("res://solver/solver.gd")
const Validate = preload("res://solver/validate.gd")

var checks: int = 0
var failures: int = 0


func check(ok: bool, message: String) -> void:
	checks += 1
	if not ok:
		failures += 1
		push_error(message)


func solve(data: Dictionary) -> Dictionary:
	var lv: Dictionary = Loader.load_dict(data)
	return Solver.new(lv["board"], lv["start"]).solve()


func _init() -> void:
	var previous: int = 0
	var rows: Array = []
	for number in range(1, 21):
		var path: String = "res://levels/level_%02d.json" % number
		var data: Dictionary = JSON.parse_string(FileAccess.get_file_as_string(path))
		var report: Dictionary = Validate.validate_dict(data)
		check(report["status"] == "valid", "%s 应可解且结构合法" % path)
		var moves: int = int(report.get("optimal_moves", -1))
		check(moves == int(data.get("optimal_moves", -2)), "%s 缓存参考步数应与真实最优解一致" % path)
		check(str(data.get("difficulty", "")) == str(report.get("difficulty", "?")), "%s 难度标签应与求解结果一致" % path)
		check(moves >= previous, "%s 难度步数不得倒退" % path)
		check(moves <= previous + 2, "%s 不应突然增加超过 2 步" % path)
		previous = moves
		rows.append({"level": number, "moves": moves})
		if number >= 19:
			var kinds: Array = []
			for d in data.get("mechanisms", []):
				kinds.append(str(d["kind"]))
			check(kinds.has("portal") and kinds.has("bridge"), "%s 终章应结合传送与桥" % path)
			for kind in ["portal", "bridge"]:
				var control: Dictionary = data.duplicate(true)
				var kept: Array = []
				for d in control["mechanisms"]:
					if str(d["kind"]) != kind and not (kind == "bridge" and str(d["kind"]) == "switch"):
						kept.append(d)
				control["mechanisms"] = kept
				var without: Dictionary = solve(control)
				check(not without["solvable"] or int(without["optimal_moves"]) > moves,
					"%s 中的 %s 不能只是装饰" % [path, kind])
	print(JSON.stringify({"suite": "test_campaign", "checks": checks, "failures": failures,
		"status": "ok" if failures == 0 else "fail", "curve": rows}))
	quit(0 if failures == 0 else 1)
