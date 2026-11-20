---
name: davinci-resolve-color-grading
description: Stabilize and color-grade drone/FPV footage in DaVinci Resolve — Gyroflow stabilization, D-Log M normalization (LUT or CST), then a 4-level node-based grade (light, color hierarchy, toning, color compression). Use when asked to grade, color, stabilize, or build a look for clips in DaVinci Resolve.
license: MIT
---

# DaVinci Resolve Color Grading (drone-first)

A node-based grading workflow for DaVinci Resolve, tuned for DJI drone footage (Avata 2, Neo, Mini/Air series shot in D-Log M) but usable for any log footage.

Method credit: the four-level grading structure follows KC ian, "The Highest Level of Color Grading: No LUTs, No Plugins" (https://www.youtube.com/watch?v=53gcbJPP5eA). Gyroflow stabilization and the DJI LUT fast path are additions for drone footage.

## 0. Working principles

- Grade **one hero clip** first, show before/after, get approval, then propagate to the rest.
- Enter values by typing into fields (double-click, select all, type, Return) rather than dragging, so numbers are exact and repeatable.
- After each change, check the scopes, not just the viewer.
- Never delete media or overwrite a saved project version without asking. Save after each level.
- Before touching a clip that already has a grade, add a new grade version (Color > Grade Version > Add) so the original can be restored.
- Ask the user only for creative choices (look direction, how stylized). Check everything technical on screen yourself.

Useful macOS shortcuts on the Color page: Shift+6 Color page · Opt+S add serial node · Shift+S add serial node before current · Opt+L layer mixer · Opt+P parallel node · Cmd+D toggle node · Shift+D bypass whole grade · Cmd+Opt+G grab still. (Windows/Linux: replace Cmd with Ctrl, Opt with Alt.)

UI notes:
- Node context submenus (Gamma, Color Space, LUT) can be finicky to open by hover — click the parent item.
- Gain/Lift/Gamma numeric fields under each wheel are ordered Y, R, G, B.
- Avoid "Cleanup Node Graph" in recent versions; it can stack nodes on top of each other (Cmd+Z undoes only the layout).
- Color > Nodes > Add Outside Node is more reliable from the menu bar than via shortcut.

## 1. Intake

Check on screen first: Resolve version, Studio or free (Help > About), timeline color settings, clip codec/resolution.

Ask the user briefly:
- Which clips / timeline to grade.
- Look direction: natural/clean, or stylized (film-like, teal/orange, moody).
- Fast path (LUT) or full path (CST)? Default: CST path if Resolve lists DJI D-Log M in Color Space Transform, otherwise LUT path.

Drone assumptions: 10-bit D-Log M, in-camera stabilization (RockSteady/HorizonSteady) **off** — required for Gyroflow. If a clip was shot in Normal color or with in-camera stabilization on, skip Gyroflow and treat it as Rec.709.

## 2. Project setup

- Project Settings > Color Management: color science **DaVinci YRGB**.
  - CST path: timeline **DaVinci Wide Gamut / DaVinci Intermediate**, output **Rec.709 Gamma 2.4**.
  - LUT path: timeline and output **Rec.709 Gamma 2.4**.
- DJI LUT: download the official D-Log M to Rec.709 LUT for your drone from DJI, put the .cube in Resolve's LUT folder (Project Settings > Color Management > Open LUT Folder), then click **Update Lists**.
- Scopes (Workspace > Video Scopes): Waveform/Parade + Vectorscope. For luminance work set the waveform to Data Levels with Colorize off.
- Timeline aspect: most FPV drones shoot 4:3. For 16:9 delivery, set clip Retime and Scaling > Scaling to **Fill** (crops top/bottom) or keep **Fit** (pillarboxed).

## 3. Node tree

Build once on the hero clip, label every node, then save as a PowerGrade.

```
01 GYROFLOW          stabilize (spatial ops first)
02 PRE-LUT LIFT      LUT path only: lift shadows before the LUT clips them
03 NORMALIZE IN      CST D-Log M → DWG/DI  |  LUT path: DJI LUT
04 NR                Studio only, light temporal NR
05 LIGHT REBALANCE   gradient window, gamma luma             L1
06 EXPOSURE          HDR wheels / primaries luma             L1
07 WB                node gamma Linear, Gain wheel            L1
08 CONTRAST          Custom curves Y, pivot at middle gray    L1
09 SHAPE             subject lift + outside-node surround     L1
10 RGB MIXER         color compression                        L4
11 TONE GAMMA        Color wheels                             L3
12 TONE LOG          Log wheels                               L3
13 HUE v SAT         or Color Slice                           L2
14 LUM v SAT         "hero zone"                              L2
15 CLEANUP           qualifier fix, optional                  L2
16 SOFT CLIP                                                  L3
17 NORMALIZE OUT     CST DWG/DI → Rec.709 (CST path only)
18 TEXTURE           Studio: glow / halation / grain
```
Order: normalize → fix light → compress color → tone → hierarchy → polish. Levels are *learned* 1→4, but the nodes sit in the order above. Skip nodes the footage doesn't need.

## 4. Gyroflow (node 01)

- First check whether it's already applied (Edit page > Inspector > Effects; clips with effects show an `fx` badge). If Status reads OK, leave it.
- Otherwise drag Gyroflow (Effects > OpenFX) onto node 01. If it isn't installed, tell the user (free OFX plugin from gyroflow.xyz) and continue without it only if they agree.
- Click **Load for current file**. If the free version of Resolve can't resolve the path, use **Browse** and pick the source MP4. Status should read OK (DJI MP4s embed gyro data).
- Starting values: Smoothness 50 (70 for cinematic, lower for punchy FPV), Lens correction 100, Zoom limit ~130.
- **Horizon lock 100** if the user wants level horizons (removes FPV roll; crops in slightly).
- Apply on source-timed clips, before any retime.
- Playback gets slow: Playback > Render Cache > Smart, or cache node 01.

## 5. Normalize

**CST path:** Color Space Transform. Input DJI D-Gamut / DJI D-Log M → Output DaVinci Wide Gamut / DaVinci Intermediate, no tone/gamut mapping. Node 17: DWG/DI → Rec.709 / Gamma 2.4, tone mapping DaVinci, gamut mapping Saturation Compression, Apply Forward OOTF on. Middle gray = **0.336**.

**LUT path (fast):** right-click the node > LUT > DJI > D-Log M to Rec.709. Everything after grades in Rec.709. Middle gray = **0.435**.

**Important on the LUT path:** the DJI LUT crushes deep shadows to black and can clip highlights. Lifting shadows *after* the LUT only produces flat gray. Put a node **before** the LUT (Shift+S) and adjust there:
- Shadows/forest in shade: Lift Y +0.02, Gamma Y +0.05 to +0.11.
- Bright skies or sun-facing shots: Gain Y down to 0.90–0.96.

LUT path + Level 1 alone is often enough for a clean natural look.

## 6. Level 1 — Fix the light (luminance only)

Goal: highlights, mids, shadows in the right zones; nothing clipped, nothing crushed. Don't touch saturation yet.

1. **Exposure.** CST path: HDR wheels in DWG — lower Light/Highlight, lift Shadow slightly. Rec.709 path: Primaries Y-only Lift/Gamma/Gain.
2. **White balance.** Right-click node > Gamma > Linear. Neutralize with small Gain R/B moves (±0.02). Neutralize on a white roof, road, rock, cloud or concrete — not grass or sky. Keep golden-hour warmth by neutralizing only partly.
3. **Middle-gray pivot.** 0.336 (DWG/DI) or 0.435 (Rec.709). Pin a curve point there.
4. **Contrast.** Custom Curves, Y channel only (unlink YRGB). Highlights down, shadows up, shaped around the pivot. Use waveform guide lines as clip/crush guards.
5. **Light rebalance** (before exposure). Gradient window over the over-bright side (bright sky, sun-lit slope); lower gamma luma inside only.
6. **Light shaping.** Very soft circle window (softness 15–20) on the subject, gamma luma +0.03; Color > Nodes > Add Outside Node for the surround, gamma luma −0.03. Tracking often fails on fast forward FPV flight — if the subject stays in roughly the same area, use a static soft window and check it at a few points in the clip.

Check: waveform inside the guides, image has depth, subject reads first.

## 7. Level 2 — Color hierarchy (organize, don't add)

The vectorscope should tighten; nothing except the subject should jump out.

- **Hue vs Sat:** tame neon greens (forest/fields) and electric cyan in water/sky; balance competing reds/yellows.
- **Color Slice** (more filmic alternative): lower saturation + density on distracting hues, small boost on the hero color.
- **Lum vs Sat — "hero zone":** pull saturation down in shadows, gently in highlights; midtones carry the color. Removes the flat, plastic digital look.
- **Cleanup (optional):** qualifier on a layer node to remove a cast from one surface.

For bright, sunlit plateau/grassland shots, reducing overall saturation to ~44–47 keeps orange grass and blue sky from looking neon.

## 8. Level 3 — Toning

Turn Level 2 nodes off while toning, back on after.

- **Color Wheels:** vectorscope Mid, Luma Mix 0, gamma nudged slightly warm.
- **Log Wheels:** shadows slightly teal (vectorscope Low), highlights slightly warm (vectorscope High). Keep highlight tint very light on skies or they go green-yellow.
- **Soft Clip:** set Low, then Low Soft to compress shadows; generous High Soft for smooth highlight roll-off on bright skies and sun glare.

## 9. Level 4 — Color compression (RGB Mixer)

Small moves; watch the vectorscope (and skin, if any people).

1. Green output: Preserve Luminance on, increase **Blue in Green** — blues/greens move to cyan, reds/yellows to orange. More = more stylized.
2. If warm tones go too red, add a little **Red in Green**.
3. Blue output: increase Green, reduce Red slightly.
4. Revisit Levels 3 and 2 on top of this new base.

Landscapes: foliage should land olive/teal-green, not neon; sky should stay believable blue.

## 10. Polish (Studio)

- Light temporal NR right after normalize (drone shadows get noisy).
- After the look: optional glow, halation, slight softening (drone footage is often over-sharp), and **film grain last** (also hides 10-bit sky banding).

## 11. Editing for a cinematic cut (optional)

If asked to cut the footage down:
- Scrub every ~2 s and drop: very dark stretches, flying straight into the sun, tilted/banking horizons, low blurry ground skims, sky-only frames, repetitive passes, landings.
- Keep a clear arc: reveal → hero subject (e.g. waterfall) → wide landscape → closing shot.
- Razor (Cmd+B), delete, then Edit > Delete Gaps. Add short cross-dissolves (Cmd+T); joins without enough handle frames can stay hard cuts.
- Check the finished cut at frame intervals for horizon tilt; turn on Gyroflow horizon lock for any shot that still rolls.

## 12. Reuse

- Grab a still and save it into a PowerGrade album (e.g. "Drone Base – LUT"). Next time, apply it and re-tune only Level 1 per clip.
- Grade the hero clip, then copy to others (middle-click). Shared nodes keep Levels 2–4 consistent.

## 13. Deliver

- **YouTube 4K:** MP4, H.264 (or H.265), 3840×2160 at timeline frame rate, Restrict bitrate ~80 Mbps for 4K60 (~45 Mbps for 4K30). Rec.709 Gamma 2.4.
- **Master:** QuickTime DNxHR HQX 10-bit or ProRes 422 HQ.
- Check one export on a phone before batch rendering. Gyroflow clips render slowly.

## Troubleshooting

- **Crushed black shadows after the LUT:** lift in a node *before* the LUT (Section 5).
- **Gyroflow wobble/jello:** raise smoothness; check lens profile; confirm in-camera stabilization was off.
- **Black borders after Gyroflow:** raise zoom limit / adaptive zoom.
- **Washed-out image after normalize:** wrong input (Normal-color clip treated as D-Log M, or vice versa).
- **Curve shifts exposure:** pivot moved; re-pin at 0.336 / 0.435.
- **Sky banding:** gentler curves, add grain, avoid heavy Hue vs Sat on blues.
- **Skin odd after RGB Mixer:** back off Blue-in-Green, add Red-in-Green.
