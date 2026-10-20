# dmgbuild settings for Satsuma's disk image (used by make_dmg.sh).
# Defines passed with -D: app (Satsuma.app), background (multi-resolution TIFF), icon (volume .icns).
import os.path

app = defines["app"]  # noqa: F821 (provided by dmgbuild)

format = "UDZO"
compression_level = 9
filesystem = "HFS+"
files = [app]
symlinks = {"Applications": "/Applications"}
icon = defines["icon"]  # noqa: F821
background = defines["background"]  # noqa: F821

# 760×440 window (Finder on macOS 26 won't go much narrower than ~740 pt); icon centers match the slots drawn by dmg_background.swift.
window_rect = ((200, 120), (760, 440))
default_view = "icon-view"
show_status_bar = False
show_tab_view = False
show_toolbar = False
show_pathbar = False
show_sidebar = False
show_icon_preview = False
arrange_by = None
icon_size = 128
text_size = 13
icon_locations = {
    os.path.basename(app): (200, 210),
    "Applications": (560, 210),
}
