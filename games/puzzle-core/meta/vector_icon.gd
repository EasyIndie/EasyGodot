# 以 CanvasItem 几何线条绘制，按控件尺寸实时缩放，不依赖位图字体或贴图。
extends Control

@export var icon_name := "levels"
@export var tint := Color(0.92, 0.95, 1.0)

func _draw() -> void:
	var c := size * 0.5
	# Keep the whole mark comfortably inside the hit target; the 2×2 level grid
	# has a wider silhouette than circular actions, so icons share one safe scale.
	var u := minf(size.x, size.y) * 0.30
	var w := maxf(u * 0.12, 1.6)
	match icon_name:
		"restart":
			draw_arc(c, u * 0.68, deg_to_rad(42), deg_to_rad(322), 28, tint, w, true)
			draw_colored_polygon(PackedVector2Array([c + Vector2(u * 0.95, -u * 0.2), c + Vector2(u * 0.37, -u * 0.28), c + Vector2(u * 0.72, -u * 0.72)]), tint)
		"levels":
			var cell := Vector2(u * 0.60, u * 0.60)
			for y in range(2):
				for x in range(2):
					var cell_center := c + Vector2((x - 0.5) * u * 1.16, (y - 0.5) * u * 1.16)
					draw_rect(Rect2(cell_center - cell * 0.5, cell), tint, false, w)
		"stop":
			draw_rect(Rect2(c - Vector2(u * 0.48, u * 0.48), Vector2(u * 0.96, u * 0.96)), tint, true)
		"replay":
			# A compact video-camera mark identifies the saved recording/replay action.
			var replay_u := u * 1.28
			var replay_w := maxf(replay_u * 0.12, 1.6)
			var body := Rect2(c + Vector2(-replay_u * 0.72, -replay_u * 0.46), Vector2(replay_u * 0.96, replay_u * 0.92))
			draw_rect(body, tint, false, replay_w)
			var lens_top := c + Vector2(replay_u * 0.24, -replay_u * 0.25)
			var lens_outer_top := c + Vector2(replay_u * 0.82, -replay_u * 0.56)
			var lens_outer_bottom := c + Vector2(replay_u * 0.82, replay_u * 0.56)
			var lens_bottom := c + Vector2(replay_u * 0.24, replay_u * 0.25)
			draw_polyline(PackedVector2Array([lens_top, lens_outer_top, lens_outer_bottom, lens_bottom]), tint, replay_w, true)
			draw_circle(c + Vector2(-replay_u * 0.25, 0), replay_u * 0.19, tint, false, replay_w, true)
		"share":
			var a := c + Vector2(-u * 0.58, 0)
			var b := c + Vector2(u * 0.48, -u * 0.55)
			var d := c + Vector2(u * 0.48, u * 0.55)
			draw_line(a, b, tint, w, true)
			draw_line(a, d, tint, w, true)
			for p in [a, b, d]:
				draw_circle(p, u * 0.2, tint)
		"settings":
			for i in range(8):
				var angle := TAU * float(i) / 8.0
				draw_line(c + Vector2.from_angle(angle) * u * 0.64, c + Vector2.from_angle(angle) * u, tint, w * 1.5, true)
			draw_circle(c, u * 0.67, tint, false, w * 1.5, true)
			draw_circle(c, u * 0.25, tint, false, w * 1.4, true)
