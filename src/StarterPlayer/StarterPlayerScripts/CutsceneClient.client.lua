--!strict
-- CutsceneClient
-- LocalScript in StarterPlayer > StarterPlayerScripts
--
-- Builds the shot list and plays it when the server fires PlayCutscene.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

local CinematicDirector = require(ReplicatedStorage:WaitForChild("Modules"):WaitForChild("CinematicDirector"))
local playEvent = ReplicatedStorage:WaitForChild("RemoteEvents"):WaitForChild("PlayCutscene") :: RemoteEvent

local localPlayer = Players.LocalPlayer
local playing = false

playEvent.OnClientEvent:Connect(function()
	if playing then
		return
	end
	playing = true

	local ok, err = pcall(function()
		local character = localPlayer.Character or localPlayer.CharacterAdded:Wait()
		local head = character:WaitForChild("Head") :: BasePart
		local nodes = Workspace:WaitForChild("CutsceneNodes")

		local sequence: { CinematicDirector.TrackKeyframe } = {
			-- Shot 1: Wide Environmental Entrance
			{
				PositionPart = nodes:WaitForChild("CamNode1") :: BasePart,
				LookAtPart = head,
				Duration = 3.5,
				FOV = 60,
				Roll = 4,
				Subtitle = "He entered the room with unprecedented aura...",
				VignetteIntensity = 0.2,
				FocusDistance = 20,
			},

			-- Shot 2: Extreme Close-Up + Lock Jaw + Hunter Eyes + Hollow Cheeks + Screen Vignette Zoom
			{
				PositionPart = nodes:WaitForChild("CamNode2") :: BasePart,
				LookAtPart = head,
				Duration = 4.0,
				FOV = 35,
				Roll = -2,
				Subtitle = "Biting lower lip, clenching jaw, locking in.",
				VignetteIntensity = 0.8,
				FocusDistance = 4,
				FacialState = {
					HunterEyes = 1.0, -- Maximum brow drop & lower lid squint
					HollowCheeks = 0.9, -- Deep cheek suck
					MewingPosture = 1.0, -- Chin lift & jaw lock
					Duration = 1.2,
				},
				SoundId = "rbxassetid://9114223179",
			},

			-- Shot 3: Walking Away into the Shadows
			{
				PositionPart = nodes:WaitForChild("CamNode3") :: BasePart,
				LookAtPart = head,
				Duration = 3.0,
				FOV = 50,
				Roll = 0,
				Subtitle = "The streak remains unbroken.",
				VignetteIntensity = 0.3,
				CharacterMoveTarget = character.PrimaryPart and character.PrimaryPart.CFrame * CFrame.new(0, 0, -15),
			},
		}

		local director = CinematicDirector.new(sequence, {
			AllowSkip = true,
			HoldSkipDuration = 1.0,
			TargetCharacter = character,
		})

		director:Play() -- yields until the cutscene ends or is skipped
	end)

	playing = false
	if not ok then
		warn("Cutscene failed:", err)
	end
end)
