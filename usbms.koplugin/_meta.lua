-- Plugin strings are not in KOReader's catalogue; usbms_l10n.lua picks them by KOReader's language.
local S = require("usbms_l10n")(G_reader_settings:readSetting("language"))
return {
    fullname = S.plugin_name,
    description = S.plugin_description,
    version = "1.0.0",
}
