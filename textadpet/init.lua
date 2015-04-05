ui.tabs = false

textadept.editing.AUTOPAIR = false

-- key bindings
keys.cah = nil -- no horizontal splits
keys.caH = nil -- replaced with ch
keys.ch = textadept.editing.highlight_word

local function toggle_tabs()
	ui.tabs = not ui.tabs
end
keys.ct = toggle_tabs
