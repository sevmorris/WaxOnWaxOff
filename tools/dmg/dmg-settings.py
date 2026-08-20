# dmgbuild settings for the WaxOn/WaxOff installer window.
#
# Used instead of styling a mounted image with AppleScript: dmgbuild writes the
# .DS_Store directly, so a release needs no Finder, no GUI session and no
# automation permission, and produces the same bytes every run.
#
#   dmgbuild -s tools/dmg/dmg-settings.py \
#            -D app=<path/to/App.app> -D background=<path/to/bg.png> \
#            "Install WaxOnWaxOff" out.dmg
import os.path

app = defines.get("app")
background = defines.get("background")
app_name = os.path.basename(app)

# Keep these three in sync with tools/dmg/make-background.py, which draws the
# arrow between exactly these two icon centres.
WINDOW = ((240, 180), (540, 380))
APP_XY = (150, 150)
APPS_XY = (390, 150)

format = "UDZO"
compression_level = 9
files = [app]
symlinks = {"Applications": "/Applications"}
icon_locations = {app_name: APP_XY, "Applications": APPS_XY}

window_rect = WINDOW
default_view = "icon-view"
icon_size = 128
text_size = 13
arrange_by = None
grid_offset = (0, 0)
label_pos = "bottom"

# Chrome off, so the background art is the whole window.
show_status_bar = False
show_tab_view = False
show_toolbar = False
show_pathbar = False
show_sidebar = False
