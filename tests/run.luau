--!nocheck
-- Headless tests for the installer, server and client scripts.
-- Run from the repository root:  lune run tests/run

local fs = require("@lune/fs")
local process = require("@lune/process")
local roblox = require("@lune/roblox")
local Engine = require("./engine")

local Vector3, Enum = roblox.Vector3, roblox.Enum
local ORIGIN = Vector3.new(0, 0, -30)
local DT = 1 / 60
local INSTALLER = fs.readFile("installer/InstallCutscene.lua")
local SOURCES = {
	CinematicDirector = fs.readFile("src/ReplicatedStorage/Modules/CinematicDirector.lua"),
	CutsceneTriggerServer = fs.readFile("src/ServerScriptService/CutsceneTriggerServer.server.lua"),
	CutsceneClient = fs.readFile("src/StarterPlayer/StarterPlayerScripts/CutsceneClient.client.lua"),
}

local tests = {}
local function test(name: string, fn: () -> ())
	table.insert(tests, { name = name, fn = fn })
end

local function check(condition: any, message: string, ...)
	if not condition then
		error(message:format(...), 2)
	end
end

local function near(a: number, b: number, tolerance: number?): boolean
	return math.abs(a - b) <= (tolerance or 1e-3)
end

-- Runs the installer the way the Command Bar does (plugin security).
local function install(engine)
	engine.privileged = true
	engine:runScript(nil, INSTALLER)
	engine.privileged = false
	check(#engine.errors == 0, "installer failed:\n%s", table.concat(engine.errors, "\n"))
end

type Options = { rig: string?, dynamicHead: boolean?, firstPerson: boolean? }

-- An installed place with one player standing near the pad and both
-- scripts running.
local function boot(options: Options?)
	local opts = options or {}
	local engine = Engine.create()
	install(engine)

	local player, controls = engine:addPlayer("Hero", 1)
	engine:setLocalPlayer(player)
	local character, humanoid = engine:spawnCharacter(player, {
		rig = opts.rig,
		dynamicHead = opts.dynamicHead,
		position = ORIGIN + Vector3.new(3, 0, 4),
	})

	local workspace = engine:service("Workspace")
	local remotes = engine:service("ReplicatedStorage"):FindFirstChild("RemoteEvents")
	local pad = workspace:FindFirstChild("CutsceneTriggerPart")
	local ctx = {
		engine = engine,
		player = player,
		controls = controls,
		character = character,
		humanoid = humanoid,
		head = character:FindFirstChild("Head"),
		pad = pad,
		prompt = pad:FindFirstChild("ProximityPrompt"),
		playerGui = player:FindFirstChild("PlayerGui"),
		finished = 0,
	}
	remotes:FindFirstChild("CutsceneFinished").OnServerEvent:Connect(function()
		ctx.finished += 1
	end)

	if opts.firstPerson then
		-- What the default camera scripts do when zoomed into first person.
		engine.renderBindings.FakeTransparencyController = {
			name = "FakeTransparencyController",
			priority = Enum.RenderPriority.Camera.Value,
			fn = function()
				for _, part in character:GetDescendants() do
					if part:IsA("BasePart") or part:IsA("Decal") then
						part.LocalTransparencyModifier = 1
					end
				end
			end,
		}
	end

	engine:runScript(engine:service("ServerScriptService"):FindFirstChild("CutsceneTriggerServer"))
	engine:runScript(engine:service("StarterPlayer"):FindFirstChild("StarterPlayerScripts"):FindFirstChild("CutsceneClient"))
	engine:step(DT)
	return ctx
end

local function gui(ctx)
	return ctx.playerGui:FindFirstChild("CinematicDirectorGui")
end

local function trigger(ctx, player)
	ctx.prompt.Triggered:Fire(player or ctx.player)
end

-- Parts the camera must never be inside or look through.
local function solids(ctx)
	local list = {}
	local workspace = ctx.engine:service("Workspace")
	for _, part in workspace:FindFirstChild("CutsceneSet"):GetDescendants() do
		if part:IsA("BasePart") then
			table.insert(list, part)
		end
	end
	return list
end

-- Checks one rendered frame of the cutscene; returns a problem or nil.
local function frameProblem(ctx, solidParts): string?
	local screen = gui(ctx)
	if not screen or screen:FindFirstChild("Fade").BackgroundTransparency < 0.5 then
		return nil -- mostly black: nothing to frame
	end
	local camera = ctx.engine.camera
	local cframe = camera.CFrame
	local eye = cframe.Position
	local target = ctx.head.Position
	if (target - eye).Magnitude < 2 then
		return ("camera %.2f studs from the head"):format((target - eye).Magnitude)
	end
	for _, part in solidParts do
		if Engine.pointInPart(part, eye, 0.3) then
			return "camera inside " .. part.Name
		end
		if Engine.segmentHitsPart(part, eye, target) then
			return "view of the head blocked by " .. part.Name
		end
	end
	for _, part in ctx.character:GetDescendants() do
		if part:IsA("BasePart") and part ~= ctx.head and Engine.pointInPart(part, eye, 0.3) then
			return "camera inside the character's " .. part.Name
		end
	end
	local headInView = cframe:PointToObjectSpace(target)
	if headInView.Z >= 0 then
		return "head is behind the camera"
	end
	local tanV = math.tan(math.rad(camera.FieldOfView / 2))
	local tanH = tanV * 16 / 9
	local bar = screen:FindFirstChild("TopBar").Size.Y.Scale
	local x, y = headInView.X / -headInView.Z, headInView.Y / -headInView.Z
	if math.abs(x) > tanH * 0.9 or math.abs(y) > tanV * (1 - 2 * bar) then
		return ("head out of frame (x %.2f, y %.2f of the picture)"):format(x / tanH, y / tanV)
	end
	return nil
end

-- Plays until the client reports back, checking every frame.
local function playThrough(ctx, onFrame: ((number) -> ())?): number
	local engine = ctx.engine
	local solidParts = solids(ctx)
	local started = engine.clock
	local problems = {}
	trigger(ctx)
	while ctx.finished == 0 do
		engine:step(DT)
		local problem = frameProblem(ctx, solidParts)
		if problem then
			table.insert(problems, ("t=%.2fs %s"):format(engine.clock - started, problem))
		end
		if onFrame then
			onFrame(engine.clock - started)
		end
		check(engine.clock - started < 60, "cutscene never finished")
	end
	local elapsed = engine.clock - started
	engine:run(1, DT) -- let the fade back and cleanup finish
	check(#problems == 0, "%d framing problems, first: %s", #problems, problems[1] or "")
	return elapsed
end

local function assertRestored(ctx)
	local engine = ctx.engine
	local camera = engine.camera
	check(camera.CameraType == Enum.CameraType.Custom, "camera type not restored: %s", tostring(camera.CameraType))
	check(camera.CameraSubject == ctx.humanoid, "camera subject not restored")
	check(near(camera.FieldOfView, 70), "FOV not restored: %s", camera.FieldOfView)
	check(ctx.controls.enabled, "player controls still disabled")
	check(engine:service("ProximityPromptService").Enabled, "prompts still hidden")
	for coreGuiType, enabled in engine.coreGui do
		check(enabled, "core GUI %s still hidden", tostring(coreGuiType))
	end
	check(gui(ctx) == nil, "cutscene GUI left behind")
	check(#camera:GetChildren() == 0, "post effects left on the camera")
	check(#engine:service("SoundService"):GetChildren() == 0, "sounds left behind")
	check(near(ctx.humanoid.WalkSpeed, 16), "WalkSpeed not restored: %s", ctx.humanoid.WalkSpeed)
	check(next(engine.renderBindings) == nil or engine.renderBindings.FakeTransparencyController ~= nil
		and engine.renderBindings.CinematicDirectorCamera == nil, "render step still bound")
	local neck = ctx.head:FindFirstChild("Neck")
	if neck then
		check(neck.C0 == roblox.CFrame.new(0, 0.8, 0), "neck not restored: %s", tostring(neck.C0))
	end
	local face = ctx.head:FindFirstChildOfClass("FaceControls")
	if face then
		for _, property in { "LeftBrowLowerer", "RightEyeClosed", "FlatPucker", "LowerLipSuck", "ChinRaiser", "LipsTogether" } do
			check(near(face[property], 0), "face %s not restored: %s", property, face[property])
		end
	end
	check(ctx.prompt.Enabled, "server never re-enabled the prompt")
	check(#engine.warnings == 0, "warnings: %s", table.concat(engine.warnings, "; "))
end

-- Installer ---------------------------------------------------------------

test("installer builds the place and is safe to re-run", function()
	local engine = Engine.create()
	install(engine)
	local workspace = engine:service("Workspace")
	local set = workspace:FindFirstChild("CutsceneSet")
	check(set and #set:GetChildren() == 14, "set not built")
	local pad = workspace:FindFirstChild("CutsceneTriggerPart")
	check(pad.CFrame.Position == ORIGIN + Vector3.new(0, 0.4, 0), "pad in the wrong place")
	check(pad:GetAttribute("TouchTrigger") == false and pad:GetAttribute("Cooldown") == 3, "pad attributes")

	-- Simulate edits in Studio, then install again.
	local floor = set:FindFirstChild("Floor")
	floor.Color = roblox.Color3.new(1, 0, 0)
	local oldModule = engine:service("ReplicatedStorage"):FindFirstChild("Modules"):FindFirstChild("CinematicDirector")
	install(engine)
	check(workspace:FindFirstChild("CutsceneSet"):FindFirstChild("Floor").Color == roblox.Color3.new(1, 0, 0), "set edit lost")
	check(engine:isDestroyed(oldModule), "old module not replaced")

	local function count(parent, name)
		local n = 0
		for _, child in parent:GetChildren() do
			if child.Name == name then
				n += 1
			end
		end
		return n
	end
	check(count(workspace, "CutsceneSet") == 1 and count(workspace, "CutsceneTriggerPart") == 1, "set duplicated")
	check(#engine:service("ReplicatedStorage"):FindFirstChild("RemoteEvents"):GetChildren() == 2, "remotes duplicated")

	local scripts = {
		CinematicDirector = engine:service("ReplicatedStorage"):FindFirstChild("Modules"):FindFirstChild("CinematicDirector"),
		CutsceneTriggerServer = engine:service("ServerScriptService"):FindFirstChild("CutsceneTriggerServer"),
		CutsceneClient = engine:service("StarterPlayer"):FindFirstChild("StarterPlayerScripts"):FindFirstChild("CutsceneClient"),
	}
	check(scripts.CinematicDirector:IsA("ModuleScript"), "module class")
	check(scripts.CutsceneTriggerServer.ClassName == "Script", "server class")
	check(scripts.CutsceneClient.ClassName == "LocalScript", "client class")
	for name, script in scripts do
		check(count(script.Parent, name) == 1, "%s duplicated", name)
		check(script.Source == SOURCES[name], "%s source differs from src/", name)
	end
end)

-- Full playthroughs -----------------------------------------------------------

test("plays all six shots with clean framing (R15, animated head)", function()
	local ctx = boot({ dynamicHead = true })
	local face = ctx.head:FindFirstChildOfClass("FaceControls")
	local sawFace, sawTitle, sawWalk = false, false, false
	local elapsed = playThrough(ctx, function()
		if face.LeftBrowLowerer > 0.9 then
			sawFace = true
		end
		local screen = gui(ctx)
		if screen and screen:FindFirstChild("Title").TextTransparency < 0.1 then
			sawTitle = true
		end
		if ctx.humanoid.WalkSpeed == 7 then
			sawWalk = true
		end
		if screen and screen:FindFirstChild("TopBar").Visible then
			check(not ctx.controls.enabled, "controls enabled during the cutscene")
		end
	end)
	check(elapsed > 23 and elapsed < 24.5, "unexpected length %.2fs", elapsed)
	check(sawFace and sawTitle and sawWalk, "missing beats (face %s, title %s, walk %s)", tostring(sawFace), tostring(sawTitle), tostring(sawWalk))
	-- He ends up in the doorway.
	local root = ctx.humanoid.RootPart.Position
	check(math.abs(root.Z - (ORIGIN.Z - 19.6)) < 0.5 and math.abs(root.X) < 0.5, "character not in the doorway: %s", tostring(root))
	check(ctx.finished == 1, "client reported finished %d times", ctx.finished)
	assertRestored(ctx)
end)

test("plays with a classic head (no FaceControls)", function()
	local ctx = boot({ dynamicHead = false })
	local neck = ctx.head:FindFirstChild("Neck")
	local tilted = false
	playThrough(ctx, function()
		if neck.C0 ~= roblox.CFrame.new(0, 0.8, 0) then
			tilted = true
		end
	end)
	check(tilted, "chin lift never applied to the neck")
	assertRestored(ctx)
end)

test("plays with an R6 character", function()
	local ctx = boot({ rig = "R6" })
	playThrough(ctx)
	assertRestored(ctx)
end)

test("keeps the character visible when the player was in first person", function()
	local ctx = boot({ firstPerson = true })
	local hidden = 0
	playThrough(ctx, function()
		local screen = gui(ctx)
		local inCutscene = screen and screen:FindFirstChild("TopBar").Visible
		if inCutscene and screen:FindFirstChild("Fade").BackgroundTransparency > 0.5 and ctx.head.LocalTransparencyModifier ~= 0 then
			hidden += 1
		end
	end)
	check(hidden == 0, "character hidden on %d frames", hidden)
end)

test("moves the character onto the mark behind the opening fade", function()
	local ctx = boot()
	trigger(ctx)
	local moved = false
	for _ = 1, 60 do
		ctx.engine:step(DT)
		local root = ctx.humanoid.RootPart.Position
		if (root - (ORIGIN + Vector3.new(0, 3.6, 0))).Magnitude < 1e-3 then
			moved = true
			check(gui(ctx):FindFirstChild("Fade").BackgroundTransparency < 0.05, "moved while the screen was visible")
			break
		end
	end
	check(moved, "character never reached the mark")
end)

-- Ending early -------------------------------------------------------------

test("holding Space skips and restores everything", function()
	local ctx = boot({ dynamicHead = true })
	trigger(ctx)
	ctx.engine:run(7, DT) -- into the close-up
	ctx.engine:input(true, { KeyCode = Enum.KeyCode.Space })
	local start = ctx.engine.clock
	while ctx.finished == 0 do
		ctx.engine:step(DT)
		check(ctx.engine.clock - start < 2, "skip took too long")
	end
	ctx.engine:input(false, { KeyCode = Enum.KeyCode.Space })
	ctx.engine:run(1, DT)
	assertRestored(ctx)
end)

test("skipping mid-walk stops the character", function()
	local ctx = boot()
	trigger(ctx)
	ctx.engine:run(16.5, DT) -- shot 5 has started the walk
	check(ctx.humanoid.WalkSpeed == 7, "walk shot not reached")
	local skip = gui(ctx):FindFirstChild("SkipButton")
	skip.InputBegan:Fire({ UserInputType = Enum.UserInputType.Touch, KeyCode = Enum.KeyCode.Unknown })
	while ctx.finished == 0 do
		ctx.engine:step(DT)
	end
	ctx.engine:input(false, { UserInputType = Enum.UserInputType.Touch })
	ctx.engine:run(1, DT)
	local before = ctx.humanoid.RootPart.Position
	ctx.engine:run(1, DT)
	check((ctx.humanoid.RootPart.Position - before).Magnitude < 1e-3, "character kept walking after the skip")
	assertRestored(ctx)
end)

test("a short tap does not skip", function()
	local ctx = boot()
	trigger(ctx)
	ctx.engine:run(3, DT)
	ctx.engine:input(true, { KeyCode = Enum.KeyCode.Space })
	ctx.engine:run(0.5, DT)
	ctx.engine:input(false, { KeyCode = Enum.KeyCode.Space })
	ctx.engine:run(2, DT)
	check(ctx.finished == 0 and gui(ctx) ~= nil, "a half-second tap skipped the cutscene")
end)

test("dying ends the cutscene and restores the camera", function()
	local ctx = boot()
	trigger(ctx)
	ctx.engine:run(5, DT)
	ctx.engine:kill(ctx.humanoid)
	ctx.engine:run(2, DT)
	check(ctx.finished == 1, "client never reported back after death")
	assertRestored(ctx)
end)

test("a second trigger while playing is ignored on the client", function()
	local ctx = boot()
	trigger(ctx)
	ctx.engine:run(2, DT)
	local remotes = ctx.engine:service("ReplicatedStorage"):FindFirstChild("RemoteEvents")
	remotes:FindFirstChild("PlayCutscene").OnClientEvent:Fire()
	while ctx.finished == 0 do
		ctx.engine:step(DT)
	end
	ctx.engine:run(2, DT)
	check(ctx.finished == 1, "played twice")
	assertRestored(ctx)
end)

-- Server -------------------------------------------------------------------

test("server runs one cutscene at a time and hides the prompt meanwhile", function()
	local ctx = boot()
	local other = ctx.engine:addPlayer("Other", 2)
	ctx.engine:spawnCharacter(other, { position = ORIGIN + Vector3.new(-3, 0, 4) })
	trigger(ctx)
	ctx.engine:step(DT)
	check(not ctx.prompt.Enabled, "prompt still shown while in use")
	trigger(ctx, other)
	ctx.engine:step(DT)
	local firedToOther = 0
	for _, fired in ctx.engine.firedToClients do
		if fired.player == other then
			firedToOther += 1
		end
	end
	check(firedToOther == 0, "second player started a cutscene while one was running")
	while ctx.finished == 0 do
		ctx.engine:step(DT)
	end
	ctx.engine:step(DT)
	check(ctx.prompt.Enabled, "prompt not shown again")
	trigger(ctx, other)
	ctx.engine:step(DT)
	check(ctx.engine.firedToClients[#ctx.engine.firedToClients].player == other, "second player blocked after release")
end)

test("server cooldown counts from the end of the last cutscene", function()
	local ctx = boot()
	trigger(ctx)
	while ctx.finished == 0 do
		ctx.engine:step(DT)
	end
	local fired = #ctx.engine.firedToClients
	trigger(ctx)
	ctx.engine:step(DT)
	check(#ctx.engine.firedToClients == fired, "retriggered inside the cooldown")
	ctx.engine:run(3.1, DT)
	trigger(ctx)
	ctx.engine:step(DT)
	check(#ctx.engine.firedToClients == fired + 1, "blocked after the cooldown")
end)

test("server releases the lock if the client never reports back", function()
	local ctx = boot()
	local other = ctx.engine:addPlayer("Silent", 2) -- no client running
	trigger(ctx, other)
	ctx.engine:step(DT)
	check(not ctx.prompt.Enabled, "lock not taken")
	ctx.engine:run(44, DT)
	check(not ctx.prompt.Enabled, "released before MaxDuration")
	ctx.engine:run(1.1, DT)
	check(ctx.prompt.Enabled, "lock never timed out")
end)

test("server releases the lock when the player leaves", function()
	local ctx = boot()
	local other = ctx.engine:addPlayer("Leaver", 2)
	trigger(ctx, other)
	ctx.engine:step(DT)
	ctx.engine:service("Players").PlayerRemoving:Fire(other)
	ctx.engine:step(DT)
	check(ctx.prompt.Enabled, "lock kept after the player left")
end)

test("touch trigger is off by default and works when enabled", function()
	local ctx = boot()
	ctx.pad.Touched:Fire(ctx.character:FindFirstChild("LeftUpperLeg"))
	ctx.engine:step(DT)
	check(#ctx.engine.firedToClients == 0, "touch triggered while TouchTrigger is false")
	ctx.pad:SetAttribute("TouchTrigger", true)
	for _ = 1, 5 do
		ctx.pad.Touched:Fire(ctx.character:FindFirstChild("LeftUpperLeg"))
	end
	ctx.engine:step(DT)
	check(#ctx.engine.firedToClients == 1, "expected exactly one start from repeated touches, got %d", #ctx.engine.firedToClients)
end)

-- Runner -------------------------------------------------------------------

local filter = process.args[1]
local passed, failed = 0, 0
for _, entry in tests do
	if not filter or entry.name:find(filter, 1, true) then
		local ok, err = pcall(entry.fn)
		if ok then
			passed += 1
			print("PASS  " .. entry.name)
		else
			failed += 1
			print("FAIL  " .. entry.name .. "\n      " .. tostring(err):gsub("\n", "\n      "))
		end
	end
end
print(("\n%d passed, %d failed"):format(passed, failed))
process.exit(if failed == 0 then 0 else 1)
