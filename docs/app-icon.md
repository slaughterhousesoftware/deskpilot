# Deskpilot app icon

The shared shipping source is `App/DeskpilotIcon.icon`, editable in Apple's Icon
Composer. It is used by both Deskpilot and Deskpilot Dashboard through
`App/project.yml`.

Selected colorway: **Sunset — warm desktop, violet frame, deep indigo tile**.

- Background: `#5B33C4` → `#191A5C`; darker indigo in dark appearance.
- Upper glass: gold `#FFB21F` → hot pink `#FF4E9B`.
- Lower glass: lilac `#A58BFF` → cyan `#86EEFF`, with a more opaque face and stronger edge so it reads clearly in dark appearance.
- Posts and feet: orange and coral through magenta to violet, preserving their 3D shading.

Both broad desktop faces use native Icon Composer glass. Rounded sides and
metal/shadow surfaces are rendered artwork. Four groups preserve correct
overlap while supporting regular, dark, tinted and clear appearances.

The `.icon` package is self-contained; the exploratory palette tools are not
required for normal builds. Xcode compiles it into `Assets.car` and
`DeskpilotIcon.icns`. Exploratory palette tools are not required for a normal build.
