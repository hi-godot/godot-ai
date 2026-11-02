@tool
extends Resource

var destination: String

@export var payload: int:
	get:
		if not destination.is_empty():
			var output := FileAccess.open(destination, FileAccess.WRITE)
			output.store_string("arrived during staging")
			output.close()
			destination = ""
		return 17
