@tool
extends RefCounted

## Handler for raid_map_blockout: lays out rooms and corridors on a 1 m
## grid, turns them into floor / wall / cover blocks (StaticBody3D boxes, so
## bullets, sight rays and the navigation bake all see them), and places the
## player spawn, enemy spawns (optionally enemy instances with a patrol
## route per room), loot crates (optionally with a LootDropper) and
## extraction zones. The whole map is one node, added as one undo step.

const Util := preload("res://addons/topdown_shooter_tools/handlers/scaffold_util.gd")

const DEFAULT_SCRIPT_DIR := "res://scripts/topdown"
const DEFAULT_LOOT_DIR := "res://data/loot"
const NAV_SOURCE_GROUP := &"navigation_source"
## Free border (meters) between a room's walls and its cover / crates /
## spawns, so a walkable ring always links every doorway.
const ROOM_MARGIN := 1.5
const MAX_GRID := 512

const COLORS := {
	"room": Color(0.56, 0.57, 0.6),
	"corridor": Color(0.42, 0.43, 0.47),
	"wall": Color(0.3, 0.32, 0.37),
	"cover": Color(0.52, 0.44, 0.32),
	"pillar": Color(0.36, 0.37, 0.42),
	"crate": Color(0.62, 0.5, 0.22),
	"extraction": Color(0.2, 1.0, 0.45, 0.35),
}

## name -> [footprint_x, footprint_z, height (-1 = wall height)]
const COVER_SHAPES := {
	"low_wall": [3.0, 0.6, 1.1],
	"box": [1.4, 1.4, 1.3],
	"pillar": [1.0, 1.0, -1.0],
}

var _meshes := {}
var _shapes := {}
var _materials := {}


func quiesce_for_script_swap() -> Dictionary:
	return {"ok": true}


func raid_map_blockout(params: Dictionary, _ctx = null) -> Dictionary:
	var p: Variant = _read_params(params)
	if Util.is_error(p):
		return p
	var layout: Variant = _plan(p)
	if Util.is_error(layout):
		return layout

	var root := Util.edited_root()
	var report := _report(p, layout)
	if p.dry_run:
		report["status"] = "dry_run"
		return {"data": report}
	if root == null:
		return Util.no_scene_error()
	if not root is Node3D:
		return Util.error(Util.INVALID_PARAMS, "the open scene's root is a %s; open a 3D scene" % root.get_class())
	var parent := Util.resolve(p.parent_path, root)
	if parent == null:
		return Util.error(Util.NODE_NOT_FOUND, "parent_path '%s' not found in the edited scene" % p.parent_path)
	if not parent is Node3D:
		return Util.error(Util.INVALID_PARAMS, "parent_path '%s' is not a 3D node" % p.parent_path)
	var old := parent.get_node_or_null(NodePath(p.name))
	if old != null and not p.replace:
		return Util.error(Util.ALREADY_EXISTS, "%s already has a '%s'; pass replace=true to rebuild it (one undo step) or pick another name" % [Util.scene_path_of(parent, root), p.name])
	if old == root or (old != null and old.is_ancestor_of(parent)):
		return Util.error(Util.INVALID_PARAMS, "cannot replace '%s': it contains parent_path" % p.name)

	## --- load everything before writing ------------------------------------
	var enemy_packed := []
	for path in p.enemy_scenes:
		var packed := ResourceLoader.load(path, "PackedScene") as PackedScene
		if packed == null:
			return Util.error(Util.INVALID_PARAMS, "enemy scene %s is not a scene" % path)
		enemy_packed.append(packed)
	var loot_table: Resource = null
	if not p.crate_loot_table.is_empty() and layout.crates.size() > 0:
		loot_table = ResourceLoader.load(p.crate_loot_table)
		if loot_table == null or not loot_table.has_method("roll"):
			return Util.error(Util.INVALID_PARAMS, "%s is not a loot table (make one with loot_table_edit)" % p.crate_loot_table)

	var warnings: Array = report.warnings
	var scripts := {}
	var script_dir: String = p.script_dir
	var wanted := []
	if not layout.crates.is_empty():
		wanted.append(["loot_crate.gd.tmpl", "loot_crate.gd"])
		if loot_table != null:
			wanted.append(["loot_dropper.gd.tmpl", "loot_dropper.gd"])
			wanted.append(["loot_pickup.gd.tmpl", "loot_pickup.gd"])
	if not layout.extractions.is_empty():
		wanted.append(["raid_extraction.gd.tmpl", "raid_extraction.gd"])
	for w in wanted:
		var installed := Util.install_script(w[0], script_dir + "/" + w[1], p.overwrite_scripts)
		if Util.is_error(installed):
			return installed
		scripts[w[1]] = installed
	var written := []
	for key in scripts:
		if scripts[key].status != "kept":
			written.append(scripts[key].path)
	Util.refresh_filesystem(written)
	report["scripts"] = {}
	for key in scripts:
		report.scripts[scripts[key].path] = scripts[key].status

	var input_report := {}
	if not layout.crates.is_empty() and p.create_input_action:
		input_report = _ensure_interact_action(p.interact_action)
		if Util.is_error(input_report):
			return input_report
		report["input_actions"] = input_report

	## --- build ---------------------------------------------------------------
	var map := _build_map(p, layout, scripts, loot_table, enemy_packed, parent, report)
	var player := _find_player(root)
	var props := []
	if player != null and p.move_player and not map.is_ancestor_of(player):
		var world: Vector3 = (parent as Node3D).global_transform * (p.origin + layout.player_spawn)
		var local: Vector3 = world
		if player.get_parent() is Node3D:
			local = (player.get_parent() as Node3D).global_transform.affine_inverse() * world
		props.append([player, "position", local, player.position])
		report["player_moved"] = {"path": Util.scene_path_of(player, root), "to": _arr(world)}
	elif player == null:
		warnings.append("No node in group 'player' in the scene: make one with player_controller_scaffold and place it at PlayerSpawn %s." % str(_arr(p.origin + layout.player_spawn)))

	## Navigation source: the map must sit under a node of the region's
	## source group, or the bake would not see it.
	var regions := _navigation_regions(root)
	var region: NavigationRegion3D = regions[0] if not regions.is_empty() else null
	var new_region: NavigationRegion3D = null
	var group_name := NAV_SOURCE_GROUP
	if region != null and region.navigation_mesh != null and region.navigation_mesh.geometry_source_geometry_mode != NavigationMesh.SOURCE_GEOMETRY_ROOT_NODE_CHILDREN:
		group_name = region.navigation_mesh.geometry_source_group_name
	if p.setup_navigation:
		if region == null:
			new_region = _build_nav_region(Util.unique_child_name(root, "Navigation"))
		if not _under_group(parent, group_name, root):
			map.add_to_group(group_name, true)
	if region != null and region.navigation_mesh != null and region.navigation_mesh.geometry_source_geometry_mode == NavigationMesh.SOURCE_GEOMETRY_ROOT_NODE_CHILDREN and not region.is_ancestor_of(parent):
		warnings.append("%s bakes only its own children, so it ignores the map. Move the map under it or switch its NavigationMesh source to a group." % Util.scene_path_of(region, root))

	_commit(p, parent, map, old, root, props, new_region)

	report["status"] = "replaced" if old != null else "created"
	report["map_path"] = Util.scene_path_of(map, root)
	if p.setup_navigation:
		if new_region != null:
			report["navigation"] = _bake_new(new_region, root)
		elif region != null:
			report["navigation"] = _rebake(region, root)
	else:
		report["navigation"] = {"status": "skipped"}
	_check_outside_enemies(root, map, layout, p, parent, warnings)
	report["next_steps"] = _next_steps(p, layout, report)
	var undo := "One undo removes the map%s." % (" and restores the previous one" if old != null else "")
	if report.navigation.get("status", "") == "rebaked":
		undo += " The navigation rebake is its own undo step, undone first."
	report["undo"] = undo
	return {"data": report}


# =============================================================================
# params
# =============================================================================

func _read_params(params: Dictionary) -> Variant:
	var p := {}
	for spec in [
		["room_count", 6, 1, 64],
		["room_size_min", 8, 4, 100],
		["room_size_max", 14, 4, 100],
		["room_gap", 6, 1, 100],
		["corridor_width", 3, 2, 12],
		["extra_connections", 1, 0, 64],
		["cover_per_room", 3, 0, 32],
		["crates_per_room", 1, 0, 32],
		["enemies_per_room", 1, 0, 32],
		["extraction_count", 1, 0, 16],
	]:
		var v: Variant = Util.integer(params, spec[0], spec[1], spec[2], spec[3])
		if Util.is_error(v):
			return v
		p[spec[0]] = v
	for spec in [
		["wall_height", 3.0, 0.5, 20.0],
		["wall_thickness", 0.4, 0.1, 1.0],
		["floor_thickness", 0.5, 0.05, 5.0],
		["crate_search_time", 1.0, 0.0, 30.0],
		["extract_time", 5.0, 0.0, 120.0],
		["extraction_radius", 2.0, 0.5, 10.0],
		["restart_delay", 4.0, 0.0, 60.0],
	]:
		var v: Variant = Util.num(params, spec[0], spec[1], spec[2], spec[3])
		if Util.is_error(v):
			return v
		p[spec[0]] = v
	for spec in [
		["build_floor", true], ["move_player", true], ["enemy_patrol", true],
		["setup_navigation", true], ["add_light", true], ["replace", false],
		["create_input_action", true], ["overwrite_scripts", false], ["dry_run", false],
	]:
		var v: Variant = Util.boolean(params, spec[0], spec[1])
		if Util.is_error(v):
			return v
		p[spec[0]] = v
	for spec in [
		["name", "RaidMap"], ["parent_path", ""], ["crate_loot_table", ""],
		["script_dir", DEFAULT_SCRIPT_DIR], ["interact_action", "interact"],
	]:
		var v: Variant = Util.text(params, spec[0], spec[1])
		if Util.is_error(v):
			return v
		p[spec[0]] = v
	var origin: Variant = Util.vec3(params, "origin", Vector3.ZERO)
	if Util.is_error(origin):
		return origin
	p["origin"] = origin
	if p.room_size_min > p.room_size_max:
		return Util.error(Util.INVALID_PARAMS, "'room_size_min' (%d) is larger than 'room_size_max' (%d)" % [p.room_size_min, p.room_size_max])
	if p.name.is_empty() or p.name.validate_node_name() != p.name:
		return Util.error(Util.INVALID_PARAMS, "'name' must be a valid node name")
	if p.interact_action.is_empty() or not p.interact_action.is_valid_identifier():
		return Util.error(Util.INVALID_PARAMS, "'interact_action' must be letters, digits and underscores")
	p.script_dir = Util.clean_dir(p.script_dir)
	var reason := Util.check_res_path(p.script_dir + "/x.gd", "gd")
	if not reason.is_empty():
		return Util.error(Util.INVALID_PARAMS, "'script_dir': " + reason)

	var seed_value: Variant = Util.integer(params, "seed", -1, -1, 2147483647)
	if Util.is_error(seed_value):
		return seed_value
	p["seed"] = seed_value if seed_value >= 0 else (randi() & 0x7fffffff)

	## crate loot table: an id under res://data/loot or a res:// path.
	if not p.crate_loot_table.is_empty():
		var path: String = p.crate_loot_table
		if not path.begins_with("res://"):
			if not path.is_valid_identifier():
				return Util.error(Util.INVALID_PARAMS, "'crate_loot_table' must be a table id (e.g. crate) or a res:// .tres path")
			path = DEFAULT_LOOT_DIR + "/" + path + ".tres"
		if not ResourceLoader.exists(path):
			return Util.error(Util.NODE_NOT_FOUND, "loot table %s does not exist; make it with loot_table_edit first" % path)
		p.crate_loot_table = path

	var scenes: Variant = _string_list(params, "enemy_scenes")
	if Util.is_error(scenes):
		return scenes
	for path in scenes:
		if not path.begins_with("res://") or path.get_extension() != "tscn":
			return Util.error(Util.INVALID_PARAMS, "enemy scene '%s' must be a res:// .tscn (e.g. from enemy_ai_scaffold)" % path)
		if not ResourceLoader.exists(path):
			return Util.error(Util.NODE_NOT_FOUND, "enemy scene %s does not exist; create it with enemy_ai_scaffold first" % path)
	p["enemy_scenes"] = scenes

	var rooms: Variant = _parse_rooms(params)
	if Util.is_error(rooms):
		return rooms
	p["rooms"] = rooms
	for key in ["connections", "extraction_rooms"]:
		if params.has(key) and params[key] != null and not params[key] is Array:
			return Util.error(Util.INVALID_PARAMS, "'%s' must be a list" % key)
	p["connections"] = params.get("connections")
	p["extraction_rooms"] = params.get("extraction_rooms")
	p["player_spawn_room"] = params.get("player_spawn_room")
	return p


## Explicit rooms: [{name, position: [x, z] | [x, y, z], size: [w, d], cover,
## crates, enemies}]. Returns [] when the param is absent (generate instead).
func _parse_rooms(params: Dictionary) -> Variant:
	if not params.has("rooms") or params.rooms == null:
		return []
	if not params.rooms is Array or params.rooms.is_empty() or params.rooms.size() > 64:
		return Util.error(Util.INVALID_PARAMS, "'rooms' must be a list of 1 to 64 rooms")
	var out := []
	var names := {}
	for i in params.rooms.size():
		var r: Variant = params.rooms[i]
		if not r is Dictionary:
			return Util.error(Util.INVALID_PARAMS, "'rooms[%d]' must be an object" % i)
		var room_name: String = str(r.get("name", "Room%d" % (i + 1))).strip_edges()
		if room_name.is_empty() or room_name.validate_node_name() != room_name or names.has(room_name):
			return Util.error(Util.INVALID_PARAMS, "'rooms[%d].name' must be a unique node name" % i)
		names[room_name] = true
		var pos: Variant = r.get("position")
		var size: Variant = r.get("size")
		if not (pos is Array and pos.size() in [2, 3] and _all_numbers(pos)):
			return Util.error(Util.INVALID_PARAMS, "'rooms[%d].position' must be [x, z] (room center)" % i)
		if not (size is Array and size.size() in [2, 3] and _all_numbers(size)):
			return Util.error(Util.INVALID_PARAMS, "'rooms[%d].size' must be [width, depth] in meters" % i)
		var w := int(round(float(size[0])))
		var d := int(round(float(size[size.size() - 1])))
		if w < 4 or d < 4 or w > 200 or d > 200:
			return Util.error(Util.INVALID_PARAMS, "'rooms[%d].size' must be 4 to 200 meters per side" % i)
		var cx := float(pos[0])
		var cz := float(pos[pos.size() - 1])
		var room := {"name": room_name, "rect": Rect2i(int(round(cx - w / 2.0)), int(round(cz - d / 2.0)), w, d)}
		for key in ["cover", "crates", "enemies"]:
			if r.has(key):
				var v: Variant = Util.integer(r, key, 0, 0, 32)
				if Util.is_error(v):
					return Util.error(Util.INVALID_PARAMS, "'rooms[%d].%s' must be a whole number 0 to 32" % [i, key])
				room[key] = v
		for key in r:
			if key not in ["name", "position", "size", "cover", "crates", "enemies"]:
				return Util.error(Util.INVALID_PARAMS, "'rooms[%d]' has unknown key '%s'" % [i, key])
		out.append(room)
	return out


# =============================================================================
# layout (pure data, shared by dry_run and build)
# =============================================================================

func _plan(p: Dictionary) -> Variant:
	var rng := RandomNumberGenerator.new()
	rng.seed = p.seed
	var rooms: Array = p.rooms.duplicate(true)
	var generated := rooms.is_empty()
	var links := []
	if generated:
		var gen := _generate_rooms(p, rng)
		rooms = gen.rooms
		links = gen.links
	else:
		var parsed: Variant = _explicit_links(p, rooms)
		if Util.is_error(parsed):
			return parsed
		links = parsed

	## Spawn and extraction rooms.
	var spawn_index: Variant = _room_index(p.player_spawn_room, rooms, "player_spawn_room", 0)
	if Util.is_error(spawn_index):
		return spawn_index
	var extraction_indices := []
	if p.extraction_rooms != null:
		for v in p.extraction_rooms:
			var idx: Variant = _room_index(v, rooms, "extraction_rooms", -1)
			if Util.is_error(idx):
				return idx
			if idx not in extraction_indices:
				extraction_indices.append(idx)
	else:
		extraction_indices = _farthest_rooms(rooms, links, spawn_index, p.extraction_count)

	## Rasterize rooms (1) and corridors (2) on a 1 m grid with a free border.
	var corridor_rects := []
	for link in links:
		corridor_rects.append_array(_corridor_rects(rooms[link[0]].rect, rooms[link[1]].rect, p.corridor_width))
	var bounds: Rect2i = rooms[0].rect
	for r in rooms:
		bounds = bounds.merge(r.rect)
	for r in corridor_rects:
		bounds = bounds.merge(r)
	bounds = bounds.grow(1)
	if bounds.size.x > MAX_GRID or bounds.size.y > MAX_GRID:
		return Util.error(Util.INVALID_PARAMS, "map is %dx%d m; the limit is %d m per side (fewer or smaller rooms)" % [bounds.size.x, bounds.size.y, MAX_GRID])
	var grid := {"x0": bounds.position.x, "z0": bounds.position.y, "w": bounds.size.x, "h": bounds.size.y, "cells": PackedByteArray()}
	grid.cells.resize(grid.w * grid.h)
	for r in rooms:
		_fill(grid, r.rect, 1, true)
	for r in corridor_rects:
		_fill(grid, r, 2, false)

	var layout := {
		"generated": generated,
		"rooms": rooms,
		"links": links,
		"grid": grid,
		"floors": _floor_rects(grid),
		"walls": _wall_boxes(grid, p.wall_thickness),
		"spawn_index": spawn_index,
		"extraction_indices": extraction_indices,
		"player_spawn": Vector3.ZERO,
		"extractions": [],
		"crates": [],
		"enemy_spawns": [],
		"cover": [],
		"skipped": [],
	}
	_place_props(p, layout, rng)
	return layout


func _generate_rooms(p: Dictionary, rng: RandomNumberGenerator) -> Dictionary:
	var n: int = p.room_count
	var cols := int(ceil(sqrt(float(n))))
	var rows := int(ceil(float(n) / cols))
	var slot: int = p.room_size_max + p.room_gap
	var rooms := []
	var cell_of := {}
	for i in n:
		var col := i % cols
		var row := i / cols
		var w := rng.randi_range(p.room_size_min, p.room_size_max)
		var d := rng.randi_range(p.room_size_min, p.room_size_max)
		var jx := rng.randi_range(-(p.room_size_max - w) / 2, (p.room_size_max - w) / 2)
		var jz := rng.randi_range(-(p.room_size_max - d) / 2, (p.room_size_max - d) / 2)
		## Row 0 is nearest the camera (+z); later rows go "up" the screen (-z).
		var cx := int(round((col - (cols - 1) / 2.0) * slot)) + jx
		var cz := int(round(((rows - 1) / 2.0 - row) * slot)) + jz
		rooms.append({"name": "Room%d" % (i + 1), "rect": Rect2i(cx - w / 2, cz - d / 2, w, d)})
		cell_of[Vector2i(col, row)] = i
	## Random spanning tree over grid neighbours, then a few extra loops.
	var candidates := []
	for i in n:
		var c := Vector2i(i % cols, i / cols)
		for dir in [Vector2i(1, 0), Vector2i(0, 1)]:
			if cell_of.has(c + dir):
				candidates.append([i, cell_of[c + dir]])
	_shuffle(candidates, rng)
	var links := _spanning_tree(n, candidates)
	_add_extra_links(links, candidates, p.extra_connections)
	return {"rooms": rooms, "links": links}


func _explicit_links(p: Dictionary, rooms: Array) -> Variant:
	if p.connections != null:
		var links := []
		for i in p.connections.size():
			var c: Variant = p.connections[i]
			if not (c is Array and c.size() == 2):
				return Util.error(Util.INVALID_PARAMS, "'connections[%d]' must be [room, room] (names or indices)" % i)
			var a: Variant = _room_index(c[0], rooms, "connections[%d]" % i, -1)
			var b: Variant = _room_index(c[1], rooms, "connections[%d]" % i, -1)
			for v in [a, b]:
				if Util.is_error(v):
					return v
			if a != b and not _has_link(links, a, b):
				links.append([a, b])
		return links
	## Minimum spanning tree by distance, then the shortest extra edges.
	var edges := []
	for a in rooms.size():
		for b in range(a + 1, rooms.size()):
			edges.append([a, b, Vector2(rooms[a].rect.get_center()).distance_to(Vector2(rooms[b].rect.get_center()))])
	edges.sort_custom(func(x, y): return x[2] < y[2])
	var pairs := []
	for e in edges:
		pairs.append([e[0], e[1]])
	var links := _spanning_tree(rooms.size(), pairs)
	_add_extra_links(links, pairs, p.extra_connections)
	return links


## Kruskal over `pairs` in the given order.
static func _spanning_tree(n: int, pairs: Array) -> Array:
	var parent := []
	for i in n:
		parent.append(i)
	var find := func(x: int) -> int:
		while parent[x] != x:
			x = parent[x]
		return x
	var links := []
	for pair in pairs:
		var ra: int = find.call(pair[0])
		var rb: int = find.call(pair[1])
		if ra != rb:
			parent[ra] = rb
			links.append([pair[0], pair[1]])
	return links


static func _add_extra_links(links: Array, pairs: Array, count: int) -> void:
	var added := 0
	for pair in pairs:
		if added >= count:
			return
		if not _has_link(links, pair[0], pair[1]):
			links.append([pair[0], pair[1]])
			added += 1


static func _has_link(links: Array, a: int, b: int) -> bool:
	for l in links:
		if (l[0] == a and l[1] == b) or (l[0] == b and l[1] == a):
			return true
	return false


## Rooms farthest (by corridor hops, then distance) from the spawn room.
static func _farthest_rooms(rooms: Array, links: Array, spawn: int, count: int) -> Array:
	if count <= 0:
		return []
	var hops := {spawn: 0}
	var queue := [spawn]
	while not queue.is_empty():
		var cur: int = queue.pop_front()
		for l in links:
			for k in 2:
				if l[k] == cur and not hops.has(l[1 - k]):
					hops[l[1 - k]] = hops[cur] + 1
					queue.append(l[1 - k])
	var order := []
	var origin := Vector2(rooms[spawn].rect.get_center())
	for i in rooms.size():
		if i != spawn or rooms.size() == 1:
			order.append([i, hops.get(i, 0), origin.distance_to(Vector2(rooms[i].rect.get_center()))])
	order.sort_custom(func(x, y): return x[1] > y[1] or (x[1] == y[1] and x[2] > y[2]))
	var out := []
	for o in order.slice(0, count):
		out.append(o[0])
	return out


## An L-shaped corridor (width cells) between two room centers: along the
## longer axis first, so neighbours get a straight run between facing walls.
static func _corridor_rects(a: Rect2i, b: Rect2i, width: int) -> Array:
	var ca := a.get_center()
	var cb := b.get_center()
	var half := width / 2
	var out := []
	if absi(cb.x - ca.x) >= absi(cb.y - ca.y):
		out.append(Rect2i(mini(ca.x, cb.x) - half, ca.y - half, absi(cb.x - ca.x) + width, width))
		out.append(Rect2i(cb.x - half, mini(ca.y, cb.y) - half, width, absi(cb.y - ca.y) + width))
	else:
		out.append(Rect2i(ca.x - half, mini(ca.y, cb.y) - half, width, absi(cb.y - ca.y) + width))
		out.append(Rect2i(mini(ca.x, cb.x) - half, cb.y - half, absi(cb.x - ca.x) + width, width))
	return out


static func _fill(grid: Dictionary, r: Rect2i, value: int, overwrite: bool) -> void:
	for z in range(r.position.y, r.end.y):
		for x in range(r.position.x, r.end.x):
			var i: int = (z - grid.z0) * grid.w + (x - grid.x0)
			if overwrite or grid.cells[i] == 0:
				grid.cells[i] = value


static func _cell(grid: Dictionary, i: int, j: int) -> int:
	if i < 0 or j < 0 or i >= grid.w or j >= grid.h:
		return 0
	return grid.cells[j * grid.w + i]


static func _walk(grid: Dictionary, i: int, j: int) -> bool:
	return _cell(grid, i, j) != 0


## Greedy merge of same-kind walkable cells into rectangles (world meters).
static func _floor_rects(grid: Dictionary) -> Array:
	var used := PackedByteArray()
	used.resize(grid.cells.size())
	var out := []
	for j in grid.h:
		for i in grid.w:
			var kind := _cell(grid, i, j)
			if kind == 0 or used[j * grid.w + i]:
				continue
			var w := 1
			while _cell(grid, i + w, j) == kind and not used[j * grid.w + i + w]:
				w += 1
			var h := 1
			var grow := true
			while grow:
				for k in w:
					if _cell(grid, i + k, j + h) != kind or used[(j + h) * grid.w + i + k]:
						grow = false
						break
				if grow:
					h += 1
			for jj in h:
				for k in w:
					used[(j + jj) * grid.w + i + k] = 1
			out.append({"kind": "room" if kind == 1 else "corridor", "rect": Rect2(grid.x0 + i, grid.z0 + j, w, h)})
	return out


## Wall boxes along every edge between walkable and empty cells, merged into
## runs. Each sits on the empty side; horizontal runs stretch over outer
## corners so the corners are closed.
static func _wall_boxes(grid: Dictionary, t: float) -> Array:
	var out := []
	## Edges between rows j-1 and j (constant z).
	for j in grid.h + 1:
		var i := 0
		while i < grid.w:
			var a := _walk(grid, i, j - 1)
			var b := _walk(grid, i, j)
			if a == b:
				i += 1
				continue
			var i0 := i
			while i < grid.w and _walk(grid, i, j - 1) == a and _walk(grid, i, j) == b:
				i += 1
			var wr: int = j - 1 if a else j
			var ws: int = j if a else j - 1
			var x0 := float(i0)
			var x1 := float(i)
			if not _walk(grid, i0 - 1, wr) and not _walk(grid, i0 - 1, ws):
				x0 -= t
			if not _walk(grid, i, wr) and not _walk(grid, i, ws):
				x1 += t
			var z0 := float(j) if a else float(j) - t
			out.append(Rect2(grid.x0 + x0, grid.z0 + z0, x1 - x0, t))
	## Edges between columns i-1 and i (constant x).
	for i in grid.w + 1:
		var j := 0
		while j < grid.h:
			var a := _walk(grid, i - 1, j)
			var b := _walk(grid, i, j)
			if a == b:
				j += 1
				continue
			var j0 := j
			while j < grid.h and _walk(grid, i - 1, j) == a and _walk(grid, i, j) == b:
				j += 1
			var x0 := float(i) if a else float(i) - t
			out.append(Rect2(grid.x0 + x0, grid.z0 + j0, t, j - j0))
	return out


## Player spawn, extraction zones, crates, enemy spawns and cover, placed in
## each room's interior (ROOM_MARGIN from its walls) without overlapping.
func _place_props(p: Dictionary, layout: Dictionary, rng: RandomNumberGenerator) -> void:
	var rooms: Array = layout.rooms
	var spawn: int = layout.spawn_index
	for ri in rooms.size():
		var room: Dictionary = rooms[ri]
		var r: Rect2i = room.rect
		var area := Rect2(r.position.x + ROOM_MARGIN, r.position.y + ROOM_MARGIN, r.size.x - ROOM_MARGIN * 2, r.size.y - ROOM_MARGIN * 2)
		var taken: Array[Rect2] = []
		var center := Vector2(r.position) + Vector2(r.size) / 2.0
		room["roles"] = []
		room["counts"] = {"cover": 0, "crates": 0, "enemies": 0}
		if ri == spawn:
			room.roles.append("player_spawn")
			var at := center
			if ri in layout.extraction_indices:
				at = _place(area, Vector2(2, 2), taken, rng, 0.5)
				if at == Vector2.INF:
					at = center
			layout.player_spawn = Vector3(at.x, 0, at.y)
			taken.append(Rect2(at - Vector2(1.0, 1.0), Vector2(2, 2)))
		if ri in layout.extraction_indices:
			room.roles.append("extraction")
			var size: Vector2 = Vector2.ONE * (p.extraction_radius * 2.0)
			var at := _place(area, size, taken, rng, 0.5)
			if at == Vector2.INF:
				at = center
			taken.append(Rect2(at - size / 2.0, size))
			layout.extractions.append({"room": room.name, "position": Vector3(at.x, 0, at.y)})
		var want := {
			"crates": room.get("crates", 0 if ri == spawn else p.crates_per_room),
			"enemies": room.get("enemies", 0 if ri == spawn else p.enemies_per_room),
			"cover": room.get("cover", p.cover_per_room),
		}
		for i in want.crates:
			var at := _place(area, Vector2(1.0, 0.8), taken, rng, 1.0)
			if at == Vector2.INF:
				layout.skipped.append("%s: no room for crate %d" % [room.name, i + 1])
				break
			taken.append(Rect2(at - Vector2(0.5, 0.4), Vector2(1.0, 0.8)))
			layout.crates.append({"room": room.name, "position": Vector3(at.x, 0, at.y), "yaw": rng.randi_range(0, 3) * 90.0})
			room.counts.crates += 1
		for i in want.enemies:
			var at := _place(area, Vector2(1.0, 1.0), taken, rng, 1.0)
			if at == Vector2.INF:
				layout.skipped.append("%s: no room for enemy %d" % [room.name, i + 1])
				break
			taken.append(Rect2(at - Vector2(0.5, 0.5), Vector2(1, 1)))
			layout.enemy_spawns.append({"room": room.name, "position": Vector3(at.x, 0, at.y), "patrol": _patrol_route(r, at)})
			room.counts.enemies += 1
		var shapes := COVER_SHAPES.keys()
		for i in want.cover:
			var shape: String = shapes[rng.randi_range(0, shapes.size() - 1)]
			var fp := Vector2(COVER_SHAPES[shape][0], COVER_SHAPES[shape][1])
			var yaw := 0.0
			if rng.randf() < 0.5:
				fp = Vector2(fp.y, fp.x)
				yaw = 90.0
			var at := _place(area, fp, taken, rng, 1.2)
			if at == Vector2.INF:
				layout.skipped.append("%s: no room for cover %d" % [room.name, i + 1])
				break
			taken.append(Rect2(at - fp / 2.0, fp))
			var height: float = COVER_SHAPES[shape][2]
			if height < 0.0:
				height = p.wall_height
			layout.cover.append({"room": room.name, "shape": shape, "rect": Rect2(at - fp / 2.0, fp), "height": height})
			room.counts.cover += 1


## A random spot for a `size` footprint inside `area` that keeps `spacing`
## from everything in `taken`. Vector2.INF when none fits.
static func _place(area: Rect2, size: Vector2, taken: Array[Rect2], rng: RandomNumberGenerator, spacing: float) -> Vector2:
	if area.size.x < size.x or area.size.y < size.y:
		return Vector2.INF
	for attempt in 80:
		var at := Vector2(
			rng.randf_range(area.position.x + size.x / 2.0, area.end.x - size.x / 2.0),
			rng.randf_range(area.position.y + size.y / 2.0, area.end.y - size.y / 2.0))
		at = (at * 2.0).round() / 2.0
		if not area.encloses(Rect2(at - size / 2.0, size)):
			continue
		var box := Rect2(at - size / 2.0, size).grow(spacing)
		var ok := true
		for t in taken:
			if box.intersects(t):
				ok = false
				break
		if ok:
			return at
	return Vector2.INF


## A loop through the room's inner corners, starting at the one nearest the spawn.
static func _patrol_route(r: Rect2i, from: Vector2) -> Array:
	var inset := ROOM_MARGIN - 0.5
	var corners := [
		Vector2(r.position.x + inset, r.position.y + inset),
		Vector2(r.end.x - inset, r.position.y + inset),
		Vector2(r.end.x - inset, r.end.y - inset),
		Vector2(r.position.x + inset, r.end.y - inset),
	]
	var start := 0
	for i in 4:
		if from.distance_to(corners[i]) < from.distance_to(corners[start]):
			start = i
	var out := []
	for k in 4:
		var c: Vector2 = corners[(start + k) % 4]
		out.append(Vector3(c.x, 0, c.y))
	return out


static func _room_index(value: Variant, rooms: Array, key: String, default_value: int) -> Variant:
	if value == null:
		return default_value
	if value is float or value is int:
		var i := int(value)
		if float(value) != float(i) or i < 0 or i >= rooms.size():
			return Util.error(Util.INVALID_PARAMS, "'%s': room index %s is out of range (0 to %d)" % [key, value, rooms.size() - 1])
		return i
	if value is String:
		for i in rooms.size():
			if rooms[i].name == value:
				return i
		return Util.error(Util.INVALID_PARAMS, "'%s': no room named '%s'" % [key, value])
	return Util.error(Util.INVALID_PARAMS, "'%s' must name a room (name or index)" % key)


# =============================================================================
# nodes
# =============================================================================

func _build_map(p: Dictionary, layout: Dictionary, scripts: Dictionary, loot_table: Resource, enemy_packed: Array, parent: Node, report: Dictionary) -> Node3D:
	_meshes.clear()
	_shapes.clear()
	_materials.clear()
	var map := Node3D.new()
	map.name = p.name
	map.position = p.origin
	map.set_meta(&"raid_map_seed", p.seed)

	if p.build_floor:
		var floors := _group(map, "Floors")
		var n := 0
		for f in layout.floors:
			n += 1
			var r: Rect2 = f.rect
			_box(floors, "%s%d" % ["Floor" if f.kind == "room" else "Corridor", n], Vector3(r.size.x, p.floor_thickness, r.size.y),
				Vector3(r.get_center().x, -p.floor_thickness / 2.0, r.get_center().y), f.kind)
	var walls := _group(map, "Walls")
	var wn := 0
	for r in layout.walls:
		wn += 1
		_box(walls, "Wall%d" % wn, Vector3(r.size.x, p.wall_height, r.size.y), Vector3(r.get_center().x, p.wall_height / 2.0, r.get_center().y), "wall")
	var cover := _group(map, "Cover")
	var cn := 0
	for c in layout.cover:
		cn += 1
		var r: Rect2 = c.rect
		_box(cover, "%s%d" % [String(c.shape).to_pascal_case(), cn], Vector3(r.size.x, c.height, r.size.y),
			Vector3(r.get_center().x, c.height / 2.0, r.get_center().y), "pillar" if c.shape == "pillar" else "cover")

	var rooms := _group(map, "Rooms")
	for room in layout.rooms:
		var marker := Marker3D.new()
		marker.name = room.name
		var r: Rect2i = room.rect
		marker.position = Vector3(r.get_center().x, 0, r.get_center().y)
		marker.set_meta(&"size", Vector2(r.size))
		marker.set_meta(&"roles", PackedStringArray(room.roles))
		marker.add_to_group(&"raid_room", true)
		rooms.add_child(marker)

	var spawn := Marker3D.new()
	spawn.name = "PlayerSpawn"
	spawn.position = layout.player_spawn
	spawn.add_to_group(&"player_spawn", true)
	map.add_child(spawn)

	if not layout.extractions.is_empty():
		var group := _group(map, "Extractions")
		var script: Script = scripts["raid_extraction.gd"].script
		var k := 0
		for e in layout.extractions:
			k += 1
			group.add_child(_extraction(p, script, "Extraction%d" % k, e.position))

	if not layout.crates.is_empty():
		var group := _group(map, "Crates")
		var k := 0
		for c in layout.crates:
			k += 1
			group.add_child(_crate(p, scripts, loot_table, "Crate%d" % k, c))

	var spawns := _group(map, "EnemySpawns")
	var k := 0
	for e in layout.enemy_spawns:
		k += 1
		var m := Marker3D.new()
		m.name = "EnemySpawn%d" % k
		m.position = e.position
		m.set_meta(&"room", e.room)
		m.add_to_group(&"enemy_spawn", true)
		spawns.add_child(m)

	var placed := []
	if not enemy_packed.is_empty() and not layout.enemy_spawns.is_empty():
		var enemies := _group(map, "Enemies")
		var world_offset: Transform3D = (parent as Node3D).global_transform * Transform3D(Basis(), p.origin)
		var i := 0
		for e in layout.enemy_spawns:
			var packed: PackedScene = enemy_packed[i % enemy_packed.size()]
			i += 1
			var inst := packed.instantiate(PackedScene.GEN_EDIT_STATE_INSTANCE) as Node3D
			if inst == null:
				continue
			var base := String(packed.resource_path.get_file().get_basename()).to_pascal_case()
			inst.name = Util.unique_child_name(enemies, base)
			inst.position = e.position
			if p.enemy_patrol:
				var route := PackedVector3Array()
				for pt in e.patrol:
					route.append(world_offset * pt)
				inst.set("patrol_points", route)
			enemies.add_child(inst)
			placed.append(String(inst.name))
	report["enemies_placed"] = placed.size()

	if p.add_light and not _has_light(Util.edited_root()):
		var sun := DirectionalLight3D.new()
		sun.name = "Sun"
		sun.rotation_degrees = Vector3(-55, 30, 0)
		sun.shadow_enabled = true
		map.add_child(sun)
		report["light_added"] = true
	return map


func _group(parent: Node, group_name: String) -> Node3D:
	var n := Node3D.new()
	n.name = group_name
	parent.add_child(n)
	return n


## A StaticBody3D box: Mesh + Shape children, sharing meshes and shapes of
## the same size.
func _box(parent: Node, box_name: String, size: Vector3, center: Vector3, kind: String) -> StaticBody3D:
	var body := StaticBody3D.new()
	body.name = box_name
	body.position = center
	var key := "%s|%.3f|%.3f|%.3f" % [kind, size.x, size.y, size.z]
	if not _meshes.has(key):
		var mesh := BoxMesh.new()
		mesh.size = size
		mesh.material = _material(kind)
		_meshes[key] = mesh
	var shape_key := "%.3f|%.3f|%.3f" % [size.x, size.y, size.z]
	if not _shapes.has(shape_key):
		var shape := BoxShape3D.new()
		shape.size = size
		_shapes[shape_key] = shape
	var mi := MeshInstance3D.new()
	mi.name = "Mesh"
	mi.mesh = _meshes[key]
	body.add_child(mi)
	var cs := CollisionShape3D.new()
	cs.name = "Shape"
	cs.shape = _shapes[shape_key]
	body.add_child(cs)
	parent.add_child(body)
	return body


func _material(kind: String) -> StandardMaterial3D:
	if not _materials.has(kind):
		var mat := StandardMaterial3D.new()
		mat.albedo_color = COLORS[kind]
		if kind == "extraction":
			mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
			mat.emission_enabled = true
			mat.emission = Color(0.2, 1.0, 0.45)
			mat.emission_energy_multiplier = 0.6
			mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		_materials[kind] = mat
	return _materials[kind]


func _extraction(p: Dictionary, script: Script, zone_name: String, at: Vector3) -> Area3D:
	var zone := Area3D.new()
	zone.name = zone_name
	zone.position = at
	zone.set_script(script)
	zone.set("extract_time", p.extract_time)
	zone.set("restart_delay", p.restart_delay)
	var shape := CollisionShape3D.new()
	shape.name = "Shape"
	var cyl := CylinderShape3D.new()
	cyl.radius = p.extraction_radius
	cyl.height = 2.0
	shape.shape = cyl
	shape.position = Vector3(0, 1, 0)
	zone.add_child(shape)
	var pad := MeshInstance3D.new()
	pad.name = "Pad"
	var mesh := CylinderMesh.new()
	mesh.top_radius = p.extraction_radius
	mesh.bottom_radius = p.extraction_radius
	mesh.height = 0.06
	mesh.material = _material("extraction")
	pad.mesh = mesh
	pad.position = Vector3(0, 0.03, 0)
	zone.add_child(pad)
	var beacon := MeshInstance3D.new()
	beacon.name = "Beacon"
	var beam := CylinderMesh.new()
	beam.top_radius = 0.08
	beam.bottom_radius = 0.08
	beam.height = 4.0
	beam.material = _material("extraction")
	beacon.mesh = beam
	beacon.position = Vector3(0, 2, 0)
	zone.add_child(beacon)
	var label := Label3D.new()
	label.name = "Label"
	label.text = "탈출 지점"
	label.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	label.no_depth_test = true
	label.font_size = 64
	label.outline_size = 12
	label.modulate = Color(0.6, 1.0, 0.7)
	label.position = Vector3(0, 2.6, 0)
	zone.add_child(label)
	return zone


func _crate(p: Dictionary, scripts: Dictionary, loot_table: Resource, crate_name: String, c: Dictionary) -> StaticBody3D:
	var crate := StaticBody3D.new()
	crate.name = crate_name
	crate.position = c.position
	crate.rotation_degrees = Vector3(0, c.yaw, 0)
	crate.set_script(scripts["loot_crate.gd"].script)
	crate.set("interact_action", StringName(p.interact_action))
	crate.set("search_time", p.crate_search_time)
	var size := Vector3(1.0, 0.7, 0.8)
	var body := MeshInstance3D.new()
	body.name = "Body"
	var mesh := BoxMesh.new()
	mesh.size = size
	mesh.material = _material("crate")
	body.mesh = mesh
	body.position = Vector3(0, size.y / 2.0, 0)
	crate.add_child(body)
	var shape := CollisionShape3D.new()
	shape.name = "Shape"
	var box := BoxShape3D.new()
	box.size = size
	shape.shape = box
	shape.position = body.position
	crate.add_child(shape)
	var label := Label3D.new()
	label.name = "Label"
	label.text = "상자"
	label.visible = false
	label.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	label.no_depth_test = true
	label.font_size = 48
	label.outline_size = 10
	label.position = Vector3(0, 1.4, 0)
	crate.add_child(label)
	if loot_table != null:
		var dropper := Node3D.new()
		dropper.name = "LootDropper"
		dropper.set_script(scripts["loot_dropper.gd"].script)
		dropper.set("loot_table", loot_table)
		dropper.set("trigger_signal", &"opened")
		dropper.set("pickup_script_path", scripts["loot_pickup.gd"].path)
		dropper.position = Vector3(0, 0, 0)
		crate.add_child(dropper)
	return crate


## One undo step: remove the old map (if replacing), add the new one, move
## the player, add a new navigation region.
func _commit(p: Dictionary, parent: Node, map: Node3D, old: Node, root: Node, props: Array, region: NavigationRegion3D) -> void:
	var ur := EditorInterface.get_editor_undo_redo()
	ur.create_action("%s raid map %s" % ["Rebuild" if old != null else "Add", p.name], UndoRedo.MERGE_DISABLE, root)
	if old != null:
		var index := old.get_index()
		var owned := _owned_by(old, root)
		ur.add_do_method(parent, "remove_child", old)
		ur.add_undo_method(parent, "add_child", old, true)
		ur.add_undo_method(parent, "move_child", old, index)
		for n in owned:
			ur.add_undo_method(n, "set_owner", root)
		ur.add_undo_reference(old)
	var items := [[parent, map]]
	if region != null:
		items.append([root, region])
	for item in items:
		ur.add_do_method(item[0], "add_child", item[1], true)
		ur.add_do_method(item[1], "set_owner", root)
		for child in Util._descendants_owned_by_node(item[1]):
			ur.add_do_method(child, "set_owner", root)
		ur.add_do_reference(item[1])
	for t in props:
		ur.add_do_property(t[0], t[1], t[2])
		ur.add_undo_property(t[0], t[1], t[3])
	for i in range(items.size() - 1, -1, -1):
		ur.add_undo_method(items[i][0], "remove_child", items[i][1])
	ur.commit_action()


static func _owned_by(node: Node, root: Node) -> Array:
	var out := []
	if node.owner == root:
		out.append(node)
	for child in node.get_children():
		out.append_array(_owned_by(child, root))
	return out


# =============================================================================
# navigation
# =============================================================================

func _build_nav_region(region_name: String) -> NavigationRegion3D:
	var region := NavigationRegion3D.new()
	region.name = region_name
	var nav := NavigationMesh.new()
	nav.geometry_parsed_geometry_type = NavigationMesh.PARSED_GEOMETRY_STATIC_COLLIDERS
	nav.geometry_source_geometry_mode = NavigationMesh.SOURCE_GEOMETRY_GROUPS_WITH_CHILDREN
	nav.geometry_source_group_name = NAV_SOURCE_GROUP
	nav.agent_radius = 0.5
	nav.agent_height = 1.75
	region.navigation_mesh = nav
	return region


func _bake_new(region: NavigationRegion3D, root: Node) -> Dictionary:
	region.bake_navigation_mesh(false)
	return {
		"status": "created",
		"region_path": Util.scene_path_of(region, root),
		"polygons": region.navigation_mesh.get_polygon_count(),
	}


## Rebakes an existing region into a fresh NavigationMesh so the bake is its
## own undo step (undo puts the previous mesh back).
func _rebake(region: NavigationRegion3D, root: Node) -> Dictionary:
	var old := region.navigation_mesh
	if old == null:
		return {"status": "skipped", "region_path": Util.scene_path_of(region, root), "note": "the region has no NavigationMesh"}
	var fresh := old.duplicate() as NavigationMesh
	region.navigation_mesh = fresh
	region.bake_navigation_mesh(false)
	region.navigation_mesh = old
	var ur := EditorInterface.get_editor_undo_redo()
	ur.create_action("Rebake navigation for raid map", UndoRedo.MERGE_DISABLE, root)
	ur.add_do_property(region, "navigation_mesh", fresh)
	ur.add_undo_property(region, "navigation_mesh", old)
	ur.commit_action()
	return {
		"status": "rebaked",
		"region_path": Util.scene_path_of(region, root),
		"polygons": fresh.get_polygon_count(),
	}


static func _navigation_regions(root: Node) -> Array:
	var out := []
	if root is NavigationRegion3D:
		out.append(root)
	out.append_array(root.find_children("*", "NavigationRegion3D", true, false))
	return out


static func _under_group(node: Node, group_name: StringName, root: Node) -> bool:
	var n := node
	while n != null:
		if n.is_in_group(group_name):
			return true
		if n == root:
			break
		n = n.get_parent()
	return false


# =============================================================================
# report
# =============================================================================

func _report(p: Dictionary, layout: Dictionary) -> Dictionary:
	var origin: Vector3 = p.origin
	var rooms := []
	for room in layout.rooms:
		var r: Rect2i = room.rect
		rooms.append({
			"name": room.name,
			"center": _arr(origin + Vector3(r.get_center().x, 0, r.get_center().y)),
			"size": [r.size.x, r.size.y],
			"roles": room.roles,
			"cover": room.counts.cover,
			"crates": room.counts.crates,
			"enemy_spawns": room.counts.enemies,
		})
	var links := []
	for l in layout.links:
		links.append([layout.rooms[l[0]].name, layout.rooms[l[1]].name])
	var spawns := []
	for e in layout.enemy_spawns:
		spawns.append(_arr(origin + e.position))
	var extractions := []
	for e in layout.extractions:
		extractions.append({"room": e.room, "position": _arr(origin + e.position)})
	var crates := []
	for c in layout.crates:
		crates.append({"room": c.room, "position": _arr(origin + c.position)})
	var warnings := []
	warnings.append_array(layout.skipped)
	if layout.extractions.is_empty():
		warnings.append("No extraction zone: the raid cannot be finished (extraction_count or extraction_rooms).")
	return {
		"seed": p.seed,
		"generated": layout.generated,
		"size_m": [layout.grid.w - 2, layout.grid.h - 2],
		"rooms": rooms,
		"connections": links,
		"player_spawn": _arr(origin + layout.player_spawn),
		"extractions": extractions,
		"crates": crates,
		"enemy_spawn_positions": spawns,
		"counts": {"floors": layout.floors.size() if p.build_floor else 0, "walls": layout.walls.size(), "cover": layout.cover.size(), "crates": layout.crates.size(), "enemy_spawns": layout.enemy_spawns.size(), "extractions": layout.extractions.size()},
		"preview": _preview(layout),
		"preview_legend": ". room  , corridor  # wall  o cover  C crate  e enemy spawn  P player spawn  X extraction  (top = -z)",
		"warnings": warnings,
	}


## ASCII map, one character per meter, -z at the top.
func _preview(layout: Dictionary) -> Array:
	var grid: Dictionary = layout.grid
	if grid.w > 160 or grid.h > 120:
		return ["(map is %dx%d m; preview shown up to 160x120)" % [grid.w, grid.h]]
	var rows := []
	for j in grid.h:
		var line := PackedStringArray()
		for i in grid.w:
			var c := _cell(grid, i, j)
			if c == 1:
				line.append(".")
			elif c == 2:
				line.append(",")
			else:
				var near := false
				for dj in [-1, 0, 1]:
					for di in [-1, 0, 1]:
						if _walk(grid, i + di, j + dj):
							near = true
				line.append("#" if near else " ")
		rows.append(line)
	var mark := func(pos: Vector3, ch: String) -> void:
		var i: int = int(floor(pos.x)) - grid.x0
		var j: int = int(floor(pos.z)) - grid.z0
		if i >= 0 and j >= 0 and i < grid.w and j < grid.h:
			rows[j][i] = ch
	for c in layout.cover:
		var r: Rect2 = c.rect
		for z in range(int(floor(r.position.y)), int(ceil(r.end.y))):
			for x in range(int(floor(r.position.x)), int(ceil(r.end.x))):
				mark.call(Vector3(x, 0, z), "o")
	for c in layout.crates:
		mark.call(c.position, "C")
	for e in layout.enemy_spawns:
		mark.call(e.position, "e")
	for e in layout.extractions:
		mark.call(e.position, "X")
	mark.call(layout.player_spawn, "P")
	var out := []
	for line in rows:
		out.append("".join(line).rstrip(" "))
	return out


func _next_steps(p: Dictionary, layout: Dictionary, report: Dictionary) -> Array:
	var steps := []
	if not layout.enemy_spawns.is_empty() and p.enemy_scenes.is_empty():
		steps.append("Enemy spawn markers only (group enemy_spawn). Pass enemy_scenes (from enemy_ai_scaffold) to place enemies with a patrol route per room, or call enemy_ai_scaffold with positions = enemy_spawn_positions.")
	if not layout.crates.is_empty() and p.crate_loot_table.is_empty():
		steps.append("Crates open but drop nothing: make a crate table with loot_table_edit and rerun with crate_loot_table and replace=true (or loot_table_edit attach_to_group=loot_crate, trigger_signal=opened).")
	var nav: Dictionary = report.get("navigation", {})
	if nav.get("polygons", 1) == 0:
		steps.append("The navigation mesh came out empty. Check that %s bakes from a group containing the map, then press Bake NavigationMesh." % nav.get("region_path", "the region"))
	steps.append("Edit freely: walls, cover and crates are plain nodes under %s. Rebake the navigation region after moving walls or cover." % p.name)
	return steps


## Warns about enemies placed before the map that now stand off the floor.
func _check_outside_enemies(root: Node, map: Node3D, layout: Dictionary, p: Dictionary, parent: Node, warnings: Array) -> void:
	var inv := ((parent as Node3D).global_transform * Transform3D(Basis(), p.origin)).affine_inverse()
	var grid: Dictionary = layout.grid
	var off := []
	for node in root.get_tree().get_nodes_in_group(&"enemy"):
		if not node is Node3D or map.is_ancestor_of(node) or not (node == root or root.is_ancestor_of(node)):
			continue
		var local: Vector3 = inv * (node as Node3D).global_position
		if not _walk(grid, int(floor(local.x)) - grid.x0, int(floor(local.z)) - grid.z0):
			off.append(Util.scene_path_of(node, root))
	if not off.is_empty():
		warnings.append("%d enemies placed earlier stand outside the map's rooms: %s. Move or delete them." % [off.size(), ", ".join(PackedStringArray(off))])


# =============================================================================
# helpers
# =============================================================================

func _ensure_interact_action(action: String) -> Variant:
	var key := "input/" + action
	if ProjectSettings.has_setting(key):
		return {"created": [], "kept_existing": [action]}
	var ev := InputEventKey.new()
	ev.physical_keycode = KEY_E
	ProjectSettings.set_setting(key, {"deadzone": 0.5, "events": [ev]})
	if not InputMap.has_action(action):
		InputMap.add_action(action, 0.5)
		InputMap.action_add_event(action, ev)
	var err := ProjectSettings.save()
	if err != OK:
		return Util.error(Util.INTERNAL_ERROR, "cannot save project.godot: %s" % error_string(err))
	return {"created": [action], "kept_existing": []}


static func _find_player(root: Node) -> Node3D:
	if root.is_in_group(&"player") and root is Node3D:
		return root
	for node in root.find_children("*", "Node3D", true, false):
		if node.is_in_group(&"player"):
			return node
	return null


static func _has_light(root: Node) -> bool:
	if root == null:
		return false
	return root is DirectionalLight3D or not root.find_children("*", "DirectionalLight3D", true, false).is_empty()


static func _string_list(params: Dictionary, key: String) -> Variant:
	if not params.has(key) or params[key] == null:
		return []
	var raw: Variant = params[key]
	if raw is String:
		raw = [raw]
	if not raw is Array:
		return Util.error(Util.INVALID_PARAMS, "'%s' must be a list of strings" % key)
	var out: Array[String] = []
	for v in raw:
		if not v is String or String(v).strip_edges().is_empty():
			return Util.error(Util.INVALID_PARAMS, "'%s' must be a list of non-empty strings" % key)
		out.append(String(v).strip_edges())
	return out


static func _all_numbers(values: Array) -> bool:
	for v in values:
		if not (v is float or v is int):
			return false
	return true


static func _shuffle(arr: Array, rng: RandomNumberGenerator) -> void:
	for i in range(arr.size() - 1, 0, -1):
		var j := rng.randi_range(0, i)
		var tmp: Variant = arr[i]
		arr[i] = arr[j]
		arr[j] = tmp


static func _arr(v: Vector3) -> Array:
	return [snappedf(v.x, 0.01), snappedf(v.y, 0.01), snappedf(v.z, 0.01)]
