@tool
extends Node

@export var bytes := PackedByteArray([7, 8])
@export var arrays: Array[PackedByteArray] = [PackedByteArray([9])]
@export var mapping: Dictionary[String, PackedByteArray] = {"original": PackedByteArray([10])}
