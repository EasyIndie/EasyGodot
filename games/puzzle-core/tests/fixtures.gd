# fixtures.gd — 测试专用关卡夹具。
# 与可玩关卡（levels/）解耦：可玩关卡会随设计/生成调整，测试夹具保持稳定。
extends RefCounted


# 单格 Cube 夹具：3x3 无洞，起点 (0,0)、目标 (2,2)。
static func cube_level() -> Dictionary:
	return {
		"id": "fixture_cube",
		"grid": {"x": 3, "z": 3},
		"holes": [],
		"goal": [[2, 2]],
		"start": {"shape": "cube", "orientation": "standing", "position": [0, 0, 0]},
	}


static func level_8moves() -> Dictionary:
	# 已知性质：6x6，最优 8 步，难度 medium，起点沿 X 横躺
	return {
		"id": "fixture_8moves",
		"grid": {"x": 6, "z": 6},
		"holes": [[2, 2], [2, 3], [3, 2]],
		"goal": [[5, 5]],
		"start": {"shape": "domino", "orientation": "lying_x", "position": [0, 0, 0]},
	}
