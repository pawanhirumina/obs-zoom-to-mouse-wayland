--[[
obs-key-display.lua — show pressed keys in an OBS text source
Part of obs-zoom-to-mouse-wayland (GPL-3.0). See LICENSE.

Displays the keys you press inside an OBS text source, so you can use it as a
keyboard visualizer / keycaster on your stream or recording.

Modes:
  * Global — reads a file written by bin/obs-key-log.py (evdev). Shows ANY key
             pressed anywhere on the desktop. Needs python3-evdev and access to
             /dev/input (add your user to the `input` group, then log out/in).
  * Hotkeys — shows OBS hotkeys you bind in Settings → Hotkeys → Scripts →
              "Key Display slot N". Works globally once bound, no extra deps.
  * Both    — global keys plus bound OBS hotkeys.

How to use:
  1. Tools → Scripts → ＋  and add this file (obs-key-display.lua).
  2. Add a "Text (FreeType2)" source to your scene. Style it however you like
     (font, size, color, background, opacity) — that styling is what shows.
  3. In this script's settings, pick that text source as "Text Source".
  4. For global keys, run:  python3 bin/obs-key-log.py
     (needs python3-evdev + /dev/input access; see the file's header).
  5. Press keys — they appear in the text source, hence on stream/record.

Extras:
  * Exceptions — comma-separated keys that won't show up, e.g. "Shift, X, F1".
                 Any part of a pressed combo matching an exception is suppressed.
  * Toggle     — bind "Toggle Key Display" in Settings → Hotkeys → Scripts to
                 turn the whole display on/off mid-stream.
]]

local obs = obslua

-- ---------------------------------------------------------------------------
-- State
-- ---------------------------------------------------------------------------
local state = {
    source_name   = "",
    mode          = "global",        -- "global" | "hotkeys" | "both"
    key_file      = "",
    clear_after   = 3,               -- seconds; 0 = never
    prefix        = "",
    suffix        = "",
    uppercase     = false,
    exceptions    = "",              -- comma-separated keys to suppress
    enabled       = true,            -- master on/off
}

local hotkey_ids = {}
local toggle_hotkey_id = nil
local last_text = ""
local last_update_time = 0

-- ---------------------------------------------------------------------------
-- Helpers
-- ---------------------------------------------------------------------------

local function trim(s)
    return (s:gsub("^%s+", ""):gsub("%s+$", ""))
end

local function split_csv(s)
    local out = {}
    if trim(s) == "" then
        return out
    end
    for part in s:gmatch("([^,]+)") do
        local p = trim(part):lower()
        if p ~= "" then
            table.insert(out, p)
        end
    end
    return out
end

local exceptions_list = {}

local function is_exception(key_text)
    if #exceptions_list == 0 then
        return false
    end
    -- Check each segment of a combo like "Ctrl + Alt + X"
    for seg in key_text:gmatch("([^%+]+)") do
        local s = trim(seg):lower()
        for _, exc in ipairs(exceptions_list) do
            if s == exc then
                return true
            end
        end
    end
    return false
end

-- Write text to the chosen OBS text source.
local function set_source_text(text)
    if trim(state.source_name) == "" then
        return
    end
    local source = obs.obs_get_source_by_name(state.source_name)
    if not source then
        return
    end
    local settings = obs.obs_source_get_settings(source)
    obs.obs_data_set_string(settings, "text", text)
    obs.obs_source_update(source, settings)
    obs.obs_data_release(settings)
    obs.obs_source_release(source)
end

local function apply_text(text)
    if not state.enabled then
        return
    end
    if is_exception(text) then
        return
    end
    if state.uppercase then
        text = text:upper()
    end
    if state.prefix ~= "" then
        text = state.prefix .. text
    end
    if state.suffix ~= "" then
        text = text .. state.suffix
    end
    set_source_text(text)
    last_text = text
    last_update_time = os.time()
end

local function clear_if_needed()
    if not state.enabled then
        return
    end
    if state.clear_after <= 0 then
        return
    end
    if last_text == "" then
        return
    end
    if os.time() - last_update_time >= state.clear_after then
        set_source_text("")
        last_text = ""
    end
end

-- ---------------------------------------------------------------------------
-- Global mode: poll the file that obs-key-log.py writes
-- ---------------------------------------------------------------------------

local function default_key_file()
    local xdg = os.getenv("XDG_STATE_HOME")
    if not xdg or xdg == "" then
        xdg = (os.getenv("HOME") or "") .. "/.local/state"
    end
    return xdg .. "/obs-zoom-to-mouse-wayland/last-key.txt"
end

local function read_last_key_file()
    if trim(state.key_file) == "" then
        return nil
    end
    local f = io.open(state.key_file, "r")
    if not f then
        return nil
    end
    local content = f:read("*a")
    f:close()
    content = trim(content)
    if content == "" then
        return nil
    end
    return content
end

local function check_file()
    if not state.enabled then
        return
    end
    if state.mode ~= "global" and state.mode ~= "both" then
        return
    end
    local content = read_last_key_file()
    if content and content ~= last_text then
        apply_text(content)
    end
    clear_if_needed()
end

-- ---------------------------------------------------------------------------
-- Hotkey mode: OBS frontend hotkeys the user binds in Settings
-- ---------------------------------------------------------------------------

local function make_hotkey_callback(slot)
    return function(pressed)
        if not pressed then
            return
        end
        if not state.enabled then
            return
        end
        if state.mode ~= "hotkeys" and state.mode ~= "both" then
            return
        end
        apply_text(slot)
        clear_if_needed()
    end
end

local function make_toggle_callback()
    return function(pressed)
        if not pressed then
            return
        end
        state.enabled = not state.enabled
        if not state.enabled then
            set_source_text("")
            last_text = ""
        end
    end
end

local NUM_HOTKEYS = 8

local function reload_hotkeys(settings)
    for _, id in ipairs(hotkey_ids) do
        obs.obs_hotkey_unregister(id)
    end
    hotkey_ids = {}

    for i = 1, NUM_HOTKEYS do
        local name = "Key Display slot " .. i
        local desc = "Bound key appears in the text source (slot " .. i .. ")"
        local id = obs.obs_hotkey_register_frontend(
            "key_display.slot" .. i, name, make_hotkey_callback("Slot " .. i))
        if id ~= obs.OBS_INVALID_HOTKEY_ID then
            local array = obs.obs_data_get_array(settings, "hotkey_slot" .. i)
            if array then
                obs.obs_hotkey_load(id, array)
                obs.obs_data_array_release(array)
            end
            table.insert(hotkey_ids, id)
        end
    end

    -- Master toggle hotkey
    if toggle_hotkey_id then
        obs.obs_hotkey_unregister(toggle_hotkey_id)
    end
    toggle_hotkey_id = obs.obs_hotkey_register_frontend(
        "key_display.toggle", "Toggle Key Display", make_toggle_callback())
    if toggle_hotkey_id ~= obs.OBS_INVALID_HOTKEY_ID then
        local array = obs.obs_data_get_array(settings, "hotkey_toggle")
        if array then
            obs.obs_hotkey_load(toggle_hotkey_id, array)
            obs.obs_data_array_release(array)
        end
        table.insert(hotkey_ids, toggle_hotkey_id)
    end
end

-- ---------------------------------------------------------------------------
-- OBS script entry points
-- ---------------------------------------------------------------------------

function script_description()
    return [[Displays keys you press in an OBS text source.

Global mode: shows ANY key pressed on the desktop. Requires the companion key
logger (bin/obs-key-log.py) running — it needs python3-evdev and access to
/dev/input (add your user to the `input` group, then log out/in).

Hotkey mode: binds OBS hotkeys (Settings → Hotkeys → Scripts → "Key Display
slot N"). Press a bound key and it appears in the text source.

Extras:
  * Exceptions — comma-separated keys that won't show up (e.g. "Shift, X, F1").
  * Toggle     — bind "Toggle Key Display" to turn the display on/off.

Add a "Text (FreeType2)" source to your scene, style it (font, color,
background, opacity), select it below, and the keys show on stream/record.]]
end

function script_properties()
    local props = obs.obs_properties_create()

    local p_source = obs.obs_properties_add_list(
        props, "source", "Text Source",
        obs.OBS_COMBO_TYPE_EDITABLE, obs.OBS_COMBO_FORMAT_STRING)
    obs.obs_property_list_add_string(p_source, "(none)", "")

    local sources = obs.obs_enum_sources()
    if sources then
        for _, source in ipairs(sources) do
            local id = obs.obs_source_get_id(source)
            if id == "text_gdiplus"
               or id == "text_freetype2"
               or id == "text_ft2_source" then
                local name = obs.obs_source_get_name(source)
                obs.obs_property_list_add_string(p_source, name, name)
            end
        end
        obs.source_list_release(sources)
    end

    local p_mode = obs.obs_properties_add_list(
        props, "mode", "Mode",
        obs.OBS_COMBO_TYPE_LIST, obs.OBS_COMBO_FORMAT_STRING)
    obs.obs_property_list_add_string(
        p_mode, "Global (any key, needs obs-key-log.py)", "global")
    obs.obs_property_list_add_string(
        p_mode, "OBS hotkeys only (bind in Settings)", "hotkeys")
    obs.obs_property_list_add_string(p_mode, "Both", "both")

    obs.obs_properties_add_text(
        props, "key_file", "Key log file path", obs.OBS_TEXT_DEFAULT)

    obs.obs_properties_add_text(
        props, "exceptions",
        "Exceptions (comma-separated, e.g. Shift, X, F1)", obs.OBS_TEXT_DEFAULT)

    obs.obs_properties_add_int(
        props, "clear_after", "Clear text after (seconds, 0 = never)", 0, 3600, 1)
    obs.obs_properties_add_text(props, "prefix", "Prefix text", obs.OBS_TEXT_DEFAULT)
    obs.obs_properties_add_text(props, "suffix", "Suffix text", obs.OBS_TEXT_DEFAULT)
    obs.obs_properties_add_bool(props, "uppercase", "Uppercase keys")

    return props
end

function script_defaults(settings)
    obs.obs_data_set_default_string(settings, "mode", "global")
    obs.obs_data_set_default_string(settings, "source", "")
    obs.obs_data_set_default_string(settings, "key_file", "")
    obs.obs_data_set_default_string(settings, "exceptions", "")
    obs.obs_data_set_default_int(settings, "clear_after", 3)
    obs.obs_data_set_default_string(settings, "prefix", "")
    obs.obs_data_set_default_string(settings, "suffix", "")
    obs.obs_data_set_default_bool(settings, "uppercase", false)
end

function script_update(settings)
    state.source_name   = trim(obs.obs_data_get_string(settings, "source"))
    state.mode          = obs.obs_data_get_string(settings, "mode")
    state.key_file      = trim(obs.obs_data_get_string(settings, "key_file"))
    state.clear_after   = obs.obs_data_get_int(settings, "clear_after")
    state.prefix        = obs.obs_data_get_string(settings, "prefix")
    state.suffix        = obs.obs_data_get_string(settings, "suffix")
    state.uppercase     = obs.obs_data_get_bool(settings, "uppercase")
    state.exceptions    = obs.obs_data_get_string(settings, "exceptions")
    exceptions_list     = split_csv(state.exceptions)

    if state.key_file == "" then
        state.key_file = default_key_file()
    end

    reload_hotkeys(settings)

    -- Reset the displayed text when the config changes.
    set_source_text("")
    last_text = ""
    last_update_time = 0
end

function script_save(settings)
    for i = 1, NUM_HOTKEYS do
        local id = hotkey_ids[i]
        if id and id ~= obs.OBS_INVALID_HOTKEY_ID then
            local array = obs.obs_hotkey_save(id)
            obs.obs_data_set_array(settings, "hotkey_slot" .. i, array)
            obs.obs_data_array_release(array)
        end
    end
    if toggle_hotkey_id and toggle_hotkey_id ~= obs.OBS_INVALID_HOTKEY_ID then
        local array = obs.obs_hotkey_save(toggle_hotkey_id)
        obs.obs_data_set_array(settings, "hotkey_toggle", array)
        obs.obs_data_array_release(array)
    end
end

function script_load(settings)
    if trim(obs.obs_data_get_string(settings, "key_file")) == "" then
        obs.obs_data_set_string(settings, "key_file", default_key_file())
    end
    if obs.obs_data_get_string(settings, "exceptions") == nil then
        obs.obs_data_set_string(settings, "exceptions", "")
    end
    script_update(settings)

    -- Poll the key-log file so global keys show up.
    obs.timer_add(check_file, 150)
end

function script_unload()
    obs.timer_remove(check_file)
    for _, id in ipairs(hotkey_ids) do
        obs.obs_hotkey_unregister(id)
    end
    hotkey_ids = {}
    toggle_hotkey_id = nil
    set_source_text("")
end
