extends CharacterBody3D

# === SETTINGS ===
@export var controller_id := 1

const SPEED = 6.0
const SPRINT_MULTIPLIER = 1.8
const JUMP_VELOCITY = 5.5
const SENSITIVITY = 3.0
var gravity = 9.8

@export var walk_bob_frequency := 6.0
@export var walk_bob_amplitude := 0.03
@export var idle_bob_frequency := 2.0
@export var idle_bob_amplitude := 0.015
@export var bob_smoothness := 6.0

@export var fire_rate := 0.2
@export var bullet_scene: PackedScene = preload("res://weapons/bullet.tscn")

# --- HEALTH SYSTEM ---
@export var max_health := 100
var health := max_health

# --- RESPAWN SYSTEM ---
@export var respawn_time := 3.0
@export var spawn_points_parent: Node       # Assign in Inspector
var spawn_points: Array = []

# --- KILLS SYSTEM ---
@export var kills := 0
@export var max_kills := 5
var last_attacker: Node = null

# --- NODES ---
@onready var head: Node3D = $Head
@onready var camera: Camera3D = $Head/Camera3D
@onready var gun_anim: AnimationPlayer = $Head/Camera3D/rifle/AnimationPlayer
@onready var gun_barrel: RayCast3D = $Head/Camera3D/rifle/RayCast3D
@onready var player_mesh: MeshInstance3D = $MeshInstance3D
@onready var death_particles: GPUParticles3D = $DeathParticles

# --- INTERNAL ---
var can_shoot := true
var bob_time := 0.0
var default_head_position: Vector3

func _ready():
	default_head_position = head.position

	# Setup spawn points
	if spawn_points_parent:
		spawn_points = spawn_points_parent.get_children()
	else:
		print("Warning: spawn_points_parent not assigned in Inspector!")

	randomize()
	spawn_player()

# --- PHYSICS & MOVEMENT ---
func _physics_process(_delta):
	if health <= 0:
		return

	# Gravity
	if not is_on_floor():
		velocity.y -= gravity * _delta

	# Movement input
	var move_input = Vector2(
		Input.get_joy_axis(controller_id, JOY_AXIS_LEFT_X),
		-Input.get_joy_axis(controller_id, JOY_AXIS_LEFT_Y)  # invert Y
	)

	if move_input.length() < 0.15:
		move_input = Vector2.ZERO

	var forward = -head.global_transform.basis.z
	var right = head.global_transform.basis.x
	forward.y = 0
	right.y = 0
	forward = forward.normalized()
	right = right.normalized()
	var move_dir = (right * move_input.x + forward * move_input.y)
	if move_dir.length() > 1:
		move_dir = move_dir.normalized()

	var current_speed = SPEED
	if Input.is_joy_button_pressed(controller_id, JOY_BUTTON_LEFT_STICK):
		current_speed *= SPRINT_MULTIPLIER

	if is_on_floor():
		velocity.x = move_toward(velocity.x, move_dir.x * current_speed, current_speed * _delta * 5)
		velocity.z = move_toward(velocity.z, move_dir.z * current_speed, current_speed * _delta * 5)

	# Jump
	if Input.is_joy_button_pressed(controller_id, JOY_BUTTON_A) and is_on_floor():
		velocity.y = JUMP_VELOCITY

	move_and_slide()

	# Camera bob
	var horizontal_speed = Vector2(velocity.x, velocity.z).length()
	var moving = horizontal_speed > 0.1 and is_on_floor()
	var freq = walk_bob_frequency if moving else idle_bob_frequency
	var amp = walk_bob_amplitude if moving else idle_bob_amplitude
	bob_time += _delta * freq
	var vertical_bob = sin(bob_time * PI * 2) * amp
	var side_bob = sin(bob_time * PI) * amp * 0.3
	var target_pos = default_head_position + Vector3(side_bob, vertical_bob, 0)
	head.position = head.position.lerp(target_pos, _delta * bob_smoothness)

# --- LOOK & SHOOT ---
func _process(_delta):
	if health <= 0:
		return

	# Look input
	var look_x = Input.get_joy_axis(controller_id, JOY_AXIS_RIGHT_X)
	var look_y = Input.get_joy_axis(controller_id, JOY_AXIS_RIGHT_Y)
	if abs(look_x) < 0.1:
		look_x = 0
	if abs(look_y) < 0.1:
		look_y = 0

	head.rotate_y(-look_x * SENSITIVITY * _delta)
	camera.rotate_x(-look_y * SENSITIVITY * _delta)
	camera.rotation.x = clamp(camera.rotation.x, deg_to_rad(-60), deg_to_rad(60))

	# Shoot input
	var trigger_value = Input.get_joy_axis(controller_id, JOY_AXIS_TRIGGER_RIGHT)
	if trigger_value > 0.5 and can_shoot:
		shoot()

# --- SHOOT ---
func shoot():
	if not can_shoot or health <= 0:
		return
	can_shoot = false

	if gun_anim and gun_anim.has_animation("shoot"):
		gun_anim.play("shoot")

	if bullet_scene and gun_barrel:
		var bullet = bullet_scene.instantiate()
		bullet.global_transform = gun_barrel.global_transform
		get_tree().current_scene.add_child(bullet)

		if bullet.has_method("set_shooter"):
			bullet.set_shooter(self)

		if "direction" in bullet:
			bullet.direction = -gun_barrel.global_transform.basis.z.normalized()

	# Fire rate timer
	var t = Timer.new()
	t.one_shot = true
	t.wait_time = fire_rate
	t.connect("timeout", Callable(self, "_reset_shoot"))
	add_child(t)
	t.start()

func _reset_shoot():
	can_shoot = true

# --- HEALTH SYSTEM ---
func take_damage(amount: int):
	health -= amount
	health = max(health, 0)
	print("Player ", controller_id, " health: ", health)
	if health <= 0:
		die()

func set_last_attacker(attacker: Node):
	last_attacker = attacker

# --- DEATH & RESPAWN ---
func die():
	# Hide player visuals
	$Head.visible = false
	if player_mesh:
		player_mesh.visible = false

	# Disable collisions & processing
	$CollisionShape3D.disabled = true
	set_process(false)
	set_physics_process(false)

	# Play death particles
	if death_particles:
		death_particles.global_transform = global_transform
		death_particles.one_shot = true
		death_particles.emitting = true

	# Award kill to attacker
	if last_attacker and last_attacker.has_method("add_kill"):
		last_attacker.add_kill()
		print("Player ", last_attacker.controller_id, " killed Player ", controller_id)
	last_attacker = null

	# Respawn timer
	await get_tree().create_timer(respawn_time).timeout
	spawn_player()

func spawn_player():
	if spawn_points.size() == 0:
		return

	# Farthest spawn from death
	var death_pos = global_transform.origin
	var farthest_spawn = spawn_points[0]
	var max_distance = 0.0

	for sp in spawn_points:
		var dist = sp.global_transform.origin.distance_to(death_pos)
		if dist > max_distance:
			max_distance = dist
			farthest_spawn = sp

	global_transform.origin = farthest_spawn.global_transform.origin
	velocity = Vector3.ZERO
	health = max_health

	# Show visuals
	$Head.visible = true
	if player_mesh:
		player_mesh.visible = true

	# Re-enable collisions and processing
	$CollisionShape3D.disabled = false
	set_process(true)
	set_physics_process(true)

	print("Player ", controller_id, " respawned at: ", global_transform.origin)

# --- KILLS SYSTEM ---
func add_kill():
	kills += 1
	print("Player ", controller_id, " kills: ", kills)
	if kills >= max_kills:
		end_game()

func end_game():
	print("Player ", controller_id, " wins! Max kills reached.")
	set_process(false)
	set_physics_process(false)
	$Head.visible = false
	if player_mesh:
		player_mesh.visible = false
