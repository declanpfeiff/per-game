# Cinematic Cutscene for Roblox

A three-shot camera cutscene with letterbox bars, typewriter subtitles, a
vignette, depth of field, facial poses and hold-to-skip. One Command Bar
paste builds the whole thing in a place.

## Install

1. Open a place in Roblox Studio (a blank Baseplate works).
2. Open **View > Command Bar**.
3. Paste the entire contents of [`installer/InstallCutscene.lua`](installer/InstallCutscene.lua) and press **Enter**.
4. Press **Play (F5)**, walk to the red neon pad and hold **E**.

To keep a copy, use **File > Save to File As…** and save it as an `.rbxl`.

You can run the installer again to update the scripts. It replaces the three
scripts but keeps any camera nodes or trigger pad that already exist, so
changes you made to them in Studio stay.

## What it creates

```
Workspace
├── CutsceneNodes            camera positions (visible in Studio, hidden in-game)
│   ├── CamNode1
│   ├── CamNode2
│   └── CamNode3
└── CutsceneTriggerPart      red pad with a ProximityPrompt
ReplicatedStorage
├── RemoteEvents
│   └── PlayCutscene         RemoteEvent
└── Modules
    └── CinematicDirector    ModuleScript: plays a TrackKeyframe sequence
ServerScriptService
└── CutsceneTriggerServer    Script: fires PlayCutscene for the triggering player
StarterPlayer
└── StarterPlayerScripts
    └── CutsceneClient       LocalScript: defines the shots and plays them
```

The set is built around `(0, 0, -30)` so the pad doesn't overlap the default
SpawnLocation. Change `ORIGIN` in the installer to move it.

## Configuration

**Trigger** (attributes on `CutsceneTriggerPart`):

| Attribute      | Default | Effect                                                   |
| -------------- | ------- | -------------------------------------------------------- |
| `TouchTrigger` | `false` | Also start the cutscene when a player steps on the pad.  |
| `Cooldown`     | `3`     | Seconds before the same player can trigger it again.     |

**Shots** are defined in `CutsceneClient`. Each entry is a `TrackKeyframe`:

| Field                 | Type        | Notes                                                        |
| --------------------- | ----------- | ------------------------------------------------------------ |
| `PositionPart`        | `BasePart`  | Where the camera sits. Required.                             |
| `LookAtPart`          | `BasePart?` | What the camera tracks, even while it moves.                 |
| `Duration`            | `number`    | Seconds. The camera blends into the shot over this time.     |
| `FOV`                 | `number?`   | Leave it out to keep the previous shot's FOV.                |
| `Roll`                | `number?`   | Degrees. Default `0`.                                        |
| `Subtitle`            | `string?`   | Typed out in the bottom letterbox bar.                       |
| `VignetteIntensity`   | `number?`   | `0`–`1`. Leave it out to keep the previous value.            |
| `FocusDistance`       | `number?`   | Studs. Turns on depth of field; leave it out for no blur.    |
| `FocusRadius`         | `number?`   | Studs kept sharp around `FocusDistance`. Defaults to it.     |
| `FacialState`         | table?      | `HunterEyes`, `HollowCheeks`, `MewingPosture` (`0`–`1`), `Duration`. |
| `SoundId`             | `string?`   | Played once when the shot starts.                            |
| `CharacterMoveTarget` | `CFrame?`   | The character walks here during the shot.                    |

`CinematicDirector.new(sequence, options)` takes `AllowSkip`,
`HoldSkipDuration` (seconds) and `TargetCharacter`. `director:Play()` blocks
until the cutscene ends or is skipped. Players skip by holding **Space**,
gamepad **A**, or the on-screen button.

### Notes

- `FacialState` drives `FaceControls`, so it only shows on avatars with
  dynamic (animatable) heads. Classic heads skip it.
  `FaceControls` has no lid-tightener or cheek-suck pose, so the squint and
  hollow cheeks are approximations.
- The `SoundId` in shot 2 (`rbxassetid://9114223179`) is a placeholder that
  hasn't been checked. Replace it with an audio asset you have access to.
- Player movement is disabled while the cutscene plays and comes back when
  it ends, is skipped, or the character dies.

## Development

The scripts live in `src/`. The installer is generated from
`installer/InstallCutscene.template.lua` with the sources inlined. After you
edit either one, rebuild it:

```sh
python3 tools/build_installer.py          # regenerate installer/InstallCutscene.lua
python3 tools/build_installer.py --check  # fail if the committed installer is stale
```
