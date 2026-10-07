--!strict
-- CutsceneTriggerServer
-- Script in ServerScriptService
--
-- Tells a player's client to play the cutscene when they use the trigger's
-- ProximityPrompt, or (if the trigger part's TouchTrigger attribute is true)
-- when they step on it.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

local playEvent = ReplicatedStorage:WaitForChild("RemoteEvents"):WaitForChild("PlayCutscene") :: RemoteEvent
local triggerPart = Workspace:WaitForChild("CutsceneTriggerPart") :: BasePart
local prompt = triggerPart:WaitForChild("ProximityPrompt") :: ProximityPrompt

local DEFAULT_COOLDOWN = 3

-- Camera nodes stay visible in Studio for editing, but would float in the
-- middle of other shots in-game.
for _, node in Workspace:WaitForChild("CutsceneNodes"):GetChildren() do
	if node:IsA("BasePart") then
		node.Transparency = 1
	end
end

-- Touched fires many times per step while a character walks on the part,
-- so every trigger goes through a per-player cooldown.
local lastFired: { [Player]: number } = {}

local function fireFor(player: Player)
	local attribute = triggerPart:GetAttribute("Cooldown")
	local cooldown = if type(attribute) == "number" then attribute else DEFAULT_COOLDOWN

	local now = os.clock()
	local last = lastFired[player]
	if last and now - last < cooldown then
		return
	end
	lastFired[player] = now
	playEvent:FireClient(player)
end

prompt.Triggered:Connect(fireFor)

triggerPart.Touched:Connect(function(otherPart: BasePart)
	if triggerPart:GetAttribute("TouchTrigger") ~= true then
		return
	end
	local character = otherPart.Parent
	local player = character and Players:GetPlayerFromCharacter(character)
	if player then
		fireFor(player)
	end
end)

Players.PlayerRemoving:Connect(function(player: Player)
	lastFired[player] = nil
end)
