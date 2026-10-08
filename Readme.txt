I’ve added a full window and a minimap button (version 1.1). I couldn’t run it in a 1.12 client, so the layout is untested. Replace both files in Interface\AddOns\MassDisenchant\.

The window

Opening it: click the minimap button or type /md. Drag the window by its title area, and Escape closes it.
Quality selector: three buttons (Green, Blue, Epic) set the highest quality it will disenchant. The selected one stays highlighted, and picking Epic shows a warning.
Item list: it shows every eligible item in your bags, with its icon, quality-coloured name and a status label. It scrolls with the mouse wheel or scrollbar, and hovering an item shows its normal tooltip.
Protecting items: click an item to protect it. It turns dim and is labelled “Protected”. Click again to unprotect.
Start/Stop button: it starts the run and turns into Stop while running. It’s greyed out when nothing is eligible.
Progress and status: a purple progress bar shows the count. During a run, each row shows Queued, Working..., Done or Skipped. A line above the bar shows the current item or a result message such as “Finished: 12 disenchanted, 1 skipped”.
Refresh: it rescans the bags and clears the skipped list, which is useful after you level Enchanting. The list also updates by itself when your bags change.
Minimap button: left-click opens the window, and dragging moves it around the minimap. /md minimap hides or shows it.

What changed from before

/md now opens the window instead of starting a run. Use /md start and /md stop for macros.
The on-screen “DE” button is gone, replaced by the minimap button.
/md list no longer disturbs a running queue.