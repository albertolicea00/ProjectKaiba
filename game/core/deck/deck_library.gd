class_name DeckLibrary
extends RefCounted
## The decks available to load, discovered from disk.
##
## Layer: L3 (AGENTS.md section 4). Pure data - it reads files and returns Dictionaries, and
## knows nothing about scenes, textures or the core.
##
## -------------------------------------------------------------------------------------------
## Why there is no deck editor
## -------------------------------------------------------------------------------------------
## Decks are authored elsewhere - EDOPro, YGOPro, any `.ydk` the player already owns - and
## brought here as files. That is the whole feature: drop a `.ydk` in a folder, pick it, play.
##
## It is not a smaller version of an editor; it is a different, better answer to the same need.
## An editor would have to reimplement search, filtering, banlists and validation that the
## tools the player already uses do better, and it would own a format nobody else could read.
## `.ydk` is what every other client speaks, so a deck built anywhere works here untouched.
##
## -------------------------------------------------------------------------------------------
## Where decks are found
## -------------------------------------------------------------------------------------------
## Two roots, searched in order, both optional:
##
##   `user://decks/`          what the player drops in after install. Survives app updates.
##   `data/base/decks/`       the dev tree, so a checkout has something to play with.
##
## A name collision resolves to the first root, so a player's own copy shadows a bundled one.

## Where a bundled deck lives relative to the Godot project.
const BUNDLED_DIR: String = "res://../data/base/decks"

const EXTENSION: String = ".ydk"

## Where the last pick is remembered. A scene change throws the picker away, so the choice has
## to outlive it somewhere; a one-line config file beats threading it through the router and
## survives a restart, which is what a player expects from "I picked that one".
const CHOICE_PATH: String = "user://last_deck.cfg"
const CHOICE_KEY: String = "path"


## Every deck found, newest root first, as Dictionaries:
##
##   "name"      String, the file name without its extension - what EDOPro shows
##   "path"      String, an absolute OS path ready for `YdkIo.parse_file()`
##   "source"    String, "user" or "bundled"
##   "main" / "extra" / "side"   int counts, read by parsing the file
##
## Parsing every file up front is deliberate: a list that shows "40/10/0" next to each name is
## worth far more than one that shows names alone, and five decks of sixty lines cost nothing.
## If that ever stops being true, the counts are the thing to make lazy, not the listing.
static func entries() -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	var seen: Dictionary = {}

	for source: String in ["user", "bundled"]:
		var root: String = root_for(source)
		if root.is_empty():
			continue
		for file_name: String in _ydk_files(root):
			var deck_name: String = file_name.trim_suffix(EXTENSION)
			if seen.has(deck_name):
				continue
			seen[deck_name] = true

			var path: String = root.path_join(file_name)
			var deck: DeckModel = YdkIo.parse_file(path)
			out.append({
				"name": deck_name,
				"path": path,
				"source": source,
				"main": deck.size(DeckModel.LIST.MAIN),
				"extra": deck.size(DeckModel.LIST.EXTRA),
				"side": deck.size(DeckModel.LIST.SIDE),
			})
	return out


## The absolute directory for a source, or "" when it does not exist.
static func root_for(source: String) -> String:
	var path: String = YdkIo.deck_dir() if source == "user" else BUNDLED_DIR
	var absolute: String = ProjectSettings.globalize_path(path).simplify_path()
	return absolute if DirAccess.dir_exists_absolute(absolute) else ""


## Loads one entry. Returns an empty deck rather than null for an unreadable file, so a caller
## can always ask it for counts without checking first.
static func load_deck(entry: Dictionary) -> DeckModel:
	var path: String = str(entry.get("path", ""))
	if path.is_empty():
		return DeckModel.new()
	return YdkIo.parse_file(path)


## `.ydk` file names in a directory, sorted, so the list does not reshuffle between runs.
static func _ydk_files(root: String) -> PackedStringArray:
	var out: PackedStringArray = PackedStringArray()
	var dir: DirAccess = DirAccess.open(root)
	if dir == null:
		return out
	dir.list_dir_begin()
	var entry: String = dir.get_next()
	while entry != "":
		if not dir.current_is_dir() and entry.ends_with(EXTENSION):
			out.append(entry)
		entry = dir.get_next()
	dir.list_dir_end()
	out.sort()
	return out


## Remembers which deck was chosen. Stores the path, not the parsed deck: the file is the truth,
## so editing it elsewhere and coming back picks up the edit.
static func remember(entry: Dictionary) -> void:
	var path: String = str(entry.get("path", ""))
	if path.is_empty():
		return
	var config := ConfigFile.new()
	config.set_value("deck", CHOICE_KEY, path)
	config.save(CHOICE_PATH)


## The remembered deck, or the first one found, or an empty entry.
##
## Falling back rather than failing is deliberate: a fresh install has no choice recorded, and
## refusing to start a duel over that would be a dead end on the very first run.
static func chosen() -> Dictionary:
	var all: Array[Dictionary] = entries()
	if all.is_empty():
		return {}

	var config := ConfigFile.new()
	if config.load(CHOICE_PATH) == OK:
		var wanted: String = str(config.get_value("deck", CHOICE_KEY, ""))
		for entry: Dictionary in all:
			if str(entry.get("path", "")) == wanted:
				return entry
	return all[0]
