--!strict
-- CutsceneTriggerServer
-- Script in ServerScriptService
--
-- Starts the cutscene for a player who uses the trigger's ProximityPrompt, or
-- (if the pad's TouchTrigger attribute is true) steps on the pad. One player
-- at a time: the cutscene moves them onto the pad, so a second player would
-- share the mark. The prompt is hidden until the client reports it finished,
-- the player leaves, or MaxDuration passes.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

local remotes = ReplicatedStorage:WaitForChild("RemoteEvents")
local playEvent = remotes:WaitForChild("PlayCutscene") :: RemoteEvent
local finishedEvent = remotes:WaitForChild("CutsceneFinished") :: RemoteEvent
local triggerPart = Workspace:WaitForChild("CutsceneTriggerPart") :: BasePart
local prompt = triggerPart:WaitForChild("ProximityPrompt") :: ProximityPrompt

local DEFAULT_COOLDOWN = 3
local DEFAULT_MAX_DURATION = 45

local function numberAttribute(name: string, default: number): number
	local value = triggerPart:GetAttribute(name)
	return if type(value) == "number" then value else default
end

local activePlayer: Player? = nil
local activeRun = 0
-- Touched fires many times per step while a character walks on the pad,
-- so triggers also go through a per-player cooldown, counted from when the
-- player's last cutscene ended.
local lastFinished: { [Player]: number } = {}

local function release(player: Player)
	if activePlayer ~= player then
		return
	end
	activePlayer = nil
	lastFinished[player] = os.clock()
	prompt.Enabled = true
end

local function begin(player: Player)
	if activePlayer then
		return
	end
	local last = lastFinished[player]
	if last and os.clock() - last < numberAttribute("Cooldown", DEFAULT_COOLDOWN) then
		return
	end

	activePlayer = player
	activeRun += 1
	local run = activeRun
	prompt.Enabled = false
	playEvent:FireClient(player)

	-- Safety net in case the client never reports back.
	task.delay(numberAttribute("MaxDuration", DEFAULT_MAX_DURATION), function()
		if activeRun == run then
			release(player)
		end
	end)
end

prompt.Triggered:Connect(begin)

triggerPart.Touched:Connect(function(otherPart: BasePart)
	if triggerPart:GetAttribute("TouchTrigger") ~= true then
		return
	end
	local character = otherPart.Parent
	local player = character and Players:GetPlayerFromCharacter(character)
	if player then
		begin(player)
	end
end)

finishedEvent.OnServerEvent:Connect(release)

Players.PlayerRemoving:Connect(function(player: Player)
	release(player)
	lastFinished[player] = nil
end)
