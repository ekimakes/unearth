# The window people see when they open Unearth.dmg. Run from the repository's root, as scripts/release.sh does:
#   dmgbuild -s scripts/dmg/settings.py -D app=<path to Unearth.app> Unearth <out.dmg>
# The picture comes from make-background.swift. Its middle is the middle of this window, and the arrow runs between
# the two icons, so the three have to move together.
app = defines["app"]

format = "UDZO"
files = [app]
symlinks = {"Applications": "/Applications"}
icon = app + "/Contents/Resources/AppIcon.icns"

background = "scripts/dmg/background.png"
window_rect = ((240, 160), (660, 420))
default_view = "icon-view"
show_status_bar = False
show_tab_view = False
show_toolbar = False
show_pathbar = False
show_sidebar = False

icon_size = 128
text_size = 14
label_pos = "bottom"
icon_locations = {"Unearth.app": (170, 165), "Applications": (490, 165)}
