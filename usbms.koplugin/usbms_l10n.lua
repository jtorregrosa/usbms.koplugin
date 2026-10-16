--[[--
Strings for usbms.koplugin.

A plugin cannot add strings to KOReader's gettext catalogue, so the plugin carries its own: the
English source below, and one file per language in l10n/, named with KOReader's language code
(l10n/es.lua, l10n/pt_BR.lua, ...). Each file returns a table with the same keys; a missing key
falls back to English, so a partial translation is fine.

The language is the one KOReader is set to (its "language" setting). "C" or no setting means
English. Lookup order: the exact code, then a known alias, then English.

To add or fix a language, copy l10n/es.lua under the new code and translate the values. Keep the
%1 placeholders, the \n line breaks and the "→" menu paths. Where KOReader already translates a
phrase (its own USB storage feature on Kobo: "Start USB storage", "Share storage via USB?",
"Share", "USB mass storage", and its "Device" menu), reuse KOReader's wording so the plugin reads
like the rest of the UI.

screen_font_ok = false marks languages whose script the full-screen status texts cannot draw:
those screens are printed by KOReader's fbink with Noto Sans, which covers Latin, Greek and
Cyrillic only and does no right-to-left or complex shaping. Those languages get English texts on
the e-ink status screens, and their own language everywhere else.
--]]--

local en = {
    plugin_name = "USB mode (Kindle)",
    plugin_description = "Leaves KOReader to share the storage over USB and comes back on its own when the computer ejects the Kindle or the cable is unplugged.",
    menu_start = "Start USB storage",
    menu_settings = "USB mass storage",
    action_start = "Start USB storage",
    prompt_on_plug = "Ask when a computer is connected",
    prompt_on_plug_help = "When a computer detects the Kindle, ask whether to enter USB mode.",
    use_framework = "Use the Amazon UI (slow)",
    use_framework_help = "Alternative method: starts the Amazon UI to export the storage and returns to KOReader afterwards. Takes about a minute. Always used when KOReader runs with the Amazon framework up.",
    always_fsck = "Always check the file system",
    always_fsck_help = "Direct method: run dosfsck after every session, not only when the cable was pulled without ejecting. Adds a few seconds.",
    auto_return = "Amazon UI: return to KOReader when done",
    auto_return_help = "When off, you stay in the Amazon UI after ejecting the Kindle.",
    plug_timeout = "Amazon UI: wait for the computer %1 s",
    plug_timeout_help = "Longest wait between leaving KOReader and the computer mounting the drive. Includes the Amazon UI start (30-60 s).",
    plug_timeout_title = "Wait for the computer (s)",
    show_log = "Show last session log",
    log_title = "USB mode log",
    confirm_direct = "Share storage via USB?\n\nKOReader closes while the computer uses the storage and comes back when it is ejected.",
    confirm_framework = "Share storage via USB?\n\nKOReader closes, the Amazon UI exports the drive and KOReader comes back after the eject (about 1 min).\n\nIf no computer is connected within %1 s, KOReader comes back on its own.",
    share = "Share",
    leaving = "Leaving KOReader for USB mode…",
    session_running = "A USB session is already running.",
    copy_failed = "Could not copy the helper to %1.",
    helper_not_started = "The USB helper did not start. KOReader stays open.",
    result = {
        eject = "USB session finished.",
        unplug = "Cable pulled without ejecting. The file system was checked.",
        nohost = "No computer detected. Connect the cable to a computer (not a charger) and try again.",
        busy = "The storage was busy and was not exported. See the log under Device → USB mass storage.",
        precheck = "USB mode was not started: a pre-flight check failed and nothing was touched. See the log under Device → USB mass storage.",
        fail = "USB mode failed. See the log under Device → USB mass storage.",
        fsckfail = "The file system check did not finish cleanly. Back up the storage from the computer and run chkdsk before using it further. See the log under Device → USB mass storage.",
    },
    screen_font_ok = true,
    screen = {
        waiting_title = "USB mode",
        waiting_text = "Connect the cable to a computer.",
        active_title = "USB storage active",
        active_text = "Eject the Kindle on the computer to return to KOReader.",
        returning_title = "USB mode",
        returning_text = "Returning to KOReader…",
        recovery_title = "USB recovery required",
        recovery_text = "Unplug USB and hold power for 40 s.",
    },
}

-- KOReader codes whose texts live under another file.
local ALIASES = {
    C = "en", en_GB = "en", en_US = "en", ro_MD = "ro",
    -- Bare language codes (e.g. from $LANG) to the variant KOReader ships.
    it = "it_IT", lt = "lt_LT", nl = "nl_NL", nb = "nb_NO", no = "nb_NO", bg = "bg_BG",
    ko = "ko_KR", zh = "zh_CN", pt = "pt_PT",
}

local dir = debug.getinfo(1, "S").source:match("^@(.*)[/\\]") or "."

local function loadFile(code)
    if code == "en" or not code:match("^[%a_]+$") then return nil end
    local ok, t = pcall(dofile, dir .. "/l10n/" .. code .. ".lua")
    return ok and type(t) == "table" and t or nil
end

local function find(language)
    if type(language) ~= "string" or language == "" then return nil end
    local code = language:match("^([%a_]+)") or ""
    local lang = code:match("^(%a%a%a?)") or ""
    -- Missing aliases are false, not nil: a nil in the middle would stop ipairs before the bare language.
    local candidates = {}
    for _, c in ipairs({ code, ALIASES[code] or false, lang, ALIASES[lang] or false }) do
        if c and c ~= "" then candidates[#candidates + 1] = c end
    end
    for _, c in ipairs(candidates) do
        if c == "en" then return nil end
        local t = loadFile(c)
        if t then return t end
    end
    return nil
end

-- Every key falls back to English, including inside the nested tables.
local function withFallback(t)
    -- A fresh table for English too, so nothing written to the result ever lands in `en`.
    t = t or {}
    for _, sub in ipairs({ "result", "screen" }) do
        t[sub] = setmetatable(type(t[sub]) == "table" and t[sub] or {}, { __index = en[sub] })
    end
    return setmetatable(t, { __index = en })
end

return function(language)
    local S = withFallback(find(language))
    -- What the e-ink status screens print: English where Noto Sans cannot draw the script.
    S.screen_texts = S.screen_font_ok == false and en.screen or S.screen
    return S
end
