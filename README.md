# Vendor+

A vendor window upgrade for **WoW Forever** by **helnwein**.

## Features

- Search across every vendor page and compact matching items into standard slots.
- Filter unusable items, collected appearances, recipes, food and mana drinks.
- Shift-click vendor items to buy a custom quantity, including multiple stacks and unstackable items.
- See unit and total purchase prices in the native quantity window.
- Configure junk, consumable and soulbound gear selling from the vendor junk button.
- Review gear six items per page, with tooltips, a live total and a remembered item blacklist.
- Confirmed sales put junk and consumables first and gear last for Buyback.
- Shift-click an item in your bags to confirm selling all eligible copies, including the reagent bag.
- Settings and blacklists are stored per character.
- Automatic localization through `GetLocale()` with English fallback.

Smart selling uses rules rather than a full gear simulator. Review gear before accepting.

## Installation

Download a release ZIP and extract its `VendorPlus` folder into your WoW Forever `Interface/AddOns` directory. Restart the game after first installation.

## Controls

- Vendor search and **Filter**: find and filter stock.
- **Shift-click a vendor item**: choose a purchase quantity.
- **Right-click Sell All Junk**: configure selling rules.
- **Left-click Sell All Junk**: sell eligible items, with confirmation whenever gear is included.
- Uncheck gear in the preview to blacklist its item ID; check it again to allow selling.

## Build a release ZIP

Requires Python 3 and no third-party packages:

```sh
python3 tools/package.py
```

The ZIP is written to `dist/`. It contains only addon Lua files, the TOC and the icon.

## Publish this repository to GitHub

Create an empty GitHub repository, then run from this project folder:

```sh
git remote add origin <your-repository-url>
git push -u origin main
git push origin --tags
```

See [CHANGELOG.md](CHANGELOG.md) for release history.
