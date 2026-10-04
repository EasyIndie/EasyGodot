# validate_levels.gd — 关卡质检 CLI（headless）。
# 用法:
#   质检所有关卡:      gf-run.sh -p games/puzzle-core res://tools/validate_levels.gd
#   质检指定关卡:      gf-run.sh -p games/puzzle-core res://tools/validate_levels.gd res://levels/level_01.json
# 输出: 单行 JSON（含逐关报告 + 汇总），存在 invalid/unsolvable 时退出码非 0。
extends SceneTree

const Validate = preload("res://solver/validate.gd")


func _init() -> void:
	var paths: Array = _collect_paths()
	var results: Array = []
	for p in paths:
		results.append(_validate_path(p))

	var summary := {"total": results.size(), "valid": 0, "invalid": 0, "unsolvable": 0}
	for r in results:
		summary[str(r["status"])] = summary.get(str(r["status"]), 0) + 1

	print(JSON.stringify({"levels": results, "summary": summary}))
	var ok: bool = summary["total"] > 0 and summary["invalid"] == 0 and summary["unsolvable"] == 0
	quit(0 if ok else 1)


func _collect_paths() -> Array:
	var args: Array = OS.get_cmdline_user_args()
	if args.size() > 0:
		return args
	var out: Array = []
	var dir := DirAccess.open("res://levels")
	if dir != null:
		dir.list_dir_begin()
		var f: String = dir.get_next()
		while f != "":
			if f.ends_with(".json"):
				out.append("res://levels/" + f)
			f = dir.get_next()
		dir.list_dir_end()
	out.sort()
	return out


func _validate_path(p: String) -> Dictionary:
	var f := FileAccess.open(p, FileAccess.READ)
	if f == null:
		return {"path": p, "status": "invalid", "errors": ["cannot open file"]}
	var text := f.get_as_text()
	f.close()
	var json := JSON.new()
	if json.parse(text) != OK:
		return {"path": p, "status": "invalid", "errors": ["bad json at line " + str(json.get_error_line())]}
	if not (json.data is Dictionary):
		return {"path": p, "status": "invalid", "errors": ["level must be an object"]}
	var r: Dictionary = Validate.validate_dict(json.data)
	r["path"] = p
	return r
