## NoclipPlayer — camera controller with walk mode and noclip toggle.
##
## F4           : toggle noclip / walk
## WASD         : move
## Mouse        : look (captured on click, released on Escape)
## Shift        : sprint
## Space        : jump  (walk mode only)
## Q / E        : up / down (noclip only)
## Scroll wheel : adjust noclip speed
class_name NoclipPlayer
extends Camera3D

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------

@export var walk_speed_m_s: float    = 1.4   ## normal walking pace
@export var sprint_speed_m_s: float  = 5.5   ## running pace
@export var jump_velocity_m_s: float = 4.5
@export var eye_height_m: float      = 1.7   ## camera above ground

@export var noclip_base_speed_m_s: float  = 50.0
@export var noclip_sprint_mult: float     = 5.0

@export var mouse_sensitivity: float = 0.002  ## radians per pixel

# ---------------------------------------------------------------------------
# Private state
# ---------------------------------------------------------------------------

const GRAVITY: float = 9.8

var _noclip: bool         = false
var _mouse_captured: bool = false
var _pitch: float         = 0.0
var _vertical_vel: float  = 0.0
var _on_ground: bool      = false

@onready var _terrain: Terrain = get_node("../Terrain")

# ---------------------------------------------------------------------------
# Lifecycle
# ---------------------------------------------------------------------------

func _ready() -> void:
	_capture_mouse()


func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventMouseButton and event.pressed:
		if not _mouse_captured:
			_capture_mouse()
			return

	if event.is_action_pressed("ui_cancel"):
		_release_mouse()
		return

	if event.is_action_pressed("toggle_noclip"):
		_toggle_noclip()
		return

	if event is InputEventMouseMotion and _mouse_captured:
		_apply_mouse_look(event.relative)

	if event is InputEventMouseButton and _mouse_captured and _noclip:
		_apply_scroll(event)


func _process(delta: float) -> void:
	if not _mouse_captured:
		return

	if _noclip:
		_process_noclip(delta)
	else:
		_process_walk(delta)

	WorldEvents.player_moved.emit(global_position)


# ---------------------------------------------------------------------------
# Noclip mode
# ---------------------------------------------------------------------------

func _process_noclip(delta: float) -> void:
	var dir := _noclip_direction()
	if dir == Vector3.ZERO:
		return
	var speed := noclip_base_speed_m_s
	if Input.is_action_pressed("sprint"):
		speed *= noclip_sprint_mult
	global_position += global_transform.basis * dir * speed * delta


func _noclip_direction() -> Vector3:
	var dir := Vector3.ZERO
	if Input.is_action_pressed("move_forward"): dir += Vector3.FORWARD
	if Input.is_action_pressed("move_back"):    dir -= Vector3.FORWARD
	if Input.is_action_pressed("move_left"):    dir -= Vector3.RIGHT
	if Input.is_action_pressed("move_right"):   dir += Vector3.RIGHT
	if Input.is_action_pressed("move_up"):      dir += Vector3.UP
	if Input.is_action_pressed("move_down"):    dir -= Vector3.UP
	return dir.normalized()


# ---------------------------------------------------------------------------
# Walk mode
# ---------------------------------------------------------------------------

func _process_walk(delta: float) -> void:
	# Horizontal movement — use camera yaw only so looking up doesn't lift.
	var yaw_basis := Basis(Vector3.UP, rotation.y)
	var h_dir := Vector2.ZERO
	if Input.is_action_pressed("move_forward"): h_dir.y -= 1.0
	if Input.is_action_pressed("move_back"):    h_dir.y += 1.0
	if Input.is_action_pressed("move_left"):    h_dir.x -= 1.0
	if Input.is_action_pressed("move_right"):   h_dir.x += 1.0

	var speed := sprint_speed_m_s if Input.is_action_pressed("sprint") else walk_speed_m_s
	var move_3d := Vector3.ZERO
	if h_dir != Vector2.ZERO:
		h_dir = h_dir.normalized()
		move_3d = yaw_basis * Vector3(h_dir.x, 0.0, h_dir.y)

	# Jump.
	if _on_ground and Input.is_action_just_pressed("jump"):
		_vertical_vel = jump_velocity_m_s
		_on_ground = false

	# Gravity.
	if not _on_ground:
		_vertical_vel -= GRAVITY * delta

	# Apply movement.
	var new_pos := global_position
	new_pos += move_3d * speed * delta
	new_pos.y += _vertical_vel * delta

	# Snap to terrain.
	var ground_y: float = _terrain.sample_height(new_pos.x, new_pos.z) + eye_height_m if _terrain else eye_height_m
	if new_pos.y <= ground_y:
		new_pos.y    = ground_y
		_vertical_vel = 0.0
		_on_ground    = true

	global_position = new_pos


# ---------------------------------------------------------------------------
# Toggle
# ---------------------------------------------------------------------------

func _toggle_noclip() -> void:
	_noclip = not _noclip
	_vertical_vel = 0.0
	_on_ground    = false
	print("NoclipPlayer: noclip %s" % ("ON" if _noclip else "OFF"))


# ---------------------------------------------------------------------------
# Mouse capture
# ---------------------------------------------------------------------------

func _capture_mouse() -> void:
	Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
	_mouse_captured = true


func _release_mouse() -> void:
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	_mouse_captured = false


# ---------------------------------------------------------------------------
# Look
# ---------------------------------------------------------------------------

func _apply_mouse_look(relative: Vector2) -> void:
	rotate_y(-relative.x * mouse_sensitivity)
	_pitch = clamp(
		_pitch - relative.y * mouse_sensitivity,
		-PI * 0.45,
		PI * 0.45,
	)
	rotation.x = _pitch


func _apply_scroll(event: InputEventMouseButton) -> void:
	if event.button_index == MOUSE_BUTTON_WHEEL_UP:
		noclip_base_speed_m_s = minf(noclip_base_speed_m_s * 1.2, 2000.0)
	elif event.button_index == MOUSE_BUTTON_WHEEL_DOWN:
		noclip_base_speed_m_s = maxf(noclip_base_speed_m_s / 1.2, 5.0)
