on run argv
  set mountPath to item 1 of argv
  tell application "Finder"
    set mountedDisk to disk "GitPier"
    if POSIX path of (mountedDisk as alias) is not mountPath & "/" then error "A different GitPier disk is already mounted"
    tell mountedDisk
      open
      delay 0.5
      set current view of container window to icon view
      set toolbar visible of container window to false
      set statusbar visible of container window to false
      set bounds of container window to {160, 120, 880, 568}
      set theViewOptions to icon view options of container window
      set arrangement of theViewOptions to not arranged
      set icon size of theViewOptions to 104
      set text size of theViewOptions to 13
      set background picture of theViewOptions to file ".background:background.tiff"
      set position of item "GitPier.app" to {190, 196}
      set position of item "Applications" to {530, 196}
      set extension hidden of item "GitPier.app" to true
      update without registering applications
      close
      open
      delay 1
      if current view of container window is not icon view then error "Finder icon view was not saved"
      if position of item "GitPier.app" is not {190, 196} then error "App position was not saved"
      if position of item "Applications" is not {530, 196} then error "Applications position was not saved"
      set theViewOptions to icon view options of container window
      if icon size of theViewOptions is not 104 then error "Icon size was not saved"
      close
    end tell
  end tell
end run
