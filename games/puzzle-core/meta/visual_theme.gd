# 独立的材质、光照与界面配方；旧主题 ID 保持存档兼容。
extends RefCounted
const IDS := ["mist", "porcelain", "candy", "abyss"]
const TITLES := ["青玉庭院", "暖陶工坊", "暮紫幻境", "深海流光"]
static func valid(id: String) -> String:
	return id if IDS.has(id) else IDS[0]
static func title(id: String) -> String:
	return preload("res://meta/i18n.gd").t(TITLES[IDS.find(valid(id))])
static func next(id: String) -> String:
	return IDS[(IDS.find(valid(id)) + 1) % IDS.size()]
static func palette(id: String) -> Dictionary:
	var c := {
		"tile_a": Color("4f857a"), "tile_b": Color("46776f"), "block": Color("e4b97d"),
		"goal": Color("245a50"), "ring": Color("a3e8c5"), "switch": Color("daab56"),
		"bridge": Color("499eaf"), "portal_a": Color("9a72b4"), "portal_b": Color("61bba2"),
		"bg_top": Color("112c2b"), "bg_mid": Color("284a43"), "bg_bottom": Color("132d2a"),
		"panel": Color("193a36e8"), "text": Color("edf4e9"), "muted": Color("afc8bb"),
		"accent": Color("e4c694"), "light": Color("fff1d6"), "ambient": Color("b4cabf"),
		"energy": 0.85, "ambient_energy": 0.48, "roughness": 0.75, "metallic": 0.0,
		"block_roughness": 0.5, "block_metallic": 0.12,
	}
	match valid(id):
		"porcelain":
			c.merge({"tile_a": Color("c8b5a0"), "tile_b": Color("bda88f"), "block": Color("af5741"),
				"goal": Color("557e70"), "ring": Color("c4e6bf"),
				"bg_top": Color("e4d9c8"), "bg_mid": Color("f2e8d8"), "bg_bottom": Color("d8c8b3"),
				"panel": Color("fff8ede8"), "text": Color("453b32"), "muted": Color("756657"),
				"accent": Color("9a4b38"), "light": Color("fff1dd"), "ambient": Color("d6c9b7"),
				"energy": 0.78, "ambient_energy": 0.55, "roughness": 0.92,
				"block_roughness": 0.85, "block_metallic": 0.0}, true)
		"candy":
			c.merge({"tile_a": Color("71648e"), "tile_b": Color("62567f"), "block": Color("e0a7b0"),
				"goal": Color("374c68"), "ring": Color("8ddcdd"),
				"bg_top": Color("231d38"), "bg_mid": Color("453554"), "bg_bottom": Color("251e36"),
				"panel": Color("30253fe8"), "text": Color("f5e9f2"), "muted": Color("c5afcf"),
				"accent": Color("e5b6c2"), "light": Color("ffe5ed"), "ambient": Color("c1b6d7"),
				"energy": 0.82, "ambient_energy": 0.48, "roughness": 0.62,
				"block_roughness": 0.35, "block_metallic": 0.15}, true)
		"abyss":
			c.merge({"tile_a": Color("254a65"), "tile_b": Color("203e58"), "block": Color("e3a94e"),
				"goal": Color("163e4a"), "ring": Color("60e0d4"),
				"bg_top": Color("081521"), "bg_mid": Color("142c40"), "bg_bottom": Color("081623"),
				"panel": Color("102536e8"), "text": Color("e3f1f4"), "muted": Color("99b7c6"),
				"accent": Color("e5bb70"), "light": Color("deeeff"), "ambient": Color("93b5cd"),
				"energy": 0.9, "ambient_energy": 0.55, "roughness": 0.5,
				"block_roughness": 0.28, "block_metallic": 0.28}, true)
	return c
