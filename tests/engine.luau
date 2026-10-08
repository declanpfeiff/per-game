--!nocheck
-- A small headless stand-in for the Roblox engine, used by tests/run.luau.
--
-- Instances are checked against Roblox's reflection database (bundled with
-- Lune): reading or writing a property that doesn't exist, writing a
-- read-only one, or assigning the wrong type is an error, as are unknown
-- methods and events. Time is virtual: step() advances the clock, runs
-- render-step bindings, tweens, Heartbeat and any threads that are due.
-- Characters are simple rigs whose Humanoid can MoveTo and die.

local roblox = require("@lune/roblox")
local luau = require("@lune/luau")

local db = roblox.getReflectionDatabase()

local Engine = {}
Engine.__index = Engine

-- Lune's CFrame.lookAt points away from the target; build it from a basis.
local CFrameShim = setmetatable({
	lookAt = function(at: Vector3, target: Vector3, up: Vector3?)
		local back = (at - target).Unit
		local right = (up or roblox.Vector3.new(0, 1, 0)):Cross(back).Unit
		return roblox.CFrame.fromMatrix(at, right, back:Cross(right), back)
	end,
}, { __index = roblox.CFrame })

local TweenInfoShim = {
	new = function(time, style, direction, repeatCount, reverses, delayTime)
		return {
			Time = time or 1,
			EasingStyle = style or roblox.Enum.EasingStyle.Quad,
			EasingDirection = direction or roblox.Enum.EasingDirection.Out,
			RepeatCount = repeatCount or 0,
			Reverses = reverses or false,
			DelayTime = delayTime or 0,
		}
	end,
}

local function easeIn(style: string, t: number): number
	if style == "Linear" then
		return t
	elseif style == "Sine" then
		return 1 - math.cos(t * math.pi / 2)
	elseif style == "Quad" then
		return t * t
	elseif style == "Cubic" then
		return t * t * t
	elseif style == "Quart" then
		return t ^ 4
	elseif style == "Quint" then
		return t ^ 5
	end
	error("easing style not supported by the test engine: " .. style)
end

local function getValue(alpha: number, style, direction): number
	local t = math.clamp(alpha, 0, 1)
	local styleName = style.Name
	local directionName = direction.Name
	if directionName == "In" then
		return easeIn(styleName, t)
	elseif directionName == "Out" then
		return 1 - easeIn(styleName, 1 - t)
	end
	if t < 0.5 then
		return easeIn(styleName, t * 2) / 2
	end
	return 1 - easeIn(styleName, (1 - t) * 2) / 2
end

-- Events the code under test may use, by class (superclasses included).
local EVENTS = {
	Instance = { "ChildAdded", "Destroying" },
	BasePart = { "Touched" },
	GuiObject = { "InputBegan", "InputEnded" },
	Humanoid = { "Died", "MoveToFinished" },
	Player = { "CharacterAdded" },
	Players = { "PlayerAdded", "PlayerRemoving" },
	ProximityPrompt = { "Triggered" },
	RemoteEvent = { "OnClientEvent", "OnServerEvent" },
	RunService = { "Heartbeat", "RenderStepped", "Stepped" },
	UserInputService = { "InputBegan", "InputEnded" },
	Sound = { "Ended" },
}

local internals = setmetatable({}, { __mode = "k" })

local function isInstance(value): boolean
	return internals[value] ~= nil
end

local function classChain(className: string): { string }
	local chain = {}
	local class = db:GetClass(className)
	while class do
		table.insert(chain, class.Name)
		class = class.Superclass and db:GetClass(class.Superclass)
	end
	return chain
end

local function findProperty(className: string, name: string)
	for _, class in classChain(className) do
		local property = db:GetClass(class).Properties[name]
		if property then
			return property, class
		end
	end
	return nil
end

local function defaultValue(className: string, name: string, property)
	for _, class in classChain(className) do
		local defaults = db:GetClass(class).DefaultProperties
		if defaults and defaults[name] ~= nil then
			return defaults[name]
		end
	end
	local datatype = property.Datatype
	if datatype == "Float32" or datatype == "Float64" or datatype == "Int32" or datatype == "Int64" then
		return 0
	elseif datatype == "Bool" then
		return false
	elseif datatype == "String" or datatype == "ContentId" then
		return ""
	elseif datatype == "Ref" then
		return nil
	end
	error(("test engine has no default for %s.%s (%s)"):format(className, name, tostring(datatype)), 3)
end

local function checkType(className: string, name: string, property, value)
	local datatype = property.Datatype
	local ok
	if datatype == "Float32" or datatype == "Float64" or datatype == "Int32" or datatype == "Int64" then
		ok = type(value) == "number" and value == value
	elseif datatype == "Bool" then
		ok = type(value) == "boolean"
	elseif datatype == "String" or datatype == "ContentId" then
		ok = type(value) == "string"
	elseif datatype == "Ref" then
		ok = value == nil or isInstance(value)
	elseif type(datatype) == "string" and datatype:sub(1, 5) == "Enum." then
		ok = typeof(value) == "EnumItem" and tostring(value):find(datatype .. ".", 1, true) ~= nil
	else
		ok = typeof(value) == datatype
	end
	if not ok then
		error(("bad value for %s.%s: expected %s, got %s"):format(className, name, tostring(datatype), typeof(value)), 3)
	end
end

local Signal = {}
Signal.__index = Signal

function Signal.new(engine)
	return setmetatable({ _engine = engine, _handlers = {} }, Signal)
end

function Signal:Connect(fn)
	local connection = { Connected = true }
	function connection.Disconnect()
		connection.Connected = false
	end
	table.insert(self._handlers, { fn = fn, connection = connection })
	return connection
end

function Signal:Fire(...)
	for _, handler in table.clone(self._handlers) do
		if handler.connection.Connected then
			self._engine:spawn(handler.fn, ...)
		end
	end
end

function Signal:Wait()
	local thread = coroutine.running()
	local connection
	connection = self:Connect(function(...)
		connection:Disconnect()
		self._engine:resume(thread, ...)
	end)
	return coroutine.yield()
end

local InstanceMT = {}

InstanceMT.__index = function(self, key)
	local data = internals[self]
	if key == "Parent" then
		return data.parent
	elseif key == "ClassName" then
		return data.className
	end
	if data.props[key] ~= nil then
		return data.props[key]
	end
	if key == "Position" and table.find(classChain(data.className), "BasePart") then
		return self.CFrame.Position -- derived from CFrame, as in the engine
	end
	if key == "WorldPivot" and data.className == "Model" then
		return self:GetPivot()
	end
	for _, class in classChain(data.className) do
		local classMethods = data.engine.methods[class]
		if classMethods and classMethods[key] then
			return classMethods[key]
		end
		local events = EVENTS[class]
		if events and table.find(events, key) then
			data.signals[key] = data.signals[key] or Signal.new(data.engine)
			return data.signals[key]
		end
	end
	local property = findProperty(data.className, key)
	if not property then
		error(("%s is not a valid member of %s"):format(tostring(key), data.className), 2)
	end
	return defaultValue(data.className, key, property)
end

InstanceMT.__newindex = function(self, key, value)
	local data = internals[self]
	if key == "Parent" then
		if data.destroyed then
			error(("The Parent property of %s is locked"):format(data.props.Name or data.className), 2)
		end
		if value ~= nil and not isInstance(value) then
			error("Parent must be an Instance", 2)
		end
		local old = data.parent
		if old then
			local siblings = internals[old].children
			local index = table.find(siblings, self)
			if index then
				table.remove(siblings, index)
			end
		end
		data.parent = value
		if value then
			table.insert(internals[value].children, self)
		end
		return
	end
	if key == "Position" and table.find(classChain(data.className), "BasePart") then
		assert(typeof(value) == "Vector3", "bad value for Position")
		self.CFrame = self.CFrame.Rotation + value
		return
	end
	if key == "WorldPivot" and data.className == "Model" then
		-- With a PrimaryPart the pivot is stored as the part's PivotOffset.
		assert(typeof(value) == "CFrame", "bad value for WorldPivot")
		local primary = data.props.PrimaryPart
		if primary then
			primary.PivotOffset = primary.CFrame:Inverse() * value
		else
			data.props.WorldPivot = value
		end
		return
	end
	local property = findProperty(data.className, key)
	if not property then
		error(("%s is not a valid member of %s"):format(tostring(key), data.className), 2)
	end
	if property.Scriptability ~= "ReadWrite" and property.Scriptability ~= "Custom" and not data.engine.privileged then
		error(("%s.%s is read-only (%s)"):format(data.className, key, property.Scriptability), 2)
	end
	checkType(data.className, key, property, value)
	data.props[key] = value
end

InstanceMT.__tostring = function(self)
	return internals[self].props.Name or internals[self].className
end

local function newEngine()
	local engine = setmetatable({
		clock = 0,
		frame = 0,
		sequence = 0,
		waiting = {},
		errors = {},
		output = {},
		warnings = {},
		renderBindings = {},
		tweens = {},
		humanoids = {},
		services = {},
		modules = {},
		moduleOverrides = {},
		coreGui = {},
		firedToClients = {},
		privileged = false,
	}, Engine)
	engine.methods = engine:_buildMethods()
	engine.task = engine:_buildTask()
	engine.game = engine:_create("DataModel")
	internals[engine.game].props.Name = "Game"

	local workspace = engine:service("Workspace")
	local camera = engine:_create("Camera")
	camera.Name = "Camera"
	camera.Parent = workspace
	engine:setRead(camera, "ViewportSize", roblox.Vector2.new(1920, 1080))
	workspace.CurrentCamera = camera
	camera.CameraType = roblox.Enum.CameraType.Custom
	engine.camera = camera
	engine:setRead(engine:service("UserInputService"), "KeyboardEnabled", true)
	engine:service("ProximityPromptService").Enabled = true
	-- Present in every Studio place (and not creatable by scripts).
	for _, className in { "StarterPlayerScripts", "StarterCharacterScripts" } do
		local container = engine:_create(className)
		container.Name = className
		container.Parent = engine:service("StarterPlayer")
	end
	for _, item in roblox.Enum.CoreGuiType:GetEnumItems() do
		if item ~= roblox.Enum.CoreGuiType.All then
			engine.coreGui[item.Name] = true
		end
	end
	return engine
end

function Engine:_create(className: string)
	assert(db:GetClass(className), "unknown class " .. className)
	local instance = setmetatable({}, InstanceMT)
	internals[instance] = {
		engine = self,
		className = className,
		props = {},
		children = {},
		attributes = {},
		signals = {},
		parent = nil,
		destroyed = false,
	}
	internals[instance].props.Name = className
	return instance
end

function Engine:new(className: string)
	local class = db:GetClass(className)
	if not class then
		error(("Unable to create an Instance of type %q"):format(className), 2)
	end
	if table.find(class.Tags, "NotCreatable") or table.find(class.Tags, "Service") then
		error(("Unable to create an Instance of type %q"):format(className), 2)
	end
	return self:_create(className)
end

-- Sets a property the engine owns (read-only to scripts).
function Engine:setRead(instance, key: string, value)
	internals[instance].props[key] = value
end

function Engine:service(name: string)
	local service = self.services[name]
	if not service then
		service = self:_create(name)
		internals[service].props.Name = name
		service.Parent = self.game
		self.services[name] = service
	end
	return service
end

function Engine:children(instance)
	return internals[instance].children
end

function Engine:isDestroyed(instance): boolean
	return internals[instance].destroyed
end

function Engine:signal(instance, name: string)
	return instance[name]
end

-- Scheduler ---------------------------------------------------------------

function Engine:resume(thread, ...)
	local ok, err = coroutine.resume(thread, ...)
	if not ok then
		table.insert(self.errors, debug.traceback(thread, tostring(err)))
	end
end

function Engine:spawn(fn, ...)
	local thread = if type(fn) == "thread" then fn else coroutine.create(fn)
	self:resume(thread, ...)
	return thread
end

function Engine:_schedule(entry)
	self.sequence += 1
	entry.sequence = self.sequence
	entry.frame = self.frame
	table.insert(self.waiting, entry)
end

function Engine:_buildTask()
	local engine = self
	return {
		wait = function(seconds: number?)
			local thread = coroutine.running()
			local start = engine.clock
			engine:_schedule({ thread = thread, at = start + (seconds or 0) })
			coroutine.yield()
			return engine.clock - start
		end,
		spawn = function(fn, ...)
			return engine:spawn(fn, ...)
		end,
		defer = function(fn, ...)
			local args = table.pack(...)
			engine:_schedule({ fn = fn, args = args, at = engine.clock })
		end,
		delay = function(seconds: number, fn, ...)
			local args = table.pack(...)
			engine:_schedule({ fn = fn, args = args, at = engine.clock + seconds })
		end,
		cancel = function() end,
	}
end

function Engine:step(dt: number)
	self.clock += dt
	self.frame += 1

	for _, humanoid in self.humanoids do
		self:_simulateHumanoid(humanoid, dt)
	end

	local bindings = table.clone(self.renderBindings)
	table.sort(bindings, function(a, b)
		return a.priority < b.priority
	end)
	for _, binding in bindings do
		if self.renderBindings[binding.name] == binding then
			local ok, err = pcall(binding.fn, dt)
			if not ok then
				table.insert(self.errors, "render step " .. binding.name .. ": " .. tostring(err))
			end
		end
	end
	self:service("RunService").RenderStepped:Fire(dt)

	self:_updateTweens()

	local due = {}
	for index = #self.waiting, 1, -1 do
		local entry = self.waiting[index]
		if entry.at <= self.clock + 1e-9 and entry.frame < self.frame then
			table.remove(self.waiting, index)
			table.insert(due, entry)
		end
	end
	table.sort(due, function(a, b)
		return a.sequence < b.sequence
	end)
	for _, entry in due do
		if entry.thread then
			if coroutine.status(entry.thread) == "suspended" then
				self:resume(entry.thread)
			end
		else
			self:spawn(entry.fn, table.unpack(entry.args, 1, entry.args.n))
		end
	end

	self:service("RunService").Heartbeat:Fire(dt)
	self:_simulatePhysics()

	if #self.errors > 0 then
		local message = table.concat(self.errors, "\n")
		table.clear(self.errors)
		error(message, 0)
	end
end

function Engine:run(seconds: number, dt: number?, onFrame: (() -> ())?)
	local stepSize = dt or 1 / 60
	local finish = self.clock + seconds
	while self.clock < finish - 1e-9 do
		self:step(stepSize)
		if onFrame then
			onFrame()
		end
	end
end

-- Tweens ------------------------------------------------------------------

local function lerpValue(a, b, t)
	if type(a) == "number" then
		return a + (b - a) * t
	end
	return a:Lerp(b, t)
end

function Engine:_updateTweens()
	for tween in table.clone(self.tweens) do
		if tween.PlaybackState == "Playing" then
			local alpha = if tween.info.Time > 0 then (self.clock - tween.started) / tween.info.Time else 1
			local eased = getValue(alpha, tween.info.EasingStyle, tween.info.EasingDirection)
			for key, goal in tween.goals do
				tween.instance[key] = lerpValue(tween.from[key], goal, eased)
			end
			if alpha >= 1 then
				tween.PlaybackState = "Completed"
				self.tweens[tween] = nil
			end
		end
	end
end

function Engine:_createTween(instance, info, goals)
	assert(isInstance(instance), "TweenService:Create expects an Instance")
	for key, goal in goals do
		local property = findProperty(internals[instance].className, key)
		assert(property, ("cannot tween %s.%s: no such property"):format(internals[instance].className, key))
		checkType(internals[instance].className, key, property, goal)
	end
	local engine = self
	goals = table.clone(goals)
	local tween = { instance = instance, info = info, goals = goals, PlaybackState = "Begin" }
	function tween.Play()
		tween.from = {}
		for key in goals do
			tween.from[key] = instance[key]
		end
		-- A new tween takes over properties from older ones, as in Roblox.
		for other in engine.tweens do
			if other.instance == instance then
				for key in goals do
					other.goals[key] = nil
				end
			end
		end
		tween.started = engine.clock
		tween.PlaybackState = "Playing"
		engine.tweens[tween] = true
	end
	function tween.Cancel()
		tween.PlaybackState = "Cancelled"
		engine.tweens[tween] = nil
	end
	return tween
end

-- Characters --------------------------------------------------------------

function Engine:_simulateHumanoid(humanoid, dt: number)
	local data = internals[humanoid].sim
	local root = humanoid.RootPart
	if not root or humanoid.Health <= 0 then
		return
	end
	if data.target then
		local offset = data.target - root.Position
		local flat = roblox.Vector3.new(offset.X, 0, offset.Z)
		local distance = flat.Magnitude
		local stepLength = humanoid.WalkSpeed * dt
		data.elapsed += dt
		if distance <= math.max(stepLength, 0.05) or data.elapsed > 8 then
			if distance <= stepLength then
				root.CFrame = root.CFrame + flat
			end
			data.target = nil
			humanoid.MoveToFinished:Fire(distance <= stepLength)
		else
			local direction = flat.Unit
			local position = root.Position + direction * stepLength
			root.CFrame = CFrameShim.lookAt(position, position + direction)
		end
	end
end

function Engine:_simulatePhysics()
	for _, humanoid in self.humanoids do
		local data = internals[humanoid].sim
		local root = humanoid.RootPart
		if root then
			for part, offset in data.joints do
				part.CFrame = root.CFrame * offset
			end
			local head, neck = data.head, data.neck
			if head and neck then
				head.CFrame = root.CFrame * data.headOffset * (data.restNeckC0:Inverse() * neck.C0)
			end
		end
	end
end

type CharacterOptions = { rig: string?, dynamicHead: boolean?, position: Vector3? }

function Engine:addPlayer(name: string, userId: number)
	local players = self:service("Players")
	local player = self:_create("Player")
	player.Name = name
	self:setRead(player, "UserId", userId)
	local playerGui = self:_create("PlayerGui")
	playerGui.Name = "PlayerGui"
	playerGui.Parent = player
	local playerScripts = self:_create("PlayerScripts")
	playerScripts.Name = "PlayerScripts"
	playerScripts.Parent = player
	local playerModule = self:_create("ModuleScript")
	playerModule.Name = "PlayerModule"
	playerModule.Parent = playerScripts
	local controls = { enabled = true }
	function controls.Enable(self)
		self.enabled = true
	end
	function controls.Disable(self)
		self.enabled = false
	end
	self.moduleOverrides[playerModule] = {
		GetControls = function()
			return controls
		end,
	}
	player.Parent = players
	return player, controls
end

function Engine:spawnCharacter(player, options: CharacterOptions?)
	local opts = options or {}
	local Vector3, CFrame = roblox.Vector3, roblox.CFrame
	local r15 = (opts.rig or "R15") == "R15"

	local model = self:_create("Model")
	model.Name = player.Name
	local humanoid = self:_create("Humanoid")
	humanoid.RigType = if r15 then roblox.Enum.HumanoidRigType.R15 else roblox.Enum.HumanoidRigType.R6
	humanoid.HipHeight = if r15 then 2 else 0
	humanoid.Health = 100
	humanoid.WalkSpeed = 16

	local rootHeight = 3 -- R15: HipHeight 2 + half the root; R6: legs 2 + half the torso
	local position = opts.position or Vector3.new(0, 0, 0)
	local root = self:_create("Part")
	root.Name = "HumanoidRootPart"
	root.Size = Vector3.new(2, 2, 1)
	root.Transparency = 1
	root.CFrame = CFrame.new(position + Vector3.new(0, rootHeight, 0))
	root.Parent = model
	model.PrimaryPart = root

	local headClass = if opts.dynamicHead then "MeshPart" else "Part"
	local head = self:_create(headClass)
	head.Name = "Head"
	head.Size = Vector3.new(1.2, 1.2, 1.2)
	head.Parent = model
	local headOffset = CFrame.new(0, if r15 then 1.75 else 1.5, 0)

	local joints = {}
	local function limb(name: string, size: Vector3, offset: Vector3)
		local part = self:_create("Part")
		part.Name = name
		part.Size = size
		part.Parent = model
		joints[part] = CFrame.new(offset)
	end
	if r15 then
		limb("UpperTorso", Vector3.new(2, 1.6, 1), Vector3.new(0, 0.5, 0))
		limb("LowerTorso", Vector3.new(2, 0.4, 1), Vector3.new(0, -0.6, 0))
		limb("LeftUpperLeg", Vector3.new(1, 1.2, 1), Vector3.new(-0.5, -1.4, 0))
		limb("RightUpperLeg", Vector3.new(1, 1.2, 1), Vector3.new(0.5, -1.4, 0))
	else
		limb("Torso", Vector3.new(2, 2, 1), Vector3.new(0, 0, 0))
		limb("Left Leg", Vector3.new(1, 2, 1), Vector3.new(-0.5, -2, 0))
		limb("Right Leg", Vector3.new(1, 2, 1), Vector3.new(0.5, -2, 0))
	end

	local neck = nil
	if r15 then
		neck = self:_create("Motor6D")
		neck.Name = "Neck"
		neck.C0 = CFrame.new(0, 0.8, 0)
		neck.Parent = head
	end
	if opts.dynamicHead then
		local face = self:_create("FaceControls")
		face.Parent = head
	else
		local face = self:_create("Decal")
		face.Name = "face"
		face.Parent = head
	end

	humanoid.Parent = model
	self:setRead(humanoid, "RootPart", root)

	internals[humanoid].sim = {
		target = nil,
		elapsed = 0,
		joints = joints,
		head = head,
		headOffset = headOffset,
		neck = neck,
		restNeckC0 = if neck then neck.C0 else nil,
	}
	table.insert(self.humanoids, humanoid)

	model.Parent = self:service("Workspace")
	player.Character = model
	self:_simulatePhysics()
	return model, humanoid
end

function Engine:kill(humanoid)
	humanoid.Health = 0
	humanoid.Died:Fire()
end

-- Methods -----------------------------------------------------------------

function Engine:_buildMethods()
	local engine = self
	local function descendants(instance, out)
		for _, child in internals[instance].children do
			table.insert(out, child)
			descendants(child, out)
		end
		return out
	end
	local function isA(instance, className: string): boolean
		return table.find(classChain(internals[instance].className), className) ~= nil
	end

	return {
		Instance = {
			FindFirstChild = function(self, name: string, recursive: boolean?)
				local list = if recursive then descendants(self, {}) else internals[self].children
				for _, child in list do
					if child.Name == name then
						return child
					end
				end
				return nil
			end,
			FindFirstChildOfClass = function(self, className: string)
				for _, child in internals[self].children do
					if internals[child].className == className then
						return child
					end
				end
				return nil
			end,
			FindFirstChildWhichIsA = function(self, className: string, recursive: boolean?)
				local list = if recursive then descendants(self, {}) else internals[self].children
				for _, child in list do
					if isA(child, className) then
						return child
					end
				end
				return nil
			end,
			WaitForChild = function(self, name: string, timeout: number?)
				local deadline = engine.clock + (timeout or 5)
				while true do
					local child = self:FindFirstChild(name)
					if child then
						return child
					end
					if engine.clock >= deadline then
						if timeout then
							return nil
						end
						error(("Infinite yield on %s:WaitForChild(%q)"):format(tostring(self), name), 2)
					end
					engine.task.wait()
				end
			end,
			GetChildren = function(self)
				return table.clone(internals[self].children)
			end,
			GetDescendants = function(self)
				return descendants(self, {})
			end,
			IsA = isA,
			Destroy = function(self)
				local data = internals[self]
				if data.destroyed then
					return
				end
				for _, child in table.clone(data.children) do
					child:Destroy()
				end
				self.Parent = nil
				data.destroyed = true
			end,
			Clone = function(self)
				local data = internals[self]
				local copy = engine:_create(data.className)
				for key, value in data.props do
					internals[copy].props[key] = value
				end
				for _, child in data.children do
					child:Clone().Parent = copy
				end
				return copy
			end,
			SetAttribute = function(self, name: string, value)
				internals[self].attributes[name] = value
			end,
			GetAttribute = function(self, name: string)
				return internals[self].attributes[name]
			end,
		},
		Model = {
			PivotTo = function(self, target)
				assert(typeof(target) == "CFrame", "PivotTo expects a CFrame")
				local delta = target * self:GetPivot():Inverse()
				for _, part in descendants(self, {}) do
					if isA(part, "BasePart") then
						part.CFrame = delta * part.CFrame
					end
				end
				if not self.PrimaryPart then
					internals[self].props.WorldPivot = target
				end
			end,
			GetPivot = function(self)
				local primary = self.PrimaryPart
				if primary then
					return primary.CFrame * primary.PivotOffset
				end
				return internals[self].props.WorldPivot or roblox.CFrame.new()
			end,
			GetScale = function(self)
				return internals[self].scale or 1
			end,
			-- Scales parts about the pivot, which stays put.
			ScaleTo = function(self, scale: number)
				assert(type(scale) == "number" and scale > 0, "ScaleTo expects a positive number")
				local factor = scale / (internals[self].scale or 1)
				local pivot = self:GetPivot()
				for _, part in descendants(self, {}) do
					if isA(part, "BasePart") then
						local relative = pivot:Inverse() * part.CFrame
						part.CFrame = pivot * (relative.Rotation + relative.Position * factor)
						part.Size *= factor
						part.PivotOffset = part.PivotOffset.Rotation + part.PivotOffset.Position * factor
					end
				end
				internals[self].scale = scale
			end,
		},
		Workspace = {
			-- Nearest part (as a box) along the ray, honouring an Exclude filter.
			Raycast = function(self, origin, direction, params)
				local excluded = {}
				if params and params.FilterType == roblox.Enum.RaycastFilterType.Exclude then
					for _, root in params.FilterDescendantsInstances do
						excluded[root] = true
						for _, d in descendants(root, {}) do
							excluded[d] = true
						end
					end
				end
				local best
				for _, part in descendants(self, {}) do
					if isA(part, "BasePart") and not excluded[part] then
						local t = Engine.rayBox(part, origin, direction)
						if t and (not best or t < best.t) then
							best = { t = t, part = part }
						end
					end
				end
				if not best then
					return nil
				end
				return {
					Instance = best.part,
					Position = origin + direction * best.t,
					Distance = direction.Magnitude * best.t,
				}
			end,
		},
		Selection = {
			Get = function()
				return table.clone(engine.selection or {})
			end,
			Set = function(_, list)
				engine.selection = table.clone(list)
			end,
		},
		Humanoid = {
			MoveTo = function(self, location, part)
				assert(typeof(location) == "Vector3", "MoveTo expects a Vector3")
				assert(part == nil or isInstance(part), "MoveTo part must be a BasePart")
				local sim = internals[self].sim
				sim.target = location
				sim.elapsed = 0
			end,
		},
		DataModel = {
			GetService = function(_, name: string)
				return engine:service(name)
			end,
		},
		Players = {
			GetPlayerFromCharacter = function(self, character)
				for _, player in internals[self].children do
					if player.Character == character then
						return player
					end
				end
				return nil
			end,
			GetPlayers = function(self)
				return table.clone(internals[self].children)
			end,
		},
		RunService = {
			BindToRenderStep = function(_, name: string, priority: number, fn)
				assert(type(priority) == "number", "BindToRenderStep priority must be a number")
				engine.renderBindings[name] = { name = name, priority = priority, fn = fn }
			end,
			UnbindFromRenderStep = function(_, name: string)
				engine.renderBindings[name] = nil
			end,
			IsClient = function()
				return true
			end,
		},
		TweenService = {
			Create = function(_, instance, info, goals)
				return engine:_createTween(instance, info, goals)
			end,
			GetValue = function(_, alpha: number, style, direction)
				return getValue(alpha, style, direction)
			end,
		},
		StarterGui = {
			GetCoreGuiEnabled = function(_, coreGuiType)
				return engine.coreGui[coreGuiType.Name]
			end,
			SetCoreGuiEnabled = function(_, coreGuiType, enabled: boolean)
				if coreGuiType == roblox.Enum.CoreGuiType.All then
					for key in engine.coreGui do
						engine.coreGui[key] = enabled
					end
				else
					engine.coreGui[coreGuiType.Name] = enabled
				end
			end,
		},
		RemoteEvent = {
			FireClient = function(self, player, ...)
				assert(isA(player, "Player"), "FireClient expects a Player")
				table.insert(engine.firedToClients, { remote = self.Name, player = player })
				if player == engine.localPlayer then
					self.OnClientEvent:Fire(...)
				end
			end,
			FireServer = function(self, ...)
				self.OnServerEvent:Fire(engine.localPlayer, ...)
			end,
		},
		Sound = {
			Play = function(self)
				internals[self].playing = true
			end,
			Stop = function(self)
				internals[self].playing = false
			end,
		},
	}
end

-- Scripts -----------------------------------------------------------------

function Engine:require(module)
	assert(isInstance(module) and module:IsA("ModuleScript"), "require expects a ModuleScript")
	local override = self.moduleOverrides[module]
	if override then
		return override
	end
	local cached = self.modules[module]
	if cached then
		return cached.value
	end
	local chunk = luau.load(module.Source, { debugName = module.Name, environment = self:environment(module) })
	local value = chunk()
	self.modules[module] = { value = value }
	return value
end

function Engine:environment(script)
	local engine = self
	return {
		game = self.game,
		workspace = self:service("Workspace"),
		script = script,
		Instance = {
			new = function(className: string)
				return engine:new(className)
			end,
		},
		CFrame = CFrameShim,
		TweenInfo = TweenInfoShim,
		RaycastParams = {
			new = function()
				return { FilterType = roblox.Enum.RaycastFilterType.Exclude, FilterDescendantsInstances = {} }
			end,
		},
		Vector3 = roblox.Vector3,
		Vector2 = roblox.Vector2,
		Color3 = roblox.Color3,
		UDim = roblox.UDim,
		UDim2 = roblox.UDim2,
		NumberSequence = roblox.NumberSequence,
		Enum = roblox.Enum,
		task = self.task,
		os = {
			clock = function()
				return engine.clock
			end,
			time = function()
				return engine.clock
			end,
		},
		require = function(module)
			return engine:require(module)
		end,
		print = function(...)
			table.insert(engine.output, table.concat({ ... }, " "))
		end,
		warn = function(...)
			local parts = {}
			for _, value in { ... } do
				table.insert(parts, tostring(value))
			end
			table.insert(engine.warnings, table.concat(parts, " "))
		end,
		typeof = function(value)
			if isInstance(value) then
				return "Instance"
			end
			return typeof(value)
		end,
	}
end

-- Runs a Script/LocalScript (or raw source) in its own thread.
function Engine:runScript(script, source: string?)
	local chunk = luau.load(source or script.Source, {
		debugName = if script then script.Name else "chunk",
		environment = self:environment(script),
	})
	return self:spawn(chunk)
end

function Engine:setLocalPlayer(player)
	self.localPlayer = player
	self:setRead(self:service("Players"), "LocalPlayer", player)
end

-- Fires a key or pointer input through UserInputService.
function Engine:input(began: boolean, fields)
	local input = setmetatable(fields, {
		__index = { KeyCode = roblox.Enum.KeyCode.Unknown, UserInputType = roblox.Enum.UserInputType.Keyboard },
	})
	local uis = self:service("UserInputService")
	if began then
		uis.InputBegan:Fire(input, false)
	else
		uis.InputEnded:Fire(input, false)
	end
	return input
end

-- Geometry helpers for framing checks ---------------------------------------

-- Fraction (0..1) along origin + direction where the ray enters a part's box, if it does.
function Engine.rayBox(part, origin: Vector3, direction: Vector3): number?
	local cf = part.CFrame
	local o = cf:PointToObjectSpace(origin)
	local d = cf:VectorToObjectSpace(direction)
	local half = part.Size / 2
	local enter, exit = 0, 1
	for _, axis in { "X", "Y", "Z" } do
		local oa, da, ha = o[axis], d[axis], half[axis]
		if math.abs(da) < 1e-9 then
			if math.abs(oa) > ha then
				return nil
			end
		else
			local t1, t2 = (-ha - oa) / da, (ha - oa) / da
			enter = math.max(enter, math.min(t1, t2))
			exit = math.min(exit, math.max(t1, t2))
			if enter > exit then
				return nil
			end
		end
	end
	return enter
end

-- Is a world point inside a part's box (grown by `margin` studs)?
function Engine.pointInPart(part, point: Vector3, margin: number?): boolean
	local localPoint = part.CFrame:PointToObjectSpace(point)
	local half = part.Size / 2 + roblox.Vector3.one * (margin or 0)
	return math.abs(localPoint.X) <= half.X and math.abs(localPoint.Y) <= half.Y and math.abs(localPoint.Z) <= half.Z
end

-- Does the segment from a to b pass through a part's box?
function Engine.segmentHitsPart(part, a: Vector3, b: Vector3): boolean
	local origin = part.CFrame:PointToObjectSpace(a)
	local finish = part.CFrame:PointToObjectSpace(b)
	local direction = finish - origin
	local half = part.Size / 2
	local tMin, tMax = 0, 1
	for _, axis in { "X", "Y", "Z" } do
		local o, d, h = origin[axis], direction[axis], half[axis]
		if math.abs(d) < 1e-9 then
			if math.abs(o) > h then
				return false
			end
		else
			local t1, t2 = (-h - o) / d, (h - o) / d
			if t1 > t2 then
				t1, t2 = t2, t1
			end
			tMin, tMax = math.max(tMin, t1), math.min(tMax, t2)
			if tMin > tMax then
				return false
			end
		end
	end
	return true
end

Engine.internals = internals
Engine.CFrame = CFrameShim
Engine.create = newEngine

return Engine
