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
    fullname = I18n.t("Suwayomi+"),
    description = I18n.t([[Suwayomi client for KOReader: stream manga online first, download chapters as a book (folder + chapter CBZs), sync progress and trackers, History and Updates. Pairs with MaxOutUI and MangaSync.]]),
    version = "1.3.8",
}
