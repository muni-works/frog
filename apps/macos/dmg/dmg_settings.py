# dmgbuild settings for Frog.dmg (release.sh):
#   dmgbuild -s dmg_settings.py -D app=path/to/Frog.app -D background=dmg/background.tiff Frog path/to/Frog.dmg
# dmgbuild writes the Finder layout (.DS_Store) itself; create-dmg scripted Finder, which
# silently does nothing without Automation permission.
app = defines["app"]  # noqa: F821 (dmgbuild provides `defines`)

format = "UDZO"
files = [app]
symlinks = {"Applications": "/Applications"}
hide_extensions = ["Frog.app"]
# 1x + 2x in one file (render.sh)
background = defines["background"]  # noqa: F821

window_rect = ((200, 120), (540, 360))
default_view = "icon-view"
show_status_bar = False
show_tab_view = False
show_toolbar = False
show_pathbar = False
show_sidebar = False
icon_size = 128
text_size = 13
icon_locations = {"Frog.app": (140, 170), "Applications": (400, 170)}
