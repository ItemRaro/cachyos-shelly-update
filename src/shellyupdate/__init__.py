"""cachyos-shelly-update: an arch-update style updater on top of Shelly and AppMan.

Modules:
    core     paths, sources, state files and texts shared by the CLI and the tray
    sources  the update checks, one per source
    cli      the command line updater (standard library only)
    tray     the tray icon (PyQt6, run from the installer's virtualenv)
"""
