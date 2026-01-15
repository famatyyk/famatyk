GIFT OF LIFE - ADDONS
===================

Goal
----
Everything NEW goes into gift_of_life/addons/*.lua (NOT into gift_of_life.lua).

How it loads
------------
gift_of_life/init.lua loads:
  1) core (gift_of_life.lua)
  2) addon manager (gift_of_life/addons/addons.lua)
  3) enabled addons from gift_of_life/config.lua -> addons table

Config
------
Edit: gift_of_life/config.lua

Enable an addon:
  addonsEnabled = true
  addons = {
    _order = {"my_addon"},
    my_addon = { enabled = true, file = "gift_of_life/addons/my_addon.lua" },
  }

Addon contract
--------------
Each addon file must RETURN a table.
Optional functions:
  init(entry, centralCfg)
  shutdown()

Reload safety
-------------
When you re-run dofile("gift_of_life/init.lua"), init.lua will call:
  GoLAddons.shutdownAll()
  GiftOfLife.shutdown()
Then load core again and load enabled addons again.
