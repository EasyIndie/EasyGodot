# 项目自检脚本：在项目上下文（--path）中运行，验证项目配置可被正确加载，
# 并输出结构化元信息。这是「结构化输出协议」在项目模式下的示例。
# 运行方式: workflow/scripts/gf-run.sh -p games/puzzle-core res://tests/project_info.gd
extends SceneTree

func _init() -> void:
	var result: Dictionary = {
		"status": "ok",
		"project_name": ProjectSettings.get_setting("application/config/name", "unknown"),
		"project_version": ProjectSettings.get_setting("application/config/version", "unknown"),
		"description": ProjectSettings.get_setting("application/config/description", ""),
		"renderer": ProjectSettings.get_setting("rendering/renderer/rendering_method", "unknown"),
		"res_path": ProjectSettings.globalize_path("res://"),
	}
	print(JSON.stringify(result))
	quit(0)
