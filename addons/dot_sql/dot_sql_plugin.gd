@tool
extends EditorPlugin

## Editor entry point for dot-sql. Registers nothing.
##
## Every class here is a RefCounted a store is handed, not a node anybody places, and there
## are no autoloads: a process running two servers has two databases, or one shared by two
## drivers, and either is the host's decision.


func _enter_tree() -> void:
	pass


func _exit_tree() -> void:
	pass
