extends CharacterBody3D

# --- Basic physics ---
var gravity = -9.8
const SPEED = 5.0
const JUMP_VELOCITY = 4.5
const GROUND_ACCEL = 40.0      # ground friction and traction
const AIR_DRAG = 0.005         # drag: acceleration = AIR_DRAG * speed squared
var sensitivity = 0.003

# --- Web ---
const WEB_RANGE = 100.0         # how far the web can reach
const BODY_LEAN = 2.0          # small push from body movement in air (0 = none)
const WINCH_ACCEL = 50.0       # winch motor pull strength (in air)
const WINCH_MAX_SPEED = 50.0   # winch motor speed limit
const WEB_STOP_DIST = 3.0      # winch stops this close to anchor

# --- Elastic web (on ground) ---
const MAX_STRETCH = 20.0       # max extra length on ground (meters)
const LAUNCH_OMEGA = 3.0       # launch speed = stretch * this

# --- Cosmetic camera (not physics) ---
const BASE_FOV = 75.0
const MAX_FOV_BONUS = 20.0

# --- Web state ---
var web_active := false
var web_anchor := Vector3.ZERO
var rope_length := 0.0
var reeling := false
var stretch := 0.0
var was_on_floor := false

@onready var head = $Head
@onready var camera = $Head/Camera3D
@onready var web_line = $WebLine


func _ready():
	Input.set_mouse_mode(Input.MOUSE_MODE_CAPTURED)

	web_line.top_level = true
	web_line.global_transform = Transform3D.IDENTITY
	web_line.mesh = ImmediateMesh.new()
	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.albedo_color = Color.WHITE
	web_line.material_override = mat


func _unhandled_input(event):
	if event is InputEventMouseMotion:
		head.rotate_y(-event.relative.x * sensitivity)
		camera.rotate_x(-event.relative.y * sensitivity)
		camera.rotation.x = clamp(camera.rotation.x, deg_to_rad(-89), deg_to_rad(89))


func _physics_process(delta: float) -> void:
	var on_floor_now = is_on_floor()

	# Walked off a ledge while stretched: web goes taut at current length.
	# No launch. Only a jump launches.
	if was_on_floor and not on_floor_now and web_active:
		rope_length = max(rope_length, global_position.distance_to(web_anchor))
	was_on_floor = on_floor_now

	# Gravity
	if not on_floor_now:
		velocity.y += gravity * delta

	# Jump. If the web is stretched, the jump releases the tension.
	if Input.is_action_just_pressed("ui_accept") and on_floor_now:
		velocity.y = JUMP_VELOCITY
		if web_active:
			release_tension()

	handle_web_input()

	# Movement direction
	var input_dir = Input.get_vector("move_left", "move_right", "move_forward", "move_back")
	var direction = (head.transform.basis * Vector3(input_dir.x, 0, input_dir.y)).normalized()

	if on_floor_now:
		# Walking. Friction pulls you toward walking speed.
		velocity.x = move_toward(velocity.x, direction.x * SPEED, GROUND_ACCEL * delta)
		velocity.z = move_toward(velocity.z, direction.z * SPEED, GROUND_ACCEL * delta)
	else:
		# In air: no steering. Only drag slows you.
		apply_air_drag(delta)

	if web_active:
		if not on_floor_now:
			velocity += direction * BODY_LEAN * delta
		apply_web(delta)
	else:
		stretch = 0.0

	move_and_slide()
	update_web_line()
	update_fov(delta)


func apply_air_drag(delta: float) -> void:
	var speed = velocity.length()
	if speed < 0.01:
		return
	var drag_accel = AIR_DRAG * speed * speed
	var slow = min(drag_accel * delta, speed)
	velocity -= velocity.normalized() * slow


func handle_web_input() -> void:
	var swing_held = Input.is_action_pressed("web_swing")
	var pull_held = Input.is_action_pressed("web_pull")
	var just_pressed = Input.is_action_just_pressed("web_swing") or Input.is_action_just_pressed("web_pull")

	# Shoot on first press
	if just_pressed and not web_active:
		shoot_web()

	# Cut web when both buttons are up. Stored tension is lost.
	if web_active and not swing_held and not pull_held:
		web_active = false
		stretch = 0.0

	# Winch only works in the air.
	reeling = web_active and pull_held and not is_on_floor()


func shoot_web() -> void:
	# Exact aim. Web sticks only to what the crosshair touches.
	var space = get_world_3d().direct_space_state
	var origin = camera.global_position
	var forward = -camera.global_transform.basis.z
	var query = PhysicsRayQueryParameters3D.create(origin, origin + forward * WEB_RANGE)
	query.exclude = [get_rid()]
	var hit = space.intersect_ray(query)
	if hit:
		web_anchor = hit.position
		rope_length = global_position.distance_to(web_anchor)
		web_active = true
		stretch = 0.0


func release_tension() -> void:
	# Stretched web snaps back toward the anchor and pulls you with it.
	var to_anchor = web_anchor - global_position
	var dist = to_anchor.length()
	var amount = max(dist - rope_length, 0.0)
	if amount <= 0.0 or dist < 0.01:
		return
	velocity += (to_anchor / dist) * amount * LAUNCH_OMEGA
	rope_length = dist   # web is now slack and relaxed at current length
	stretch = 0.0


func apply_web(delta: float) -> void:
	var to_anchor = web_anchor - global_position
	var dist = to_anchor.length()
	if dist < 0.01:
		return
	var rope_dir = to_anchor / dist   # unit vector toward anchor

	# Winch (in air only): motor with limited force and limited speed
	if reeling:
		if dist < WEB_STOP_DIST:
			web_active = false
			reeling = false
			stretch = 0.0
			return
		rope_length = min(rope_length, dist)
		if velocity.dot(rope_dir) < WINCH_MAX_SPEED:
			velocity += rope_dir * WINCH_ACCEL * delta

	if is_on_floor():
		# GROUND: elastic web. Stretch builds as you walk away.
		var max_len = rope_length + MAX_STRETCH
		stretch = clamp(dist - rope_length, 0.0, MAX_STRETCH)

		# At max tension: stop moving AWAY from the anchor (flat only).
		# Sideways and toward-anchor movement still work. Tension stays at max.
		if dist >= max_len:
			var flat = Vector3(to_anchor.x, 0.0, to_anchor.z)
			if flat.length() > 0.01:
				var flat_dir = flat.normalized()
				var away = -(velocity.x * flat_dir.x + velocity.z * flat_dir.z)
				if away > 0.0:
					velocity.x += flat_dir.x * away
					velocity.z += flat_dir.z * away
				global_position += flat_dir * (dist - max_len)
	else:
		# AIR: rigid rope. Only acts when taut. Slack rope does nothing.
		stretch = 0.0
		if dist > rope_length:
			var away = -velocity.dot(rope_dir)   # speed moving away from anchor
			if away > 0.0:
				velocity += rope_dir * away      # rope cancels it. Energy is lost.
			global_position += rope_dir * (dist - rope_length)


func update_web_line() -> void:
	var m = web_line.mesh as ImmediateMesh
	m.clear_surfaces()
	if not web_active:
		return

	# White = normal. Cyan = winch. White to red-orange = stretch (tension).
	var color = Color.WHITE
	if reeling:
		color = Color.CYAN
	elif stretch > 0.0:
		color = Color.WHITE.lerp(Color.ORANGE_RED, stretch / MAX_STRETCH)
	web_line.material_override.albedo_color = color

	var hand = camera.global_position + camera.global_transform.basis * Vector3(0.3, -0.3, -0.5)
	m.surface_begin(Mesh.PRIMITIVE_LINES)
	m.surface_add_vertex(hand)
	m.surface_add_vertex(web_anchor)
	m.surface_end()


func update_fov(delta: float) -> void:
	# Cosmetic only. Delete this function and its call to remove.
	var speed_ratio = clamp(velocity.length(), 0.0, 40.0) / 40.0
	var target = BASE_FOV + speed_ratio * MAX_FOV_BONUS
	camera.fov = lerp(camera.fov, target, 4.0 * delta)
