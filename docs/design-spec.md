# Onboard design spec

Dark, calm, premium (Raycast, Linear, Wispr Flow, Clicky). One accent: teal #2DD4BF. Background #0B0D0C. System font (SF Pro). Text opacities: primary 0.95, secondary 0.65, tertiary 0.40. Hairline white 0.08, strong 0.14.

| Element | Values |
|---|---|
| Command bar | 680 wide, 56 collapsed, up to 420 with results; radius 14; `.ultraThinMaterial` plus black 0.35; border white 0.08; shadow black 0.45 radius 30 y 12 |
| Bar type | Input 16 regular (we use 20 for readability on video), rows 14 medium, hints 12; row height 40, radius 8, icon 18 |
| Bar motion | Hotkey open: opacity over 0.08 s, no scale. Close 0.10 s easeOut. Height `.spring(response: 0.25, dampingFraction: 1.0)`. Rows fade+slide 6pt, no long stagger |
| Voice pill | 24pt above the Dock, centered. Idle 44x10, listening 120x32, thinking 72x32, speaking 120x32; capsule, black 0.85, border white 0.10 |
| Pill bars | 9 bars, 3 wide, 3 gap, radius 1.5, white. Height = 4 + pow(min(level*2.85,1), 0.76) * 16 * profile, profile [0.4,0.55,0.7,0.85,1,0.85,0.7,0.55,0.4]; `.linear(duration: 0.08)` |
| Pill morph | `.spring(response: 0.35, dampingFraction: 0.8)`; done: checkmark 0.6 s then shrink |
| Agent cursor | 18pt arrow, teal #2DD4BF, 1pt white stroke 0.9, glow radius 8 at 0.6 |
| Cursor flight | Quadratic bezier arc; duration clamp(distance/1200, 0.28, 0.75) s (snappy); arc height min(0.2*distance, 80); scale peaks 1.15 mid flight; easeInOut. Idle: 2pt bob, 2.4 s |
| Click ripple | Ring 8 to 36pt, opacity 0.6 to 0, 0.35 s easeOut; cursor dips to 0.92 |
| Thought bubble | 12 medium white on teal 0.95 (dark text also fine), radius 8, padding 8x5, max width 260, offset (14, 18) from the cursor tip; pop from 0.5 with `.spring(response: 0.4, dampingFraction: 0.6)`; text crossfades 0.15 s |
| X-ray outline | 1.5pt teal stroke, radius 4, fill teal 0.08, glow radius 6 at 0.4; appear from scale 1.04 with `.spring(response: 0.3, dampingFraction: 0.85)`; 12 ms stagger, cap 60 elements; whole pass under 0.9 s then fade 0.25 s |
| Target glow | The element about to be clicked: 2pt teal stroke + fill 0.14, pulses once (0.25 s) before the click |
| Scan shimmer | 120pt gradient band, white 0.12, sweeps the window once in 0.7 s |
| Spotlight dim | Black 0.35, 0.2 s easeOut (only behind the approval card) |
| Approval card | 360 wide, radius 16, padding 16, title 14 semibold, body 13 at 0.7; buttons 30 high radius 8; in with `.spring(response: 0.35, dampingFraction: 0.85)` y +12 and opacity; Return allows, Escape declines |
| Step dots | 20pt circle with number 11 semibold where the agent clicked; done teal; 1pt connector white 0.15; pop in with the `pop` spring; fade out 2 s after the task ends |
| Reduce Motion | Replace flight, morphs and sweeps with 0.15 s opacity fades |

Rules: interactions 200 ms or less; enter from scale 0.9 or higher, never 0; ease-out for enter and exit; never animate keyboard-triggered open with scale; springs for anything interruptible.
