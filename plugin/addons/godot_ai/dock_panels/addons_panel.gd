@tool
extends ScrollContainer

## Offline discovery only. Keep this bundled list in sync with
## docs/community-addons.md; authors report compatibility and own installation.
## Link intents are handled by the dock, so building the panel never performs
## network requests or changes the project.

const COMMUNITY_DIRECTORY := "https://github.com/hi-godot/godot-ai/blob/main/docs/community-addons.md"
const ADDONS := [
	{
		"id": "terrain_tools",
		"name": "Godot AI Terrain Tools",
		"author": "michaltomczykowski",
		"description": "Create and sculpt heightmap terrain, add erosion and roads, and paint terrain layers.",
		"requirements": "Godot 4.7+ · Godot AI 4.1+",
		"repository": "https://github.com/michaltomczykowski/godot-ai-terrain-tools",
		"installation": "https://github.com/michaltomczykowski/godot-ai-terrain-tools#installation",
	},
	{
		"id": "animation_toolkit",
		"name": "Godot AI Animation Toolkit",
		"author": "michaltomczykowski",
		"description": "Build and edit animation clips, effects, AnimationTrees, rigs, and procedural character motion.",
		"requirements": "Godot 4.7 · Godot AI 4.1+",
		"repository": "https://github.com/michaltomczykowski/godot-ai-animation-toolkit",
		"installation": "https://github.com/michaltomczykowski/godot-ai-animation-toolkit#install",
	},
]

signal link_requested(url: String)


## Synchronous, idempotent construction, like the other dock panels.
func setup(muted_color: Color) -> void:
	if get_child_count() > 0:
		return
	size_flags_horizontal = Control.SIZE_EXPAND_FILL
	size_flags_vertical = Control.SIZE_EXPAND_FILL
	horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	var catalog := VBoxContainer.new()
	catalog.name = "Catalog"
	catalog.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	catalog.add_theme_constant_override("separation", 12)
	add_child(catalog)
	var intro := _label(
		"Discover optional addons that give your AI agent more Godot tools. "
		+ "Maintained by their authors; requirements are author-reported. "
		+ "Open the installation instructions to add and enable an addon."
	)
	intro.add_theme_color_override("font_color", muted_color)
	catalog.add_child(intro)
	for addon in ADDONS:
		catalog.add_child(_build_addon_card(addon, muted_color))
	var directory := _link_button("Community directory", COMMUNITY_DIRECTORY)
	directory.name = "CommunityDirectory"
	directory.size_flags_horizontal = Control.SIZE_SHRINK_BEGIN
	catalog.add_child(directory)


func _build_addon_card(addon: Dictionary, muted_color: Color) -> PanelContainer:
	var card := PanelContainer.new()
	card.name = addon.id
	card.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	var margin := MarginContainer.new()
	for side in ["left", "right", "top", "bottom"]:
		margin.add_theme_constant_override("margin_" + side, 12)
	card.add_child(margin)
	var body := VBoxContainer.new()
	body.name = "Details"
	body.add_theme_constant_override("separation", 6)
	margin.name = "Margin"
	margin.add_child(body)
	var title := _label(addon.name)
	title.name = "Title"
	var title_size := EditorInterface.get_base_control().get_theme_font_size("font_size", "Label")
	title.add_theme_font_size_override("font_size", title_size + roundi(2 * EditorInterface.get_editor_scale()))
	body.add_child(title)
	var author := _label("By " + addon.author)
	author.name = "Author"
	author.add_theme_color_override("font_color", muted_color)
	body.add_child(author)
	var description := _label(addon.description)
	description.name = "Description"
	body.add_child(description)
	var requirements := _label(addon.requirements)
	requirements.name = "Requirements"
	requirements.add_theme_color_override("font_color", muted_color)
	body.add_child(requirements)
	var links := HFlowContainer.new()
	links.name = "Links"
	links.add_theme_constant_override("h_separation", 8)
	links.add_theme_constant_override("v_separation", 6)
	links.add_child(_link_button("GitHub", addon.repository))
	links.add_child(_link_button("Releases", addon.repository + "/releases"))
	links.add_child(_link_button("Installation instructions", addon.installation))
	body.add_child(links)
	return card


static func _label(text: String) -> Label:
	var label := Label.new()
	label.text = text
	label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	return label


func _link_button(text: String, url: String) -> Button:
	var button := Button.new()
	button.text = text
	button.tooltip_text = url
	button.pressed.connect(func(): link_requested.emit(url))
	return button
