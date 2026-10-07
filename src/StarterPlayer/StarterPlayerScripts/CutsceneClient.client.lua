--!strict
-- CutsceneClient
-- LocalScript in StarterPlayer > StarterPlayerScripts
--
-- Defines the shots and plays them when the server fires PlayCutscene.
-- Shots are framed relative to the trigger pad (the character's mark):
-- +X is the character's right, +Y is up from the pad, -Z is the way the
-- character faces (toward the doorway).

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

local CinematicDirector = require(ReplicatedStorage:WaitForChild("Modules"):WaitForChild("CinematicDirector"))
local remotes = ReplicatedStorage:WaitForChild("RemoteEvents")
local playEvent = remotes:WaitForChild("PlayCutscene") :: RemoteEvent
local finishedEvent = remotes:WaitForChild("CutsceneFinished") :: RemoteEvent

-- Audio. Leave an ID empty to skip it. The stinger ID came with the original
-- setup and hasn't been checked; swap in audio you have permission to use.
local MUSIC_ID = ""
local MUSIC_VOLUME = 0.5
local STINGER_ID = "rbxassetid://9114223179"
local STOMP_ID = "rbxasset://sounds/action_jump_land.mp3" -- ships with Roblox

local localPlayer = Players.LocalPlayer
local playing = false

local function buildShots(): { CinematicDirector.TrackKeyframe }
	return {
		-- 1. Establishing: high and wide in front, craning down and around.
		{
			Duration = 4.5,
			Offset = Vector3.new(-7, 9, -15),
			EndOffset = Vector3.new(-4.5, 6.5, -11.5),
			Orbit = 10,
			FOV = 50,
			EndFOV = 46,
			Roll = 3,
			Focus = "Subject",
			VignetteIntensity = 0.35,
			Grade = { Contrast = 0.1, Saturation = -0.2, TintColor = Color3.fromRGB(225, 235, 255) },
			Subtitle = "He entered the room with unprecedented aura...",
		},

		-- 2. Hard cut to a low hero angle from the floor, handheld.
		{
			Duration = 2.8,
			Offset = Vector3.new(2.2, 0.9, -5.5),
			EndOffset = Vector3.new(1.8, 1.2, -4.6),
			LookAtOffset = Vector3.new(0, 0.3, 0),
			FOV = 55,
			Roll = 3,
			Shake = 0.35,
			VignetteIntensity = 0.45,
			Grade = { Contrast = 0.2, Saturation = -0.1 },
			SoundId = STOMP_ID,
			SoundVolume = 0.7,
		},

		-- 3. Extreme close-up: push in and zoom while the face locks in.
		{
			Duration = 4.0,
			Offset = Vector3.new(0.25, 4.85, -3.4),
			EndOffset = Vector3.new(0.1, 4.8, -2.7),
			LookAtOffset = Vector3.new(0, 0.1, 0),
			FOV = 28,
			EndFOV = 22,
			Roll = -2,
			Shake = 0.12,
			Focus = "Subject",
			FocusRadius = 1,
			VignetteIntensity = 0.85,
			Grade = { Brightness = 0.02, Contrast = 0.3, Saturation = -0.15, TintColor = Color3.fromRGB(255, 236, 215) },
			Subtitle = "Biting lower lip, clenching jaw, locking in.",
			FacialState = {
				HunterEyes = 1.0, -- brow drop & squint
				HollowCheeks = 0.9, -- cheek suck
				MewingPosture = 1.0, -- chin lift & jaw lock
				Duration = 1.2,
			},
			SoundId = STINGER_ID,
		},

		-- 4. Profile: the camera swings around the jawline.
		{
			Duration = 3.2,
			Offset = Vector3.new(-3.2, 4.9, -0.9),
			EndOffset = Vector3.new(-3, 4.8, -0.5),
			Orbit = -18,
			FOV = 30,
			Shake = 0.1,
			Focus = "Subject",
			FocusRadius = 1.2,
			VignetteIntensity = 0.6,
			Grade = { Contrast = 0.25, Saturation = -0.25 },
			Subtitle = "Hunter eyes. Hollow cheeks. Zero hesitation.",
		},

		-- 5. Blend behind him as he walks into the doorway's shadow.
		{
			Duration = 4.5,
			Transition = "Blend",
			BlendTime = 1.0,
			Offset = Vector3.new(1.6, 2.2, 5.5),
			EndOffset = Vector3.new(1, 4.5, 9),
			FOV = 50,
			EndFOV = 44,
			Shake = 0.2,
			Focus = "Subject",
			VignetteIntensity = 0.45,
			Grade = { Brightness = -0.05, Contrast = 0.2, Saturation = -0.35, TintColor = Color3.fromRGB(220, 225, 255) },
			WalkTo = Vector3.new(0, 0, -19.6),
			WalkSpeed = 7,
		},

		-- 6. Title card over a high wide shot of the doorway.
		{
			Duration = 3.5,
			Offset = Vector3.new(0, 7, 16),
			EndOffset = Vector3.new(0, 8.5, 21),
			FOV = 40,
			VignetteIntensity = 0.7,
			Grade = { Brightness = -0.08, Contrast = 0.3, Saturation = -0.6 },
			Title = "THE STREAK REMAINS UNBROKEN",
		},
	}
end

playEvent.OnClientEvent:Connect(function()
	if playing then
		return
	end
	playing = true

	local ok, err = pcall(function()
		local character = localPlayer.Character or localPlayer.CharacterAdded:Wait()
		local pad = Workspace:WaitForChild("CutsceneTriggerPart") :: BasePart

		local director = CinematicDirector.new(buildShots(), {
			TargetCharacter = character,
			Mark = pad.CFrame * CFrame.new(0, pad.Size.Y / 2, 0),
			AllowSkip = true,
			HoldSkipDuration = 1.0,
			MusicId = MUSIC_ID,
			MusicVolume = MUSIC_VOLUME,
		})
		director:Play() -- yields until the cutscene ends or is skipped
	end)

	playing = false
	finishedEvent:FireServer()
	if not ok then
		warn("Cutscene failed:", err)
	end
end)
