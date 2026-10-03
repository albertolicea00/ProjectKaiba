class_name YdkIo
extends RefCounted

## `.ydk` import and export, byte-compatible with EDOPro.
##
## Layer: **L3**. Touches `FileAccess` and `DirAccess`, which are not scene-tree types, so V2
## holds. Decks live in `user://decks/`: Local First, no server, nothing under `res://`. A deck
## is the player's, it is editable, and `res://` is read-only in an exported build anyway.
##
## -------------------------------------------------------------------------------------------
## The format, transcribed - not remembered
## -------------------------------------------------------------------------------------------
## Writer, `edopro/gframe/deck_manager.cpp:441` (`DeckManager::SaveDeck`):
##
##     #created by <nickname>\n#main\n   then one decimal code per line, then
##     #extra\n                          then the extra codes, then
##     !side\n                           then the side codes
##
## Every code line is `"%d\n"` - `MakeYdkEntryString()`, same file. That function has one other
## mode, `addCardNamesToDeckList`, which prefixes each code with a `# <name>\n` comment line.
## Those comments parse away to nothing (see below), so such a file loads correctly but will
## **not** round-trip byte-identically through `serialise()`. That is EDOPro's non-canonical
## output, not ours; we always write the plain form.
##
## Parser, `deck_manager.cpp:276-300` (`LoadCardList`). Four details that are easy to get wrong
## and each of which silently corrupts a deck if guessed:
##
##   1. A line starting with `#` is **skipped**, with exactly one exception: the literal string
##      `#extra` switches the target list. `#main` is *not* a mode switch - main is simply the
##      state the parser starts in - and `#created by ...` is just another comment.
##   2. A line starting with `!` switches to the side list. It is the leading `!` that matters,
##      not the word after it. `!side`, `!sidedeck` and `!` all do the same thing.
##   3. Otherwise: if the line contains a digit anywhere, parse it as an unsigned integer. A
##      parse failure **skips the line** and carries on. A corrupt line never fails the file.
##   4. Blank lines are dropped, and the line is truncated at the first `\r` or `\n` - which is
##      what makes a CRLF file from Windows load unchanged.
##
## Note the exact control flow at (1): EDOPro sets `is_extra` and then falls through to (2) and
## (3) rather than continuing. `#extra` contains no digit so nothing is appended, which makes
## the fallthrough invisible - but it is reproduced below rather than tidied, because the
## tidied version stops being a transcription and starts being a guess.

## The only `#` line with a meaning. Compared exactly, including case: EDOPro uses `str !=
## "#extra"`, so `#Extra` is a comment.
const EXTRA_MARK: String = "#extra"

## Where a player's decks live. Local First: `user://` is the only writable place on Android and
## the only place a deck belongs on desktop.
const DECK_DIR: String = "user://decks"

const EXTENSION: String = ".ydk"

## Written into the `#created by` line when the caller has no name to offer. EDOPro writes the
## player's nickname there; it is informational and no parser reads it.
const DEFAULT_AUTHOR: String = "Project Kaiba"

## Characters a deck name may not contain, because the name becomes a filename.
const UNSAFE_NAME_CHARS: String = "\\/:*?\"<>|"


# ----------------------------------------------------------------------------------------------
# Parsing
# ----------------------------------------------------------------------------------------------

## Never fails. A file that is not a deck at all yields an empty `DeckModel`, which is the same
## answer EDOPro gives and the only answer that keeps a corrupt file from taking the editor down.
static func parse(text: String) -> DeckModel:
	var deck: DeckModel = DeckModel.new()
	var target: DeckModel.LIST = DeckModel.LIST.MAIN

	for raw: String in text.split("\n"):
		# `split("\n")` has already consumed the newlines; this clears the `\r` of a CRLF file
		# and anything after it, exactly as `find_first_of("\n\r")` + `erase` does upstream.
		var line: String = raw
		var cut: int = line.find("\r")
		if cut >= 0:
			line = line.substr(0, cut)

		if line.is_empty():
			continue

		if line[0] == "#":
			if line != EXTRA_MARK:
				continue
			target = DeckModel.LIST.EXTRA
			# Deliberate fallthrough, mirroring the upstream switch. See the header.

		if line[0] == "!":
			target = DeckModel.LIST.SIDE
			continue

		if not _has_digit(line):
			continue

		var code: int = _to_unsigned(line)
		if code < 0:
			continue

		deck.append(target, code)

	return deck


## `null` when the file cannot be read. An unreadable deck and an empty deck are different
## answers and the caller needs to be able to tell them apart.
static func parse_file(path: String) -> DeckModel:
	if not FileAccess.file_exists(path):
		return null
	var text: String = FileAccess.get_file_as_string(path)
	if text.is_empty() and FileAccess.get_open_error() != OK:
		return null
	return parse(text)


# ----------------------------------------------------------------------------------------------
# Writing
# ----------------------------------------------------------------------------------------------

## The exact byte sequence `DeckManager::SaveDeck` produces. Built as one string rather than
## written line by line so that `serialise()` can be tested without a filesystem.
static func serialise(deck: DeckModel, author: String = DEFAULT_AUTHOR) -> String:
	var out: PackedStringArray = PackedStringArray()
	# The author line is free text and the only part of the file a round trip may legally
	# change. Newlines in it would forge section markers, so they are flattened.
	out.append("#created by %s\n" % author.replace("\r", " ").replace("\n", " "))
	out.append("#main\n")
	_write_list(out, deck, DeckModel.LIST.MAIN)
	out.append("#extra\n")
	_write_list(out, deck, DeckModel.LIST.EXTRA)
	out.append("!side\n")
	_write_list(out, deck, DeckModel.LIST.SIDE)
	return "".join(out)


## Writes `deck` to `path`. Returns `OK` or the `FileAccess` error.
static func save_to(deck: DeckModel, path: String, author: String = DEFAULT_AUTHOR) -> Error:
	var dir: String = path.get_base_dir()
	if not dir.is_empty() and not DirAccess.dir_exists_absolute(dir):
		var made: Error = DirAccess.make_dir_recursive_absolute(dir)
		if made != OK:
			return made

	var handle: FileAccess = FileAccess.open(path, FileAccess.WRITE)
	if handle == null:
		return FileAccess.get_open_error()
	handle.store_string(serialise(deck, author))
	handle.close()
	return OK


## Writes `deck` as `user://decks/<name>.ydk`.
static func save(deck: DeckModel, deck_name: String, author: String = DEFAULT_AUTHOR) -> Error:
	return save_to(deck, path_for(deck_name), author)


# ----------------------------------------------------------------------------------------------
# The deck folder
# ----------------------------------------------------------------------------------------------

static func deck_dir() -> String:
	return DECK_DIR


static func ensure_deck_dir() -> Error:
	if DirAccess.dir_exists_absolute(DECK_DIR):
		return OK
	return DirAccess.make_dir_recursive_absolute(DECK_DIR)


## `user://decks/<name>.ydk`, with the name made safe for a filesystem first.
static func path_for(deck_name: String) -> String:
	return DECK_DIR.path_join(sanitise_name(deck_name) + EXTENSION)


## Deck names, without the extension, sorted. An absent folder is an empty list, not an error:
## a player who has never saved a deck is a normal state.
static func list_decks() -> PackedStringArray:
	var out: PackedStringArray = PackedStringArray()
	if not DirAccess.dir_exists_absolute(DECK_DIR):
		return out
	for file: String in DirAccess.get_files_at(DECK_DIR):
		if file.to_lower().ends_with(EXTENSION):
			out.append(file.substr(0, file.length() - EXTENSION.length()))
	out.sort()
	return out


static func load_deck(deck_name: String) -> DeckModel:
	return parse_file(path_for(deck_name))


static func delete_deck(deck_name: String) -> Error:
	return DirAccess.remove_absolute(path_for(deck_name))


## Strips path separators and the characters Windows refuses, collapses whitespace and caps the
## length. Returns "deck" for a name that sanitises away to nothing, because a file still has to
## be called something.
static func sanitise_name(deck_name: String) -> String:
	var source: String = deck_name.strip_edges()
	var out: String = ""
	for i: int in source.length():
		var c: String = source[i]
		out += "_" if UNSAFE_NAME_CHARS.contains(c) or c.unicode_at(0) < 32 else c
	out = out.strip_edges()
	if out.length() > 64:
		out = out.substr(0, 64).strip_edges()
	return out if not out.is_empty() else "deck"


# ----------------------------------------------------------------------------------------------
# The two string primitives the format depends on
# ----------------------------------------------------------------------------------------------

## Upstream: `str.find_first_of("0123456789") != npos`. Checked over the whole line, before any
## attempt to parse it, which is why `"#created by 2001"` would reach the parse step if it were
## not already filtered out as a comment.
static func _has_digit(line: String) -> bool:
	for i: int in line.length():
		var c: int = line.unicode_at(i)
		if c >= 48 and c <= 57:
			return true
	return false


## `std::stoul` semantics, narrowed: leading whitespace, an optional `+`, then at least one
## digit; trailing junk is ignored. Returns -1 where `stoul` would have thrown, which upstream
## catches and turns into "skip this line".
##
## A leading `-` is rejected rather than wrapped. `stoul` would accept it and wrap to a huge
## unsigned value; no real `.ydk` contains one, and a silently wrapped passcode is worse than a
## dropped line.
static func _to_unsigned(line: String) -> int:
	var i: int = 0
	while i < line.length() and line.unicode_at(i) <= 32:
		i += 1
	if i < line.length() and line[i] == "+":
		i += 1

	var start: int = i
	var value: int = 0
	while i < line.length():
		var c: int = line.unicode_at(i)
		if c < 48 or c > 57:
			break
		value = value * 10 + (c - 48)
		i += 1

	if i == start:
		return -1
	# Passcodes are uint32. Anything wider is a corrupt line, not a card.
	return value if value <= 0xFFFFFFFF else -1


static func _write_list(out: PackedStringArray, deck: DeckModel, which: DeckModel.LIST) -> void:
	for code: int in deck.cards(which):
		out.append("%d\n" % code)
