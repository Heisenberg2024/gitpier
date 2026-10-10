# GitPier brand

**GitPier** · Native Git Client for macOS  
*All Your Repositories. One Workspace.*

The application icon is a blue and cyan P with repository nodes and a pier on a rounded navy tile. `gitpier-icon-1024.png` is the canonical raster asset. Preserve the tile and its artwork; the canvas outside its rounded edge is transparent.

`Scripts/generate-branding.swift` derives the macOS AppIcon catalog and the SwiftPM application resource without resampling or overwriting the canonical image. `Scripts/build-app.sh` runs this generator before building, creates a fresh iconset, and binds a content-stamped `GitPier-<image hash>.icns` in Info.plist. Updating the icon filename and build number avoids reusing the previous package's icon identity.

`AppResources.applicationIcon` supplies the same image to the sidebar, Dock, and standard About panel. The About command explicitly passes this image instead of falling back to the system's named application-icon cache.

Do not substitute historical vector concepts or add text inside the icon. Use the formal name GitPier and the product description and slogan above in both documentation languages.
