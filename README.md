# pfUI Income

Addon for **World of Warcraft: Vanilla (1.12)** that tracks session gold by source and shows a breakdown on the money tooltip. Works with [pfUI](https://github.com/shagu/pfUI) and does not require it.

## Features

- **Session income breakdown** — Hover the money display (e.g. in the character panel or on pfUI’s bar) to see how much gold you earned this session from:
  - **Loot** — Gold from looting corpses (`CHAT_MSG_MONEY`)
  - **Auction** — Gold from mail (AH sales, COD, etc.)
  - **Vendor** — Gold from selling to merchants
  - **Quest** — Gold from quest rewards
  - **Other** — Trade, refunds, and anything not classified above

- **Per-login session** — Totals reset when you log in (`PLAYER_LOGIN`).

## Installation

1. Download or clone the addon.
2. Put the `pfUI_Income` folder in `WoW/Interface/AddOns/`.
3. Restart WoW or run `/reload`.

## Requirements

- **Client:** WoW 1.12.x (Interface 11200).

## Compatibility

- **pfUI** — Optional. If present, pfUI Income loads after it and hooks the same money display; no config needed.
- **TurtleMail** (and similar mailbox addons) — Compatible. Mail gold is attributed correctly even when using “Collect All” or any flow that doesn’t call the global `TakeInboxMoney`. No dependency on TurtleMail.

## Author

Bloodysunset
