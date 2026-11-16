# Changelog

## 1.02 — 2026-11-16

- Exclude food with the word "Raw" in its name from low-level consumable selling, protecting raw cooking fish.
- Match the word case-insensitively without excluding unrelated names containing those letters.
- Configure automatic CurseForge packaging with the VendorPlus folder name and development-file exclusions.

## 1.01 — 2026-11-16

- Add optional automatic selling at the top of the selling menu.
- Add automatic repairs to the Repair All button’s right-click menu.
- Keep both options disabled by default and saved per character.
- Preserve gear confirmation, blacklist rules and sale ordering.
- Repair only when supported and personal gold covers the full cost.
- Localize new options and descriptions.
- Split the implementation into focused Lua modules and add regression tests.

## 1.0 — 2026-11-16

- Initial release of Vendor+ for WoW Forever.
- Vendor search and filters, bulk buying, configurable selling, gear review and per-character blacklists.
- Localized interface and per-character settings.
