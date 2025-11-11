extends Node3D

const SPEED = 40.0
const DAMAGE = 34  # Enough to kill in 3 hits (100/34 ≈ 3)

@onready var mesh = $MeshInstance3D
@onready var ray = $RayCast3D
@onready var particles = $GPUParticles3D
var shooter: Node  # Reference to the player who shot this bullet

# Called when the node enters the scene tree for the first time.
func _ready():
	# Auto-destroy after 5 seconds if it doesn't hit anything
	get_tree().create_timer(5.0).timeout.connect(queue_free)

# Called every frame. 'delta' is the elapsed time since the previous frame.
func _process(delta):
	position += transform.basis * Vector3(0, 0, -SPEED) * delta
	
	if ray.is_colliding():
		var collider = ray.get_collider()
		
		# Check if we hit a player
		if collider and collider.has_method("take_damage"):
			# Make sure we don't damage the shooter
			if collider != shooter:
				collider.take_damage(DAMAGE)
				# Optional: Pass shooter reference for kill tracking
				if collider.has_method("set_last_attacker"):
					collider.set_last_attacker(shooter)
		
		# Visual effects for hit
		mesh.visible = false
		particles.emitting = true
		
		# Disable further collisions
		ray.enabled = false
		set_process(false)
		
		await get_tree().create_timer(1.0).timeout
		queue_free()

# Call this when instantiating the bullet to set who shot it
func set_shooter(player_node: Node):
	shooter = player_node

func _on_timer_timeout():
	queue_free()
