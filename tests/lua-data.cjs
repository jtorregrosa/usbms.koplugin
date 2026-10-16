const fs = require("node:fs");
const path = require("node:path");
const source = fs.readFileSync(path.join(__dirname, "..", "usbms.koplugin", "main.lua"), "utf8");
const names = [
    "function USBMS:plugTimeout", "local function copyFile", "local function writeScreenTexts",
    "local function readLine", "local function readPid", "local function releaseStartLock",
    "local function clearStaleLock",
];
const functions = names.map(name => {
    const start = source.indexOf(name + "(");
    const end = source.indexOf("\nend", start);
    if (start < 0 || end < start) throw new Error(`Missing ${name}`);
    return source.slice(start, end + 4);
}).join("\n");
const screenKeys = source.match(/^local SCREEN_KEYS = \{[^}]*\}/m);
if (!screenKeys) throw new Error("Missing SCREEN_KEYS");
process.stdout.write(`
local USBMS = {}
local G_reader_settings = {}
local HELPER_SCREEN_TEXTS = "screen.txt"
local HELPER_LOCK = "lock"
local HELPER_LOCK_PID = "lock/pid"
local STALE_LOCK_AGE = 30
${screenKeys[0]}
local S = { screen_texts = {} }
for _, key in ipairs(SCREEN_KEYS) do
    S.screen_texts[key] = "Title\\nText"
end
local now, lock_changed, existing, lock_pid, removed_paths = 1000, nil, {}, nil, {}
local ffi = { C = { getpid = function() return 42 end } }
local lfs = { attributes = function() return lock_changed end }
local util = { pathExists = function(p) return existing[p] == true end }
local logger = { warn = function() end }
local real_time = os.time
${functions}
local count = 0
local function check(condition, label)
    assert(condition, label)
    count = count + 1
end
for _, item in ipairs({
    { false, 120 }, { "bad", 120 }, { "60", 120 }, { 0/0, 120 },
    { math.huge, 120 }, { -math.huge, 120 }, { -1, 60 }, { 1000, 600 },
    { 90.5, 90 }, { 120, 120 },
}) do
    G_reader_settings.readSetting = function() return item[1] end
    check(USBMS:plugTimeout() == item[2], "timeout")
end
local removed, executed, writes, renamed
local function setup(failure)
    removed = false; executed = false; renamed = nil; writes = {}
    io.open = function(_, mode)
        if failure == "open" then return nil end
        return {
            read = function() if failure == "read" then return nil end; return "payload" end,
            write = function(_, ...)
                if failure == "write" then return nil end
                writes[#writes + 1] = table.concat({...})
                return true
            end,
            close = function()
                if (mode == "rb" and failure == "read_close") or (mode ~= "rb" and failure == "close") then return nil end
                return true
            end,
        }
    end
    os.remove = function() removed = true end
    os.execute = function() executed = true; if failure == "chmod" then return 1 end; return 0 end
    os.rename = function(from, to)
        if failure == "rename" then return nil, "busy" end
        renamed = from .. ">" .. to
        return true
    end
end
for _, failure in ipairs({ "open", "read", "read_close", "write", "close", "chmod", "rename" }) do
    setup(failure)
    local copied, detail = copyFile("source", "target", "755")
    check(not copied, "copy rejects " .. failure)
    check(type(detail) == "string" and #detail > 0, "copy explains " .. failure)
    if failure == "write" or failure == "close" or failure == "chmod" or failure == "rename" then
        check(removed, "partial target removed")
    end
end
setup("none")
check(copyFile("source", "target", "755") and executed and not removed, "copy succeeds")
check(renamed == "target.new>target", "copy replaces the target by rename")
for _, failure in ipairs({ "write", "close" }) do
    setup(failure)
    check(not writeScreenTexts() and removed, "screen write rejects " .. failure)
end
setup("none")
check(writeScreenTexts() and #writes == #SCREEN_KEYS, "screen texts succeed")
check(writes[1] == "waiting_title=Title Text\\n", "screen texts normalize newlines")
check(#SCREEN_KEYS == 8 and SCREEN_KEYS[8] == "recovery_text", "recovery screen texts are passed on")

-- Stale lock: { age, owner pid, owner alive, cancel file, expected cleared }
os.time = function() return now end
for _, case in ipairs({
    { 60, 7, false, false, true, "dead owner" },
    { 60, nil, false, false, true, "no owner" },
    { 60, 7, true, false, false, "live owner" },
    { 5, 7, false, false, false, "recent lock" },
    { 60, 42, true, true, true, "own cancelled start" },
    { 60, 42, true, false, false, "own start in progress" },
}) do
    lock_changed = now - case[1]
    lock_pid = case[2]
    existing = { ["/proc/" .. tostring(lock_pid)] = case[3], ["lock/cancel"] = case[4] }
    removed_paths = {}
    io.open = function(p)
        if p ~= "lock/pid" or not lock_pid then return nil end
        return { read = function() return tostring(lock_pid) end, close = function() return true end }
    end
    os.remove = function(p) removed_paths[#removed_paths + 1] = p end
    clearStaleLock()
    local cleared = removed_paths[#removed_paths] == "lock"
    check(cleared == case[5], "stale lock: " .. case[6])
end
lock_changed = nil
removed_paths = {}
clearStaleLock()
check(#removed_paths == 0, "stale lock: no lock")
os.time = real_time
print("PASS " .. count .. " Lua data assertions")
`);
