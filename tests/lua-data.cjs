const fs = require("node:fs");
const path = require("node:path");
const source = fs.readFileSync(path.join(__dirname, "..", "usbms.koplugin", "main.lua"), "utf8");
const names = ["function USBMS:plugTimeout", "local function copyFile", "local function writeScreenTexts"];
const functions = names.map(name => {
    const start = source.indexOf(name + "(");
    const end = source.indexOf("\nend", start);
    if (start < 0 || end < start) throw new Error(`Missing ${name}`);
    return source.slice(start, end + 4);
}).join("\n");
process.stdout.write(`
local USBMS = {}
local G_reader_settings = {}
local HELPER_SCREEN_TEXTS = "screen.txt"
local S = { screen_texts = {} }
for _, key in ipairs({ "waiting_title", "waiting_text", "active_title", "active_text", "returning_title", "returning_text" }) do
    S.screen_texts[key] = "Title\\nText"
end
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
local removed, executed, writes
local function setup(failure)
    removed = false; executed = false; writes = {}
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
end
for _, failure in ipairs({ "open", "read", "read_close", "write", "close", "chmod" }) do
    setup(failure)
    local copied, detail = copyFile("source", "target", "755")
    check(not copied, "copy rejects " .. failure)
    check(type(detail) == "string" and #detail > 0, "copy explains " .. failure)
    if failure == "write" or failure == "close" or failure == "chmod" then
        check(removed, "partial target removed")
    end
end
setup("none")
check(copyFile("source", "target", "755") and executed and not removed, "copy succeeds")
for _, failure in ipairs({ "write", "close" }) do
    setup(failure)
    check(not writeScreenTexts() and removed, "screen write rejects " .. failure)
end
setup("none")
check(writeScreenTexts() and #writes == 6, "screen texts succeed")
check(writes[1] == "waiting_title=Title Text\\n", "screen texts normalize newlines")
print("PASS " .. count .. " Lua data assertions")
`);