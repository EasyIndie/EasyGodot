# 主题共用造型与机关语义，只替换材质和背景配色。
extends RefCounted

const IDS := ["mist", "porcelain", "candy"]
const TITLES := ["雾蓝暖金", "瓷白琥珀", "糖果珊瑚"]

static func valid(id: String) -> String:
	return id if IDS.has(id) else IDS[0]

static func title(id: String) -> String:
	return preload("res://meta/i18n.gd").t(TITLES[IDS.find(valid(id))])

static func next(id: String) -> String:
	return IDS[(IDS.find(valid(id)) + 1) % IDS.size()]

static func palette(id: String) -> Dictionary:
	var colors := {
		"tile_a": Color("8faec5"), "tile_b": Color("7595b1"),
		"block": Color("efb853"), "goal": Color("3da889"), "ring": Color("b4ffe3"),
		"switch": Color("e8bc72"), "bridge": Color("50b9d0"),
		"portal_a": Color("bb8aeb"), "portal_b": Color("64dcc8"),
		"bg_top": Color("101b2c"), "bg_mid": Color("273e59"), "bg_bottom": Color("111b2c"),
	}
	match valid(id):
		"porcelain":
			colors.merge({"tile_a": Color("e0e5e8"), "tile_b": Color("bdcad3"), "block": Color("dda351"),
				"bg_top": Color("151923"), "bg_mid": Color("333d4c"), "bg_bottom": Color("121822")}, true)
		"candy":
			colors.merge({"tile_a": Color("b2a5dd"), "tile_b": Color("8e83bb"), "block": Color("ef9181"),
				"bg_top": Color("211b34"), "bg_mid": Color("4b3d64"), "bg_bottom": Color("211c32")}, true)
	return colors
