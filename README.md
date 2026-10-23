# RhythmBar (FFXI Action Lockout & Rhythm Bar)

A lightweight, 60 FPS center-draining rhythm bar addon for **Final Fantasy XI (Windower 4)** that visualizes FFXI's hidden post-action **Forced Delay (action lockout)** across all regular actions—so you know the exact millisecond you can press your next button without your input getting eaten.

```text
During Cast:     [     ████████|████████     ]  (Cyan: Filling outward while casting)
Post-Action Lock:[  ███████████|███████████  ]  (Draining inward toward center tick)
Ready / Empty:   [             |             ]  (Flashes Neon Green -> Auto-Hides!)
```

## Why This Exists
Unlike modern MMOs, **FFXI has no action queue buffer**, and your character's visual animation finishes *before* the server lockout actually expires. Pressing a macro or crossbar button even `50ms` early silently drops your action or prints `"Unable to use job ability."` / `"Unable to cast spells at this time."`

**RhythmBar** solves this by drawing a compact, color-coded bar that shrinks from both edges into a center target tick: **wait until the bar collapses into the center line, then press your next button.**

---

## Color Coding & Action Coverage

| Action / Phase | Color | Lockout / Behavior |
| :--- | :--- | :--- |
| **Job Ability / Step / Flourish / Waltz / Samba / Ward** | **Gold / Amber** $\rightarrow$ **Lime-Gold** | Drains into center over **`1.10s`** (brightens in the final `0.25s`). |
| **Weapon Skill / TP Move** | **Coral Red-Orange** $\rightarrow$ **Amber** | Drains into center over **`2.05s`**. |
| **Spell / Song / Ninjutsu (Casting)** | **Electric Cyan** | Fills outward from center using adaptive Fast Cast learning. |
| **Spell Post-Cast Lock (`0.0s–2.05s`)** | **Vibrant Purple** | Drains toward two gold sub-ticks. **Everything is locked** (no JA/WS/Spell). |
| **Spell Post-Cast Lock (`2.05s–3.08s`)** | **Sky Blue** | Crosses the sub-ticks and turns **Sky Blue** for the last **`1.03s`**: **JAs & Weapon Skills are unlocked NOW**, or wait until empty for your next **Spell**! |
| **Ranged Attack (`/ra`)** | **Teal** (Aim) $\rightarrow$ **Orange** (Lock) | Aiming bar followed by **`1.60s`** post-shot lockout. |
| **Item Use (`/item`)** | **Emerald Mint** | Item cast followed by **`1.15s`** post-item lockout. |
| **Pressed Too Early / Interrupted!** | **Hot Red Flash** | Flashes **Red** (`0.22s`) if you press an action before the lockout finishes. |
| **Ready (Empty)** | **Neon Green Pulse** $\rightarrow$ **Hidden** | Pulses green for `0.18s` when empty, then **auto-hides** out of the way. |

---

## Key Features
* **1-Frame Instant Response + Live RTT Learning**: Starts shrinking the instant you press a JA or WS button (`0x01A`) and continuously learns your network round-trip latency (`RTT`) so the bar smoothly locks onto the server's `0x028` completion packet without jumping.
* **Adaptive Fast Cast Learning**: Automatically measures your real spell cast times (`Cat 8` $\rightarrow$ `Cat 4`) per magic skill and base cast time, accounting for Fast Cast gear swaps, Job Gifts, and server tick alignment (inspired by [hikaruoshino/FF11-MBReadyTimer](https://github.com/hikaruoshino/FF11-MBReadyTimer)).
* **Self-Calibrating Auto-Tune**: If your connection has higher latency and the server rejects an action right after the bar empties, RhythmBar automatically nudges that action category's lockout by `+0.04s` and saves it.
* **Sized for `xivcrossbar` (or Drag Anywhere)**: Defaults to `96×6 px` anchored neatly inside the center gap of `xivcrossbar`. Don't use `xivcrossbar`? Run `//rbar test` and **click-and-drag the bar with your mouse** anywhere on screen!
* **Ultra-Low Overhead**: Uses dirty-flagged Direct3D 8 hardware primitives (`windower.prim`), zero texture files, a 4-byte raw actor filter on `0x028` packets, and a 1-nanosecond idle exit when hidden.

---

## Installation
1. Click **Code** $\rightarrow$ **Download ZIP** (or clone this repo).
2. Extract the folder into `Windower4/addons/rhythmbar/` (make sure the folder is named **`rhythmbar`** so `Windower4/addons/rhythmbar/rhythmbar.lua` exists).
3. Load in-game:
   ```text
   //lua l rhythmbar
   //rbar test
   ```
   *(To auto-load on startup, add `lua l rhythmbar;` to `Windower4/scripts/init.txt`.)*

---

## Commands (`//rbar`, `//rb`, or `//rhythmbar`)

| Command | Description |
| :--- | :--- |
| `//rbar` | Show current version, screen position, learned RTT (`ms`), and lockout timers |
| `//rbar test [sec]` | Run a live preview cycle (default `12s`). **Click and drag the bar with your mouse** while testing to move it anywhere! |
| `//rbar drag` | Toggle always-on mouse dragging on/off |
| `//rbar size <w> [h]` | Set bar width and height in pixels (default: `//rbar size 96 6`) |
| `//rbar pos <x> <y>` | Set exact screen coordinates |
| `//rbar offset <dx> <dy>` | Set offset relative to screen center/bottom (`xivcrossbar` void default: `8 -198`) |
| `//rbar resetpos` | Reset position back to the `xivcrossbar` center void (`8, -198`) |
| `//rbar text` | Toggle the compact `0.1s` countdown number above the center tick |
| `//rbar autohide` | Toggle auto-hiding when idle/ready (default: `ON`) |
| `//rbar autotune` | Toggle automatic `+0.04s` lockout self-calibration (default: `ON`) |
| `//rbar <ja\|ws\|spell\|ranged\|item> <sec>` | Manually set the lockout duration for any category (e.g., `//rbar ja 1.10`) |

---

## Credits & License
* Spell cast-time moving average inspired by [hikaruoshino/FF11-MBReadyTimer](https://github.com/hikaruoshino/FF11-MBReadyTimer).
* Released under the MIT License.
