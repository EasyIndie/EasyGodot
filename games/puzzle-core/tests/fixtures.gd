# fixtures.gd — 测试专用关卡夹具。
# 与可玩关卡（levels/）解耦：可玩关卡会随设计/生成调整，测试夹具保持稳定。
extends RefCounted


static func level_8moves() -> Dictionary:
	# 已知性质：6x6，最优 8 步，难度 medium，起点沿 X 横躺
	return {
		"id": "fixture_8moves",
		"grid": {"x": 6, "z": 6},
		"holes": [[2, 2], [2, 3], [3, 2]],
		"goal": [[5, 5]],
		"start": {"shape": "domino", "orientation": "lying_x", "position": [0, 0, 0]},
	}


static func tiny_level() -> Dictionary:
	# 最小可玩夹具：3x3 无洞、竖立骨牌，起点 (0,0)、目标 (2,2)。
	# 用于「视觉层能否加载并渲染一个关卡」这类冒烟测试（不依赖 levels/ 的具体内容）。
	return {
		"id": "fixture_tiny",
		"grid": {"x": 3, "z": 3},
		"holes": [],
		"goal": [[2, 2]],
		"start": {"shape": "domino", "orientation": "standing", "position": [0, 0, 0]},
	}


static func with_hole() -> Dictionary:
	# 带一个空洞的夹具：用于验证「踩空坠落」路径
	return {
		"id": "fixture_hole",
		"grid": {"x": 4, "z": 4},
		"holes": [[1, 1]],
		"goal": [[3, 3]],
		"start": {"shape": "domino", "orientation": "standing", "position": [0, 0, 0]},
	}
