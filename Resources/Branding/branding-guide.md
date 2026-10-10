# GitPier brand

**GitPier** · Native Git Client for macOS  
*All Your Repositories. One Workspace.*

The application icon is a blue and cyan P with repository nodes and a pier on a rounded navy tile. `gitpier-icon-1024.png` is the canonical raster asset. Preserve the tile and its artwork; the canvas outside its rounded edge is transparent.

`Scripts/generate-branding.swift` derives the macOS AppIcon catalog and the SwiftPM application resource from this image. `Scripts/build-app.sh` converts the catalog to `GitPier.icns` and binds it in Info.plist. The same artwork appears in the application sidebar and Dock.

Do not substitute historical vector concepts or add text inside the icon. Use the formal name GitPier and the product description and slogan above in both documentation languages.
