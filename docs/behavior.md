# How T3 Mini behaves

T3 Mini is inspired by the Pets / Mini overlay in OpenAI's Codex app. Everything below describes this project's
own behavior and tuning; it is not a description of how any other app is implemented.

## Window
- A borderless, transparent panel that floats above other windows on every Space, including full-screen apps.
- It never activates itself: you can type in it while your current app stays frontmost.
- Clicks on transparent areas pass through to the windows underneath; only the pet, bar and cards take clicks.
- First launch places the pet at the bottom-right of the main display.

## At rest
- Only the pet is visible. A small badge on it turns amber when a thread needs input or is blocked, and green when
  the top thread is ready.

## Near the pet
- Moving the pointer within about 40 pt of the pet reveals one compact pill next to it: **＋ New chat** and a
  **bell** with a count (the bell only appears when there are notifications). The pill hides about 300 ms after the
  pointer moves away (beyond about 56 pt), unless you're typing, have a draft, or the tray is open.
- The pill sits directly above or below the pet, toward whichever side of the screen has more room, and is kept on
  screen.
- Hovering the pet itself makes it jump.

## New chat
- Clicking the pet or **＋** opens a composer: a project picker, a text field that grows to five lines, and Send.
  Return sends; the new thread is started with T3's `t3 thread start` and shows up as a Running card.
- Escape closes the composer and hands typing back to your app.

## Notifications
- The bell opens the tray. With more than one item it starts as a collapsed stack (the top card with the next ones
  peeking behind it). Clicking the stack, or scrolling toward it, shows the full list; scrolling back at the end of
  the list, or pressing the bell, collapses it again. Pressing the bell on the stack hides the tray.
- Each card shows the thread title, its state (Running, Needs input, Ready, Blocked) and one line of detail.
  Running cards say what the agent is doing (its latest short reasoning or reply, or the current tool).
- **Ready cards** show a two-line digest of the agent's final reply: what it needs from you (or "Nothing needed from
  you"), and one short sentence on where things stand. The digest is extracted locally from the reply text.
- Clicking a card opens that thread in T3 (`t3code://threads/…`), where you answer questions and approvals.
- Hovering a card shows **Reply** (a follow-up sent with `t3 thread send`) and **×** to dismiss it. Right-click for
  Open, Reply, Peek transcript, Mute chat and Dismiss. Muted chats are listed under **Muted chats** in the menu.
- A dismissal lasts for that run; a new run or a new question brings the card back.
- Cards expire on their own: Blocked after 1 hour, Needs input after 24 hours, Ready after 7 days.
- Order: Needs input, Blocked, Ready, Running, newest first.

## Pet
- Drag the pet anywhere; it stays where you drop it. Hold **Option** when releasing to snap it to one of six spots
  (top or bottom × left, centre, right).
- Its animation follows the most urgent card (each state plays three times, then it settles into a slow idle).
  When idle its eyes follow the cursor. Reduce Motion shows a still frame.
- Built-in pets: Tee, Bit and Mochi (original art from `tools/make_pets.py`). Custom pets are read from
  `~/.t3-mini/pets/<name>/` and `~/.codex/pets/<name>/` (`pet.json` + an 8×11 sprite atlas of 192×208 cells).

## Settings (menu bar)
- Mode: Pet or Mini (no pet, just the pill). Pet, Pet Size (80–224 pt), Visibility (Always visible, or On demand:
  shown with ⌃⌥P and hidden on an outside click), Launch at Login, Muted chats.
- ⌃⌥P: show T3 Mini and start typing; press it again to close the composer.

## Data
- Reads T3 Code's local state (`~/.t3/userdata/statev2.sqlite`, or `$T3CODE_HOME`) read-only, re-reading whenever T3
  writes and at least every 15 seconds. It never writes to T3's database.

## Not included
- Voice input, attachments, and approving / answering / stopping runs from the overlay (T3 has no API for that, so
  cards open the thread in T3 instead).
