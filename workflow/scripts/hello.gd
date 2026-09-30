# 最小闭环验证脚本：验证「智能体 → Godot headless → 结构化 JSON 结果」链路
# 运行方式: godot --headless -s workflow/scripts/hello.gd
# 约定: 脚本统一通过 stdout 输出单行 JSON，通过退出码表达成功/失败
extends SceneTree

func _init() -> void:
	var version_info: Dictionary = Engine.get_version_info()
	var result: Dictionary = {
		"status": "ok",
		"godot": str(version_info.get("string", "unknown")),
		"headless": DisplayServer.get_name() == "headless",
		"message": "game-factory workflow: minimal loop is alive",
	}
	print(JSON.stringify(result))
	quit(0)
