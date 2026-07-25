extends StaticBody3D
# ─────────────────────────────────────────────────────────────────────────────
# TradingPost — a real, buildable structure. "allow trading post to be built
# before its used" -- envoys, the trade menu, and incoming trade requests all
# used to route through an abstract stockpile position with no building the
# player ever had to raise. Now every trade action (Tribemanager.
# trade_partners()/propose_trade_with()/player_send_trade_envoy()/the
# incoming-request tick) is gated on one of these actually existing, and
# envoys walk to/from ITS position, not the stockpile's.
# In group "trading_post".
# ─────────────────────────────────────────────────────────────────────────────

func _ready() -> void:
	add_to_group("trading_post")
	_build_visual()

func _build_visual() -> void:
	# a simple raised stall: a plank counter + an awning post + a banner, so
	# it reads as a distinct structure from a teepee/fence at a glance
	var counter := MeshInstance3D.new()
	var box := BoxMesh.new()
	box.size = Vector3(2.6, 0.9, 1.2)
	counter.mesh = box
	counter.position = Vector3(0, 0.45, 0)
	counter.material_override = MatCache.flat(Color(0.45, 0.32, 0.18))
	add_child(counter)

	var col := CollisionShape3D.new()
	var shape := BoxShape3D.new()
	shape.size = box.size
	col.shape = shape
	col.position = counter.position
	add_child(col)

	for side in [-1.0, 1.0]:
		var post := MeshInstance3D.new()
		var cyl := CylinderMesh.new()
		cyl.top_radius = 0.08; cyl.bottom_radius = 0.1; cyl.height = 2.4
		post.mesh = cyl
		post.position = Vector3(side * 1.2, 1.2, -0.5)
		post.material_override = MatCache.flat(Color(0.35, 0.24, 0.14))
		add_child(post)

	var awning := MeshInstance3D.new()
	var abox := BoxMesh.new()
	abox.size = Vector3(2.8, 0.08, 1.4)
	awning.mesh = abox
	awning.position = Vector3(0, 2.35, -0.5)
	awning.material_override = MatCache.flat(Color(0.75, 0.30, 0.22))
	add_child(awning)

	var label := Label3D.new()
	label.text = "Trading Post"
	label.position = Vector3(0, 3.0, 0)
	label.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	label.modulate = Color(0.92, 0.72, 0.32)
	add_child(label)
