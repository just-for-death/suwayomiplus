-- Boundary: KOReader plugin metadata.
--
-- Responsibility: expose the plugin name, description, and entrypoint metadata
-- consumed by KOReader's plugin loader.
-- Owned state: none.
-- Dependencies: plugin i18n facade only.
-- External data: none.

local I18n = require("suwayomi/i18n")

return {
    name = "suwayomi",
    fullname = I18n.t("Suwayomi Client v1.0.8-reader"),
    description = I18n.t([[Suwayomi client for KOReader. Tap a chapter to read it online right away, or open it in the normal reader through a size-capped cache so history and statistics count it. Jump between chapters from inside the reader, track on MAL/AniList, and download CBZ files in bulk.]]),
    version = "1.0.8-reader",
}
