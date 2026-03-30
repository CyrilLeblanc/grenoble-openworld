## NoclipPlayer — free-flying camera controller.
##
## Move: WASD + Q/E (up/down)
## Look: mouse (captured on click, released on Escape)
## Speed: scroll wheel or shift for sprint
class_name NoclipPlayer
extends Camera3D

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------

@export var base_speed_m_s: float  = 50.0
@export var sprint_multiplier: float = 5.0
@export var mouse_sensitivity: float = 0.002  ## radians per pixel

# ---------------------------------------------------------------------------
# Private state
# ---------------------------------------------------------------------------

var _mouse_captured: bool = false
var _pitch: float = 0.0  ## accumulated vertical angle (clamped)

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

	if event is InputEventMouseMotion and _mouse_captured:
		_apply_mouse_look(event.relative)

	if event is InputEventMouseButton and _mouse_captured:
		_apply_scroll(event)


func _process(delta: float) -> void:
	if not _mouse_captured:
		return

	var direction := _input_direction()
	if direction == Vector3.ZERO:
		return

	var speed := base_speed_m_s
	if Input.is_action_pressed("sprint"):
		speed *= sprint_multiplier

	global_position += global_transform.basis * direction * speed * delta
	WorldEvents.player_moved.emit(global_position)


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
	# Yaw: rotate the camera around world Y
	rotate_y(-relative.x * mouse_sensitivity)

	# Pitch: rotate around local X, clamped to avoid flipping
	_pitch = clamp(
		_pitch - relative.y * mouse_sensitivity,
		-PI * 0.45,
		PI * 0.45,
	)
	rotation.x = _pitch


func _apply_scroll(event: InputEventMouseButton) -> void:
	if event.button_index == MOUSE_BUTTON_WHEEL_UP:
		base_speed_m_s = minf(base_speed_m_s * 1.2, 2000.0)
	elif event.button_index == MOUSE_BUTTON_WHEEL_DOWN:
		base_speed_m_s = maxf(base_speed_m_s / 1.2, 5.0)


# ---------------------------------------------------------------------------
# Input direction
# ---------------------------------------------------------------------------

func _input_direction() -> Vector3:
	var dir := Vector3.ZERO
	if Input.is_action_pressed("move_forward"):  dir += Vector3.FORWARD
	if Input.is_action_pressed("move_back"):     dir -= Vector3.FORWARD
	if Input.is_action_pressed("move_left"):     dir -= Vector3.RIGHT
	if Input.is_action_pressed("move_right"):    dir += Vector3.RIGHT
	if Input.is_action_pressed("move_up"):       dir += Vector3.UP
	if Input.is_action_pressed("move_down"):     dir -= Vector3.UP
	return dir.normalized()
