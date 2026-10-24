extends Control

var settings_dialog : AcceptDialog
func _ready() -> void:
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	
	settings_dialog = AcceptDialog.new()
	settings_dialog.title = "SETTINGS"
	settings_dialog.dialog_text = "Settings Dialogue Text Here"
	add_child(settings_dialog)

func _on_play_pressed() -> void:
	get_tree().change_scene_to_file("res://scenes/world.tscn")

func _on_settings_pressed() -> void:
	settings_dialog.popup_centered()


func _on_quit_pressed() -> void:
	get_tree().quit()
