# Handoff: breakr — break overlay, heads-up panel, settings

Made with Claude Design. Screens in `screens/` are 1:1 unless noted; the overlay is at 50%.

## Approved screens

| id | name | files |
|---|---|---|
| `overlay` | Full-break overlay | `overlay.png`, `overlay--complete.png` |
| `heads-up` | Heads-up panel | `heads-up.png` |
| `settings` | Settings window | `settings.png` |

## Design tokens

| name | value | usage |
|---|---|---|
| `ink` | `#08161f` | screen dim base, text on accent |
| `accent` | `#7fc8b7` | primary buttons, timer disc |
| `panel-border` | `rgba(127,200,183,.28)` | 1px border on every panel |
| `radius-panel` | `20px` | panels |

## Components

- `TimerDisc` — circular countdown with a draining ring
- `PrimaryButton` — accent fill, ink text
- SequenceStrip: four-column progress strip

## Screens

### overlay — Full-break overlay

Card 1000×660, centred. States: running, collapsed instruction, complete.

### heads-up — Heads-up panel

400px wide, top-centre, non-activating.

### settings — Settings window

760×700 single scrolling window.

## Deviations from the brief

- The brief asked for a light panel → the overlay panel is dark ink — reads better over a dimmed screen (agreed in stage 2)

## Copy

### overlay
- `Snooze 5 min`
- `Four movements done. Next break at {time}.`
- `Back to work`

### heads-up
- `Hip reset in a minute`

### settings
- `Launch at login`
