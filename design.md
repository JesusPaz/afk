# AFK — native interface

<!-- Hallmark · genre: modern-minimal · structure: native workbench · pre-emit critique: P5 H4 E4 S5 R5 V4 -->

Implement the approved AFK direction: a quiet terminal workbench, native Apple navigation and system typography. The terminal is the main surface. No decorative dashboard or simulated window chrome.

## Shared system

Semantic Apple surfaces and text adapt to light/dark and accessibility settings. Blue is the action accent; green means connected, amber means observing, red means an error or destructive action. Every status has text. Terminal canvas uses the approved dark background (#151719) and foreground (#ECEFF1), independent of window chrome. Colors live in `AFKStyle.swift`.

System UI type, system monospace for terminal and codes. On Mac, prefer locally installed Meslo Nerd Font Mono for shell prompt glyphs, with system monospace fallback; do not download or bundle a font implicitly. Spacing: 4/8/12/16/24/32 pt. Native focus/hover/pressed/disabled states and sheets. No custom animation. iPhone targets at least 44 pt. Forms scroll with Dynamic Type and the keyboard.

## Mac

Sessions in a native sidebar. Explicit **Vincular iPhone** text in the toolbar and in Dispositivos. Each session has a distinct display name and a meaningful control/process subtitle. A compact control strip sits directly above a continuous terminal surface. When observing a narrow remote grid, center it in a restrained rounded panel with a “Vista compartida” caption, 16 pt side insets and 24 pt top margin. Keep it top-aligned; do not simulate device buttons or stretch terminal cells. Local control returns to the full workbench surface. Session termination lives in a labelled menu with confirmation.

Pairing explains three steps and presents selectable/copyable code, password, server and actual expiry. Errors stay in the sheet; retry is visible. Devices includes pairing in its empty state and one pause/resume action that reflects the actual connection.

## iPhone

Native list of sessions grouped under the linked Mac. Clear connection and host availability states. Pairing leads with code/password, with server configuration secondary. Terminal control copy distinguishes observing, writing, ended and disconnected. Terminal can scroll horizontally; app chrome must fit. Auxiliary keys stay reachable above the system keyboard.

## Boundaries

The controller determines the shared PTY geometry. Presentation changes must preserve the authoritative rows and columns, encryption boundaries and session persistence. Keep POC/trust details in pairing and connection settings, not permanently across the workspace.
