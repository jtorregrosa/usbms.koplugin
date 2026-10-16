--[[--
USB mass storage for KOReader on jailbroken Kindles.

KOReader cannot stay up while the userstore is exported (it lives on it), so this plugin hands the
session to a helper on tmpfs and quits. Two methods:

* direct (default when running without the framework): usbms_direct.sh pauses koreader.sh, exports
  /dev/mmcblk0p4 itself the way volumd does, and lets koreader.sh restart KOReader on eject.
* framework (alternative): usbms_framework.sh lets koreader.sh bring the Amazon framework back,
  which exports the drive, and starts KOReader again once the cable is unplugged (~1 min).

Strings live in usbms_l10n.lua, picked by KOReader's language setting.

@module koplugin.usbms
--]]--

local Device = require("device")
if not Device:isKindle() then
    return { disabled = true, }
end

local ConfirmBox = require("ui/widget/confirmbox")
local Dispatcher = require("dispatcher")
local Event = require("ui/event")
local InfoMessage = require("ui/widget/infomessage")
local UIManager = require("ui/uimanager")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local ffi = require("ffi")
local ffiutil = require("ffi/util")
local logger = require("logger")
local util = require("util")
local T = ffiutil.template

require("ffi/posix_h")

local S = require("usbms_l10n")(G_reader_settings:readSetting("language"))

local WORK_DIR = "/var/tmp/usbms-koplugin"
local HELPER_PIDFILE = WORK_DIR .. "/helper.pid"
local HELPER_LOCK = WORK_DIR .. "/lock"
local HELPER_LOCK_PID = WORK_DIR .. "/lock/pid"
local HELPER_READY = WORK_DIR .. "/ready"
local HELPER_LOG = "/var/local/usbms-koplugin.log"
local HELPER_RESULT = WORK_DIR .. "/result"
local HELPER_SCREEN_TEXTS = WORK_DIR .. "/screen.txt"
local SSH_PIDFILE = "/tmp/dropbear_koreader.pid"
-- 1 once a computer has enumerated the Kindle; 0 with no cable or a plain charger.
local USB_CONNECTED = "/sys/devices/platform/fsl-usb2-udc/gadget/connected"
-- What the direct helper needs off the userstore besides itself: KOReader's fbink (OpenType text,
-- no image support), a font for it, and the three screens as raw framebuffer dumps.
local DIRECT_PAYLOAD = {
    { src = "./fbink", dst = "fbink", mode = "755" },
    { src = "./fonts/noto/NotoSans-Regular.ttf", dst = "NotoSans-Regular.ttf", mode = "644" },
    { plugin = "screens/usb-waiting.raw", dst = "usb-waiting.raw", mode = "644", optional = true },
    { plugin = "screens/usb-active.raw", dst = "usb-active.raw", mode = "644", optional = true },
    { plugin = "screens/usb-returning.raw", dst = "usb-returning.raw", mode = "644", optional = true },
}
-- koreader.sh loops on 85, which the direct helper relies on to bring KOReader back.
local EXIT_CODE_RESTART = 85
-- Any other code makes koreader.sh resume volumd and the framework; 86 is KOReader's USBMS code on Kobo.
local EXIT_CODE_USBMS = 86

local function hostConnected()
    local f = io.open(USB_CONNECTED, "r")
    if not f then return false end
    local v = f:read("*l")
    f:close()
    return v == "1"
end

local USBMS = WidgetContainer:extend{
    name = "usbms",
    is_doc_only = false,
}

function USBMS:init()
    self:onDispatcherRegisterActions()
    self.ui.menu:registerToMainMenu(self)
    for _, attribute in ipairs({ "virtual_size", "bits_per_pixel", "stride" }) do
        local diagnostic = io.open("/sys/class/graphics/fb0/" .. attribute, "r")
        local value = diagnostic and diagnostic:read("*l") or "unavailable"
        if diagnostic then diagnostic:close() end
        logger.info("USBMS framebuffer:", attribute, value)
    end
    local diagnostic = io.open(HELPER_LOG, "r")
    if diagnostic then
        local length = diagnostic:seek("end")
        if length and diagnostic:seek("set", math.max(0, length - 16384)) then
            for line in diagnostic:lines() do
                if line:find("Image ", 1, true) then logger.info("USBMS image diagnostic:", line) end
            end
        end
        diagnostic:close()
    end
    -- Coming back from a session with the cable still in, powerd reports charging again; do not
    -- ask to share a second time until the cable has actually been pulled. After an unplug the
    -- cable is already out, and the "not charging" event that lifts this would never come.
    self.prompt_suppressed = self:showLastResult() and hostConnected()
end

function USBMS:onDispatcherRegisterActions()
    Dispatcher:registerAction("usbms_start", {
        category = "none",
        event = "StartUSBMS",
        title = S.action_start,
        device = true,
    })
end

function USBMS:promptOnPlug() return G_reader_settings:nilOrTrue("usbms_prompt_on_plug") end
function USBMS:useFramework() return G_reader_settings:isTrue("usbms_use_framework") end
function USBMS:alwaysFsck() return G_reader_settings:isTrue("usbms_always_fsck") end
function USBMS:autoReturn() return G_reader_settings:nilOrTrue("usbms_auto_return") end
function USBMS:plugTimeout()
    local value = G_reader_settings:readSetting("usbms_plug_timeout")
    if type(value) ~= "number" or value ~= value or value == math.huge or value == -math.huge then
        return 120
    end
    return math.max(60, math.min(600, math.floor(value)))
end

-- The direct method needs koreader.sh as our parent and the framework stopped (with it up,
-- the framework holds the userstore, and quitting KOReader already hands USB back to it).
function USBMS:canGoDirect()
    if os.getenv("STOP_FRAMEWORK") ~= "yes" then
        return false
    end
    local f = io.open(string.format("/proc/%d/cmdline", ffi.C.getppid()), "rb")
    if not f then return false end
    local cmdline = f:read("*a")
    f:close()
    return cmdline:find("koreader.sh", 1, true) ~= nil
end

function USBMS:isDirect()
    return not self:useFramework() and self:canGoDirect()
end

function USBMS:addToMainMenu(menu_items)
    -- KOReader's own menu order already reserves this key for USBMS on the main menu.
    menu_items.mass_storage_actions = {
        text = S.menu_start,
        callback = function() self:confirmStart() end,
    }
    -- And this one in the Device menu.
    menu_items.mass_storage_settings = {
        text = S.menu_settings,
        sorting_hint = "device",
        sub_item_table = {
            {
                text = S.prompt_on_plug,
                help_text = S.prompt_on_plug_help,
                checked_func = function() return self:promptOnPlug() end,
                callback = function()
                    G_reader_settings:saveSetting("usbms_prompt_on_plug", not self:promptOnPlug())
                end,
            },
            {
                text = S.use_framework,
                help_text = S.use_framework_help,
                enabled_func = function() return self:canGoDirect() end,
                checked_func = function() return not self:isDirect() end,
                callback = function()
                    G_reader_settings:saveSetting("usbms_use_framework", not self:useFramework())
                end,
                separator = true,
            },
            {
                text = S.always_fsck,
                help_text = S.always_fsck_help,
                enabled_func = function() return self:isDirect() end,
                checked_func = function() return self:alwaysFsck() end,
                callback = function()
                    G_reader_settings:saveSetting("usbms_always_fsck", not self:alwaysFsck())
                end,
            },
            {
                text = S.auto_return,
                help_text = S.auto_return_help,
                enabled_func = function() return not self:isDirect() end,
                checked_func = function() return self:autoReturn() end,
                callback = function()
                    G_reader_settings:saveSetting("usbms_auto_return", not self:autoReturn())
                end,
            },
            {
                text_func = function()
                    return T(S.plug_timeout, self:plugTimeout())
                end,
                help_text = S.plug_timeout_help,
                enabled_func = function() return not self:isDirect() end,
                keep_menu_open = true,
                callback = function(touchmenu_instance)
                    local SpinWidget = require("ui/widget/spinwidget")
                    UIManager:show(SpinWidget:new{
                        title_text = S.plug_timeout_title,
                        value = self:plugTimeout(),
                        value_min = 60,
                        value_max = 600,
                        value_step = 30,
                        default_value = 120,
                        callback = function(spin)
                            G_reader_settings:saveSetting("usbms_plug_timeout", spin.value)
                            touchmenu_instance:updateItems()
                        end,
                    })
                end,
                separator = true,
            },
            {
                text = S.show_log,
                enabled_func = function() return util.fileExists(HELPER_LOG) end,
                callback = function() self:showLog() end,
            },
        },
    }
end

function USBMS:onStartUSBMS()
    self:confirmStart()
    return true
end

-- The charger reports "charging" for any cable, and briefly even while it is being pulled.
-- Give the host time to enumerate, then ask only if one is really there and we are awake.
function USBMS:schedulePrompt()
    if self.prompt_suppressed or not self:promptOnPlug() or self.confirm_box or self.prompt_scheduled then
        return
    end
    self.prompt_scheduled = true
    UIManager:scheduleIn(2, function()
        self.prompt_scheduled = nil
        if hostConnected() and not self.confirm_box and not Device.screen_saver_mode then
            self:confirmStart()
        end
    end)
end

function USBMS:onCharging()
    self:schedulePrompt()
end

-- Plugging the cable into a sleeping Kindle wakes it, but the charging event arrives while the
-- screensaver is still up; ask again once we are back.
function USBMS:onResume()
    self:schedulePrompt()
end

function USBMS:onNotCharging()
    self.prompt_suppressed = false
    if self.confirm_box then
        UIManager:close(self.confirm_box)
        self.confirm_box = nil
    end
end

function USBMS:confirmStart()
    if self.confirm_box then return end
    local text
    if self:isDirect() then
        text = S.confirm_direct
    else
        text = T(S.confirm_framework, self:plugTimeout())
    end
    self.confirm_box = ConfirmBox:new{
        text = text,
        ok_text = S.share,
        ok_callback = function()
            self.confirm_box = nil
            self:start()
        end,
        cancel_callback = function()
            self.confirm_box = nil
        end,
    }
    UIManager:show(self.confirm_box)
end

function USBMS:showError(text)
    UIManager:show(InfoMessage:new{ icon = "notice-warning", text = text })
end

local function copyFile(src, dst, mode)
    local fin, err = io.open(src, "rb")
    if not fin then return false, "open source: " .. src .. ": " .. tostring(err) end
    local data, read_err = fin:read("*a")
    local read_closed, close_err = fin:close()
    if data == nil then return false, "read: " .. src .. ": " .. tostring(read_err) end
    if not read_closed then return false, "close source: " .. src .. ": " .. tostring(close_err) end
    local fout, open_err = io.open(dst, "wb")
    if not fout then return false, "open target: " .. dst .. ": " .. tostring(open_err) end
    local ok, write_err = fout:write(data)
    local closed, target_close_err = fout:close()
    if not ok or not closed then
        os.remove(dst)
        return false, "write/close target: " .. dst .. ": " .. tostring(write_err or target_close_err)
    end
    if os.execute(string.format("chmod %s '%s'", mode, dst)) ~= 0 then
        os.remove(dst)
        return false, "chmod: " .. dst
    end
    return true
end

-- The direct helper prints these on the e-ink status screens; one key=value per line.
local function writeScreenTexts()
    local f = io.open(HELPER_SCREEN_TEXTS, "w")
    if not f then return false end
    for _, key in ipairs({ "waiting_title", "waiting_text", "active_title", "active_text", "returning_title", "returning_text" }) do
        if not f:write(key, "=", (S.screen_texts[key]:gsub("[\r\n]", " ")), "\n") then
            f:close()
            os.remove(HELPER_SCREEN_TEXTS)
            return false
        end
    end
    if not f:close() then
        os.remove(HELPER_SCREEN_TEXTS)
        return false
    end
    return true
end

local function readLine(path)
    local f = io.open(path, "r")
    if not f then return nil end
    local line = f:read("*l")
    f:close()
    return line
end

local function readPid(path)
    return tonumber(readLine(path))
end

local function helperRunning()
    return util.pathExists(HELPER_LOCK)
end

local function writeLine(path, value)
    local f, err = io.open(path, "w")
    if not f then return false, "open: " .. path .. ": " .. tostring(err) end
    local ok, write_err = f:write(value, "\n")
    local closed, close_err = f:close()
    if not ok or not closed then
        return false, "write/close: " .. path .. ": " .. tostring(write_err or close_err)
    end
    return true
end

local function releaseStartLock()
    os.remove(HELPER_LOCK .. "/token")
    os.remove(HELPER_LOCK_PID)
    os.remove(HELPER_LOCK)
end

-- Everything the direct helper runs or draws must live off the userstore, which goes away.
function USBMS:copyDirectPayload()
    for _, item in ipairs(DIRECT_PAYLOAD) do
        local src = item.src or (self.path .. "/" .. item.plugin)
        local copied, detail = copyFile(src, WORK_DIR .. "/" .. item.dst, item.mode)
        if not copied then
            if not item.optional then
                return false, detail
            end
            logger.info("USBMS: optional file missing, helper falls back without it:", src)
        end
    end
    return true
end

function USBMS:start()
    if self.starting or helperRunning() then
        self:showError(S.session_running)
        return
    end
    self.starting = true
    local direct = self:isDirect()
    local script = direct and "usbms_direct.sh" or "usbms_framework.sh"
    local helper = WORK_DIR .. "/" .. script

    os.execute("mkdir -p " .. WORK_DIR)
    if os.execute("mkdir " .. HELPER_LOCK .. " 2>/dev/null") ~= 0 then
        self.starting = nil
        self:showError(S.session_running)
        return
    end
    self.session_counter = (self.session_counter or 0) + 1
    local token = string.format("%d-%d-%d", ffi.C.getpid(), os.time(), self.session_counter)
    local reserved, reserve_detail = writeLine(HELPER_LOCK .. "/token", token)
    if reserved then
        reserved, reserve_detail = writeLine(HELPER_LOCK_PID, tostring(ffi.C.getpid()))
    end
    if not reserved then
        releaseStartLock()
        self.starting = nil
        logger.warn("USBMS session reservation failed:", reserve_detail)
        self:showError(T(S.copy_failed, WORK_DIR) .. "\n\n" .. tostring(reserve_detail))
        return
    end
    local copied, detail = copyFile(self.path .. "/" .. script, helper, "755")
    if copied and direct then
        copied, detail = self:copyDirectPayload()
        if copied and not writeScreenTexts() then
            copied, detail = false, "write screen texts: " .. HELPER_SCREEN_TEXTS
        end
    end
    if not copied then
        releaseStartLock()
        self.starting = nil
        logger.warn("USBMS payload preparation failed:", detail)
        self:showError(T(S.copy_failed, WORK_DIR) .. "\n\n" .. tostring(detail))
        return
    end
    os.remove(HELPER_READY)
    os.remove(HELPER_RESULT)

    -- Both helpers acknowledge this session; direct also pauses koreader.sh before answering.
    local args
    if direct then
        args = string.format("%d %d %s %d %s", ffi.C.getpid(), ffi.C.getppid(), token, 30,
            self:alwaysFsck() and "always" or "auto")
    else
        -- Relaunch the way we were launched: koreader.sh exports STOP_FRAMEWORK=yes without the framework.
        args = string.format("%d %s %d %d %s", ffi.C.getpid(),
            os.getenv("STOP_FRAMEWORK") == "yes" and "--framework_stop" or "--asap",
            self:autoReturn() and 1 or 0, self:plugTimeout(), token)
    end
    local cmd = string.format("cd / && ( $(command -v setsid) sh %s %s < /dev/null > /dev/null 2>&1 & )", helper, args)
    logger.info("USBMS: starting helper:", cmd)
    os.execute(cmd)

    -- Quit only once the helper is ready, or nothing would bring KOReader back.
    local helper_pid
    for _i = 1, 100 do
        if readLine(HELPER_READY) == token then
            local pid = readPid(HELPER_PIDFILE)
            if pid and pid ~= ffi.C.getpid() and pid == readPid(HELPER_LOCK_PID)
                and util.pathExists("/proc/" .. pid) then
                helper_pid = pid
            end
            break
        end
        local result = readLine(HELPER_RESULT)
        if result and not helperRunning() then break end
        ffiutil.usleep(100000)
    end
    if not helper_pid then
        writeLine(HELPER_LOCK .. "/cancel", token)
        self.starting = nil
        local result = readLine(HELPER_RESULT)
        os.remove(HELPER_RESULT)
        self:showError(S.result[result] or S.helper_not_started)
        return
    end

    -- KOReader's SSH server runs from /mnt/us/koreader and would keep the userstore busy.
    local ssh_pid = readPid(SSH_PIDFILE)
    if ssh_pid then
        logger.info("USBMS: stopping SSH server", ssh_pid)
        os.execute(string.format("kill -TERM %d", ssh_pid))
    end

    UIManager:show(InfoMessage:new{
        text = S.leaving,
        timeout = 2,
    })
    UIManager:scheduleIn(0.5, function()
        UIManager:flushSettings()
        logger.info("USBMS: exiting KOReader, helper pid", helper_pid, direct and "(direct)" or "(framework)")
        UIManager:broadcastEvent(Event:new("Close"))
        UIManager:quit(direct and EXIT_CODE_RESTART or EXIT_CODE_USBMS)
    end)
end

-- The direct helper leaves its outcome for the KOReader it brings back. Returns true if there was one.
function USBMS:showLastResult()
    local result = readLine(HELPER_RESULT)
    if not result then return false end
    os.remove(HELPER_RESULT)
    local text = S.result[result]
    if not text then return false end
    local ok = result == "eject" or result == "unplug"
    UIManager:show(InfoMessage:new{
        icon = not ok and "notice-warning" or nil,
        text = text,
        timeout = ok and 3 or nil,
    })
    return true
end

function USBMS:showLog()
    local f = io.open(HELPER_LOG, "r")
    if not f then return end
    local text = f:read("*a")
    f:close()
    local TextViewer = require("ui/widget/textviewer")
    UIManager:show(TextViewer:new{
        title = S.log_title,
        text = text,
    })
end

return USBMS
