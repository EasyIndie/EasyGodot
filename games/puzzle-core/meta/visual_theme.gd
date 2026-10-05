# 独立的材质、光照与界面配方；旧主题 ID 保持存档兼容。
extends RefCounted

const IDS := ["mist", "porcelain", "candy", "abyss"]
const TITLES := ["玉林晨雾", "陶土暖阳", "暮色天鹅绒", "蔚蓝深海"]

static func valid(id: String) -> String:
	return id if IDS.has(id) else IDS[0]


static func title(id: String) -> String:
	return preload("res://meta/i18n.gd").t(TITLES[IDS.find(valid(id))])


static func next(id: String) -> String:
	return IDS[(IDS.find(valid(id)) + 1) % IDS.size()]


static func palette(id: String) -> Dictionary:
	# 色彩按角色分配：低干扰的棋盘/背景、清晰的目标、少量强调色与高对比 UI。
	# 四套主题有各自的明暗与材质性格，同时保持文字颜色与面板之间的可读性。
	var c := {
		"tile_a": Color("6d9e8d"), "tile_b": Color("5f8c7d"), "block": Color("e5b85b"),
		"goal": Color("264e43"), "ring": Color("b8e8cc"), "switch": Color("e8a954"),
		"bridge": Color("5db4c4"), "portal_a": Color("a985c4"), "portal_b": Color("75c6ad"),
		"bg_top": Color("172724"), "bg_mid": Color("233732"), "bg_bottom": Color("152522"),
		"panel": Color("20322ef2"), "text": Color("f3f1e3"), "muted": Color("c2d2c8"),
		"accent": Color("f0c773"), "light": Color("ffeac2"), "ambient": Color("a6c4b7"),
		"energy": 0.88, "ambient_energy": 0.60, "roughness": 0.78, "metallic": 0.05,
		"block_roughness": 0.38, "block_metallic": 0.22,
	}
	match valid(id):
		"porcelain":
			c.merge({"tile_a": Color("b99973"), "tile_b": Color("a98664"), "block": Color("bd5038"),
				"goal": Color("385d50"), "ring": Color("70a78c"), "switch": Color("c87043"),
				"bridge": Color("527f8a"), "portal_a": Color("8c6b90"), "portal_b": Color("598d78"),
				"bg_top": Color("e8d8c1"), "bg_mid": Color("dfc9aa"), "bg_bottom": Color("cbb293"),
				"panel": Color("fff7eaf5"), "text": Color("332c26"), "muted": Color("62564a"),
				"accent": Color("934832"), "light": Color("fff0d5"), "ambient": Color("d7c3a7"),
				"energy": 0.78, "ambient_energy": 0.52, "roughness": 0.91, "metallic": 0.0,
				"block_roughness": 0.76, "block_metallic": 0.02}, true)
		"candy":
			c.merge({"tile_a": Color("81768f"), "tile_b": Color("70647f"), "block": Color("e99a8a"),
				"goal": Color("38364f"), "ring": Color("a9e2da"), "switch": Color("e3b878"),
				"bridge": Color("62b6b2"), "portal_a": Color("bd82bb"), "portal_b": Color("78b7a8"),
				"bg_top": Color("211e2b"), "bg_mid": Color("332d40"), "bg_bottom": Color("211e2c"),
				"panel": Color("292536f2"), "text": Color("f5f0f4"), "muted": Color("c9c0d0"),
				"accent": Color("f0bca4"), "light": Color("ffe0cf"), "ambient": Color("b7aacb"),
				"energy": 0.78, "ambient_energy": 0.48, "roughness": 0.66, "metallic": 0.02,
				"block_roughness": 0.34, "block_metallic": 0.16}, true)
		"abyss":
			c.merge({"tile_a": Color("477d94"), "tile_b": Color("386a82"), "block": Color("ee8064"),
				"goal": Color("173e50"), "ring": Color("86e5e2"), "switch": Color("e3b86f"),
				"bridge": Color("51b3c8"), "portal_a": Color("9d8be0"), "portal_b": Color("4dc3aa"),
				"bg_top": Color("0d1c28"), "bg_mid": Color("173343"), "bg_bottom": Color("0d1c28"),
				"panel": Color("172d3af2"), "text": Color("ebf5f4"), "muted": Color("b6cdd1"),
				"accent": Color("e8c47c"), "light": Color("d9f6f2"), "ambient": Color("9ecbd5"),
				"energy": 0.90, "ambient_energy": 0.55, "roughness": 0.52, "metallic": 0.20,
				"block_roughness": 0.30, "block_metallic": 0.24}, true)
	return c
