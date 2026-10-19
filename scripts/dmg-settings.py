# dmgbuild settings for the drag-to-Applications installer window.
# Used by scripts/build-app.sh: dmgbuild -s scripts/dmg-settings.py -D app=... "Prime Cue Recorder" out.dmg
import os.path

app = defines["app"]
format = "UDZO"
files = [app]
symlinks = {"Applications": "/Applications"}
icon = "art/AppIcon.icns"
background = "art/dmg-background.png"
window_rect = ((200, 200), (640, 400))
icon_size = 112
text_size = 13
show_status_bar = show_tab_view = show_toolbar = show_pathbar = show_sidebar = False
icon_locations = {os.path.basename(app): (180, 210), "Applications": (460, 210)}
