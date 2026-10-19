# Notch spike — owner checklist

Before you start:
- Start with the lid closed and the LG only (V steps), then open the lid (C steps). C11/C12 need the LG.
- Keep Agent Sessions running with its menu bar item, but close its Quota Meter window.

Run in Terminal: `cd tools/notch-spike && swift run notch-spike`

Type commands into that Terminal window (Return after each):
- `mark C3`: marks the start of a step in the log. Do this before every step.
- `wings` / `minimal`: style.
- `quit`.

Clicking a black wing opens the spike menu with the same controls, the way the real strip will open the old menu bar item's menu. There is no "NS" icon any more.

For each step: type `mark <ID>`, click into the app the step names (Safari if none), do the action, then write one line under the step below.

Log: `~/Library/Logs/AgentSessions-NotchSpike/spike.log`.

| ID | Action | Pass looks like |
|---|---|---|
| V1 | Lid closed, LG only: look at the top centre of the LG | One black pill (wing · small sensor · wing) centred in the menu bar; app menus and status items untouched |
| V2 | Hover the pill, then move into the drop panel and out | Panel opens under the pill after ~⅓ s, closes ~0.7 s after leaving |
| V3 | With Safari frontmost, click the left wing | The spike menu opens under the wing; Safari stays frontmost |
| V5 | Open a long app menu (Xcode → View) on the LG | Menu draws above the pill; note whether the menu titles reach the pill |
| V6 | Open the lid | Pill moves from the LG centre to the MacBook notch |
| C1 | Launch with the built-in display only | Two black wings flush with the notch; nothing else covered |
| C2 | Repeat C1 at Default and "More Space" scaling (quit and relaunch after each change) | Wings stay flush with the notch at both |
| C3 | Hover left wing → notch → drop panel → back out to a third-party menu bar item. Then click a wing and leave the panel while its menu is open | Opens after ~⅓ s, no flicker crossing regions, closes ~0.7 s after leaving, menu opens normally |
| C4 | With Safari frontmost, click "Spike action" in the drop panel | Button works on the first click; Safari stays frontmost |
| C4b | With Safari frontmost, right-click the left wing, then right-click inside the open drop panel | Safari stays frontmost; no menu appears |
| C5 | Open a long app menu (Xcode → View) and a system menu (Apple menu) while wings show | Menus open and draw above the wings |
| C6 | Click status items right of the right wing, including Agent Sessions' item | All respond; nothing is blocked outside the wings |
| C8 | Type `minimal`; hover the notch | Hairlines only; menu bar items beside the notch clickable; hover over the notch still opens the panel |
| C9 | Type `wings`. Full-screen Safari; check the top strip; hover the notch | Wings visible in the black strip (or note that they are not) |
| C10 | Stage Manager on; Mission Control open | Wings stay put and are not part of window groups |
| C11 | Connect the external display; disconnect it | Wings return on the built-in display, flush with the notch |
| C12 | With the external display connected, close the lid; reopen it | Strip moves to the LG's top centre with the lid closed; back at the notch on reopen |
| C13 | Sleep and wake | Wings return after wake |
| C14 | Close and reopen the lid three times quickly | No duplicate wings |

## Notes

V1:
V2:
V3:
V5:
V6:

C1:
C2:
C3:
C4:
C4b:
C5:
C6:
C8:
C9:
C10:
C11:
C12:
C13:
C14:
