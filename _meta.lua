-- Boundary: KOReader plugin metadata.
--
-- Responsibility: expose the plugin name, description, and entrypoint metadata
-- consumed by KOReader's plugin loader.
-- Owned state: none.
-- Dependencies: plugin i18n facade only.
-- External data: none.

local I18n = require("suwayomi/i18n")

return {
    name = "suwayomiplus",
    fullname = I18n.t("Suwayomi+ v1.0.3"),
    description = I18n.t([[Suwayomi client for KOReader: stream manga online, download chapters for offline reading, sync progress and trackers, and browse History and Updates from your server.]]),
    version = "1.0.3",
}
