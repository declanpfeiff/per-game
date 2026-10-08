# Cinematic Cutscene for Roblox

A 23-second, six-shot cutscene: the player steps onto a red pad, the screen
fades, and the camera takes over. It uses hard cuts and blends, crane, dolly
and orbit moves, handheld shake, auto-focus depth of field, per-shot color
grading, letterbox bars, typed subtitles, a facial pose, a walk into a dark
doorway and a closing title card. When it ends, everything goes back to how
it was.

| # | Shot | What happens |
| - | ---- | ------------ |
| 1 | Establishing | Fades in on a high, wide view that cranes down and around him. |
| 2 | Hero angle | Hard cut to a handheld view from floor level, with a stomp. |
| 3 | Close-up | Pushes in and zooms while the brows drop, eyes narrow, cheeks hollow and chin lifts. |
| 4 | Profile | The camera swings around the jawline. |
| 5 | Exit | Blends behind him as he walks into the doorway's shadow. |
| 6 | Title | High wide shot with "THE STREAK REMAINS UNBROKEN", then fades to black. |

## Get it running

**Option A: open the ready-made place.** Download
[`dist/CinematicCutscene.rbxl`](dist/CinematicCutscene.rbxl) and open it in
Roblox Studio. It has a baseplate, a spawn, dusk lighting with an atmosphere,
the set and all the scripts.

**Option B: add it to your own place.**

1. Open your place in Studio and open **View > Command Bar**.
2. Paste the whole of [`installer/InstallCutscene.lua`](installer/InstallCutscene.lua) and press **Enter**.

Then press **Play (F5)**, walk to the red pad and hold **E**. To skip, hold
**Space**, gamepad **A**, or the on-screen button for one second.

Running the installer again updates the three scripts. It keeps the set and
pad if they already exist, so any changes you made to them in Studio stay.

## What it adds

```
Workspace
├── CutsceneSet              floor, four lit pillars, a doorway with a black void, back wall
└── CutsceneTriggerPart      the red pad (the character's mark) with a ProximityPrompt
ReplicatedStorage
├── RemoteEvents
│   ├── PlayCutscene         server → client: play now
│   └── CutsceneFinished     client → server: done (frees the pad)
└── Modules
    └── CinematicDirector    plays a list of shots
ServerScriptService
└── CutsceneTriggerServer    starts the cutscene, one player at a time
StarterPlayer
└── StarterPlayerScripts
    └── CutsceneClient       the shot list and audio settings
```

The set is built around `(0, 0, -30)`, so it doesn't overlap the default
spawn. Change `ORIGIN` in the installer to move it.

## How it behaves

- **Hitting the mark.** Behind the opening fade, the character is moved onto
  the pad, facing the doorway. Every shot is framed relative to that spot, so
  the framing is the same whoever plays it and wherever the set is.
- **The player's game is put back.** During the cutscene, movement, the
  core GUI (chat, backpack, player list) and other proximity prompts are
  turned off. Afterwards the camera, controls, GUI, prompts, walk speed,
  face and neck are all restored. This also happens on a skip or if the
  character dies, and there's a fade from black on the way out.
- **First person.** The character stays visible even if the player was
  zoomed into first person.
- **Multiplayer.** One player at a time, since everyone would share the
  same mark. The prompt is hidden while the cutscene is playing. It comes
  back when the client reports it's finished, the player leaves, or
  `MaxDuration` passes.

## Customizing

**Pad attributes** (select `CutsceneTriggerPart` in Studio):

| Attribute      | Default | Effect |
| -------------- | ------- | ------ |
| `TouchTrigger` | `false` | Also start when a player steps on the pad. |
| `Cooldown`     | `3`     | Seconds after a player's cutscene ends before they can start it again. |
| `MaxDuration`  | `45`    | Seconds before the server frees the pad if the client never reports back. |

**Audio** (top of `CutsceneClient`): `MUSIC_ID` (empty by default),
`MUSIC_VOLUME` and `STINGER_ID`. Music fades in and out with the cutscene.

**Shots** are the table in `CutsceneClient`. Offsets are in studs from the
pad: `+X` is the character's right, `+Y` is up, `-Z` is the way they face.

| Field | Notes |
| ----- | ----- |
| `Duration` | Seconds. |
| `Transition`, `BlendTime` | `"Cut"` (default) or `"Blend"`. A blend moves the camera across while it stays aimed at the subject. |
| `Offset`, `EndOffset`, `Orbit` | Camera start and end position, and degrees to swing around the character. |
| `PositionPart` | Use a fixed part in the world instead of an offset. |
| `LookAtPart`, `LookAtOffset` | What to aim at. The default is the character's head. |
| `FOV`, `EndFOV` | Zoom across the shot. |
| `Roll`, `Shake`, `Ease` | Tilt in degrees, handheld shake from `0` to `1`, and the easing style of the move. |
| `Focus`, `FocusRadius` | Depth of field: `"Subject"` keeps the subject sharp, or give a distance in studs. |
| `Grade` | `Brightness`, `Contrast`, `Saturation`, `TintColor`. |
| `VignetteIntensity` | `0`–`1`. |
| `Subtitle`, `Title` | A typed subtitle in the bottom bar, or a big centered title. |
| `FacialState` | `HunterEyes`, `HollowCheeks`, `MewingPosture` (`0`–`1`) and `Duration`. |
| `SoundId`, `SoundVolume` | Played when the shot starts. |
| `WalkTo`, `WalkSpeed` | The character walks to this offset during the shot. |

`CinematicDirector.new(shots, options)` takes `TargetCharacter`, `Mark`,
`AllowSkip`, `HoldSkipDuration`, `FadeIn`, `FadeOut`, `MusicId`,
`MusicVolume` and `HideCoreGui`. `director:Play()` waits until the
cutscene ends, and `director:Stop()` ends it early.

## Known limits

- **Audio is yours to choose.** The build sandbox can't reach Roblox's
  asset servers, so no audio ID here has been verified. The stomp is a sound
  that ships with Roblox (`rbxasset://sounds/action_jump_land.mp3`), so it
  will play. The stinger (`rbxassetid://9114223179`) came with the original
  brief and is unverified, and there's no music by default.
- **Facial poses need an animatable (dynamic) head.** The chin lift also
  works on classic R15 heads (through the neck joint). On R6 the face part
  of shot 3 does nothing. `FaceControls` has no lid-tightener or cheek-suck
  pose, so the squint and hollow cheeks are approximations.
- **Not yet watched in Studio.** The look (vignette, grade strengths,
  lighting) hasn't been seen on a real screen. The framing was checked by
  the tests below, not by eye.

## 1969 Mustang model

[`models/Mustang1969`](models/Mustang1969) has a 1969 Mustang SportsRoof
(blue, white stripes) to import with Studio's 3D Importer, plus a Command Bar
script that paints and assembles it. The README there has the steps.

## Development

The scripts live in `src/`, and the installer and place file are generated
from them. Tools are pinned in `rokit.toml` (Lune, Rojo, luau-lsp).

```sh
lune run tools/build            # regenerate installer/InstallCutscene.lua and dist/CinematicCutscene.rbxl
lune run tools/build --check    # fail if the committed installer is stale
lune run tests/run              # headless tests (pass a name fragment to filter)
```

`tests/engine.luau` is a small stand-in for the Roblox engine. Every
property read or write is checked against Roblox's reflection database,
including type and read-only status. Time is virtual, and characters can
walk and die. The tests:

- install into an empty place twice;
- play the whole cutscene on R15 (dynamic and classic heads) and R6;
- on every visible frame, check that the camera isn't inside the set or the
  character, nothing blocks the view of the face, and the face is inside the
  letterbox and more than 2 studs away;
- skip by key and by touch, check a short tap doesn't skip, and kill the
  character mid-shot;
- check first person, and that a re-trigger while playing is ignored;
- check the server's lock, cooldown, timeout, leaving and touch trigger;
- run the Mustang setup script on imports that are moved, turned around
  at meter scale, or lying on their side, and check the paint,
  orientation, length, grounding and welds.

CI runs the build check, a strict type-check (luau-lsp with Roblox types)
and the tests on every push.
