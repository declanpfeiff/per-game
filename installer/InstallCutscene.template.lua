-- Cinematic Cutscene installer (template)
--
-- tools/build_installer.py inlines each script source into the matching
-- placeholder string in SOURCES and writes installer/InstallCutscene.lua.
-- Edit this file or src/, then rebuild; don't edit the generated file by hand.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")
local StarterPlayer = game:GetService("StarterPlayer")
local Workspace = game:GetService("Workspace")

-- Where the set is built. Offset from the world origin so the trigger pad
-- does not overlap the default SpawnLocation.
local ORIGIN = Vector3.new(0, 0, -30)

local SOURCES = {
	CinematicDirector = "{{src/ReplicatedStorage/Modules/CinematicDirector.lua}}",
	CutsceneTriggerServer = "{{src/ServerScriptService/CutsceneTriggerServer.server.lua}}",
	CutsceneClient = "{{src/StarterPlayer/StarterPlayerScripts/CutsceneClient.client.lua}}",
}

local function ensure(parent: Instance, className: string, name: string): (Instance, boolean)
	local existing = parent:FindFirstChild(name)
	if existing and existing:IsA(className) then
		return existing, false
	end
	local instance = Instance.new(className)
	instance.Name = name
	instance.Parent = parent
	return instance, true
end

local function replaceScript(parent: Instance, className: string, name: string, source: string)
	local existing = parent:FindFirstChild(name)
	if existing then
		existing:Destroy()
	end
	local newScript = Instance.new(className) :: any
	newScript.Name = name
	newScript.Source = source
	newScript.Parent = parent
end

-- 1. Camera nodes (kept if they already exist, so Studio edits survive a re-run)
local nodesFolder = ensure(Workspace, "Folder", "CutsceneNodes")
local nodeLayout = {
	{ Name = "CamNode1", Offset = Vector3.new(0, 12, 25), Color = Color3.fromRGB(255, 170, 0) },
	{ Name = "CamNode2", Offset = Vector3.new(0, 6, 8), Color = Color3.fromRGB(0, 255, 170) },
	{ Name = "CamNode3", Offset = Vector3.new(-10, 8, -15), Color = Color3.fromRGB(170, 0, 255) },
}
for _, layout in nodeLayout do
	local node, created = ensure(nodesFolder, "Part", layout.Name)
	if created then
		local part = node :: Part
		part.Size = Vector3.new(2, 2, 2)
		part.Position = ORIGIN + layout.Offset
		part.Anchored = true
		part.CanCollide = false
		part.CanTouch = false
		part.CanQuery = false
		part.CastShadow = false
		part.Transparency = 0.5
		part.Color = layout.Color
	end
end

-- 2. Trigger pad with ProximityPrompt
local trigger, triggerCreated = ensure(Workspace, "Part", "CutsceneTriggerPart")
if triggerCreated then
	local part = trigger :: Part
	part.Size = Vector3.new(4, 1, 4)
	part.Position = ORIGIN + Vector3.new(0, 0.5, 0)
	part.Anchored = true
	part.Color = Color3.fromRGB(255, 50, 50)
	part.Material = Enum.Material.Neon
	part:SetAttribute("TouchTrigger", false)
	part:SetAttribute("Cooldown", 3)
end

local prompt, promptCreated = ensure(trigger, "ProximityPrompt", "ProximityPrompt")
if promptCreated then
	local proximityPrompt = prompt :: ProximityPrompt
	proximityPrompt.ActionText = "Start Cutscene"
	proximityPrompt.ObjectText = "Cinematic Engine"
	proximityPrompt.HoldDuration = 0.5
	proximityPrompt.RequiresLineOfSight = false
end

-- 3. RemoteEvent
local remoteFolder = ensure(ReplicatedStorage, "Folder", "RemoteEvents")
ensure(remoteFolder, "RemoteEvent", "PlayCutscene")

-- 4. Scripts (always replaced, so a re-run picks up new code)
local modulesFolder = ensure(ReplicatedStorage, "Folder", "Modules")
replaceScript(modulesFolder, "ModuleScript", "CinematicDirector", SOURCES.CinematicDirector)
replaceScript(ServerScriptService, "Script", "CutsceneTriggerServer", SOURCES.CutsceneTriggerServer)
replaceScript(
	StarterPlayer:WaitForChild("StarterPlayerScripts"),
	"LocalScript",
	"CutsceneClient",
	SOURCES.CutsceneClient
)

print("✅ Cinematic cutscene installed. Press Play (F5), walk to the red pad and hold E.")
