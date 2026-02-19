local Rayfield = loadstring(game:HttpGet('https://sirius.menu/rayfield'))()

local Window = Rayfield:CreateWindow({
   Name = "Evade Features",
   Icon = 0,
   LoadingTitle = "Loading Features",
   LoadingSubtitle = "by xzyyysh",
   Theme = "Default",
   DisableRayfieldPrompts = false,
   DisableBuildWarnings = false,
   ConfigurationSaving = {
      Enabled = true,
      FolderName = nil,
      FileName = "XyzHubEvade"
   },
   Discord = {
      Enabled = false,
      Invite = "noinvitelink",
      RememberJoins = true
   },
   KeySystem = false,
   KeySettings = {
      Title = "Untitled",
      Subtitle = "Key System",
      Note = "No method of obtaining the key is provided",
      FileName = "Key",
      SaveKey = true,
      GrabKeyFromSite = false,
      Key = {"Hello"}
   }
})

local AutoTab = Window:CreateTab("Auto Features", "zap")
local MovementTab = Window:CreateTab("Movement", "wind")

Players = game:GetService("Players")
RunService = game:GetService("RunService")
UserInputService = game:GetService("UserInputService")
Debris = game:GetService("Debris")
player = Players.LocalPlayer
camera = workspace.CurrentCamera

featureStates = {
   AutoCarry = false,
   Bhop = false,
   BhopHold = false
}

--[[ ========================================
     AUTO CARRY FEATURE
     ======================================== ]]

function startAutoCarry()
AutoCarryConnection = RunService.Heartbeat:Connect(function()
if not featureStates.AutoCarry then return end
local char = player.Character
local hrp = char and char:FindFirstChild("HumanoidRootPart")
if hrp then
for _, other in ipairs(Players:GetPlayers()) do
if other ~= player and other.Character and other.Character:FindFirstChild("HumanoidRootPart") then
local dist = (hrp.Position - other.Character.HumanoidRootPart.Position).Magnitude
if dist <= 20 then
local args = { "Carry", [3] = other.Name }
pcall(function()
game:GetService("ReplicatedStorage"):WaitForChild("Events"):WaitForChild("Character"):WaitForChild("Interact"):FireServer(unpack(args))
end)
task.wait(0.01)
end
end
end
end
end)
end

function stopAutoCarry()
if AutoCarryConnection then
AutoCarryConnection:Disconnect()
AutoCarryConnection = nil
end
end

local AutoCarryToggle = AutoTab:CreateToggle({
   Name = "Auto Carry",
   CurrentValue = false,
   Flag = "AutoCarryToggle",
   Callback = function(state)
      featureStates.AutoCarry = state
      if state then
         startAutoCarry()
      else
         stopAutoCarry()
      end
   end
})


--[[ ========================================
     EASY TRIMP FEATURE
     ======================================== ]]

getgenv().EasyTrimp = {
   Enabled = false,
   BaseSpeed = 50,
   ExtraSpeed = 100,
   FloorDrop = 0
}

extra = getgenv().EasyTrimp.ExtraSpeed
floorDrop = getgenv().EasyTrimp.FloorDrop
last = tick()
airTick = 0
airSum = 0
airborne = false
push = nil
speed = getgenv().EasyTrimp.BaseSpeed
allow = false

function cut(n)
return math.floor(n*10)/10
end

function meter()
   ok, v = pcall(function()
      return player.PlayerGui.Shared.HUD.Overlay.Default.CharacterInfo.Item.Speedometer.Players
   end)
   if ok then return v end
end

RunService.RenderStepped:Connect(function()
   dt = tick() - last
   last = tick()

   ch = player.Character
if not ch then return end

hrp = ch:FindFirstChild("HumanoidRootPart")
hum = ch:FindFirstChild("Humanoid")
if not hrp or not hum then return end

spd = meter()
inAir = hum.FloorMaterial == Enum.Material.Air

if airborne and not inAir then
speed = math.max(getgenv().EasyTrimp.BaseSpeed - floorDrop, speed - 10)
if spd then spd.Text = cut(speed) end
airSum = 0
end
airborne = inAir

if getgenv().EasyTrimp.Enabled then
if inAir then
airSum += dt
airTick += dt
while airTick >= 0.04 do
airTick -= 0.04
add = math.max(0.1, 2.5 * (0.04 / 1))
speed = math.min(getgenv().EasyTrimp.BaseSpeed + extra, speed + add)
end
else
airTick = 0
airSum = 0
speed = math.max(getgenv().EasyTrimp.BaseSpeed - floorDrop, speed - (2.5 * dt))
end

if push then push:Destroy() end

look = camera.CFrame.LookVector
moveDir = Vector3.new(look.X, 0, look.Z)
if moveDir.Magnitude > 0 then moveDir = moveDir.Unit end

bv = Instance.new("BodyVelocity")
bv.Velocity = moveDir * speed
bv.MaxForce = Vector3.new(4e5, 0, 4e5)
bv.P = 1250
bv.Parent = hrp
Debris:AddItem(bv, 0.1)
push = bv

allow = true
if spd then spd.Text = cut(speed) end
else
if push then push:Destroy() push = nil end
speed = getgenv().EasyTrimp.BaseSpeed
allow = false
airTick = 0
airSum = 0
airborne = false
end
end)

MovementTab:CreateSection("Easy Trimp")

local EasyTrimpToggle = MovementTab:CreateToggle({
   Name = "Easy Trimp",
   CurrentValue = false,
   Flag = "EasyTrimpToggle",
   Callback = function(state)
      getgenv().EasyTrimp.Enabled = state
   end
})

local BaseSpeedInput = MovementTab:CreateInput({
   Name = "Base Speed",
   CurrentValue = "50",
   PlaceholderText = "50",
   RemoveTextAfterFocusLost = false,
   Flag = "EasyTrimpBaseSpeed",
   Callback = function(value)
      local num = tonumber(value)
      if num then
         getgenv().EasyTrimp.BaseSpeed = num
         speed = num
      end
   end
})

local ExtraSpeedInput = MovementTab:CreateInput({
   Name = "Extra Speed",
   CurrentValue = "100",
   PlaceholderText = "100",
   RemoveTextAfterFocusLost = false,
   Flag = "EasyTrimpExtraSpeed",
   Callback = function(value)
      local num = tonumber(value)
      if num then
         getgenv().EasyTrimp.ExtraSpeed = num
         extra = num
      end
   end
})

local FloorDropInput = MovementTab:CreateInput({
   Name = "Floor Drop",
   CurrentValue = "0",
   PlaceholderText = "0",
   RemoveTextAfterFocusLost = false,
   Flag = "EasyTrimpFloorDrop",
   Callback = function(value)
      local num = tonumber(value)
      if num then
         getgenv().EasyTrimp.FloorDrop = num
         floorDrop = num
      end
   end
})


--[[ ========================================
     BHOP/SPEED SYSTEM FEATURE
     ======================================== ]]

getgenv().bhopMode = "Acceleration"
getgenv().bhopAccelValue = -0.5
getgenv().bhopHoldActive = false
getgenv().autoJumpEnabled = false
getgenv().autoJumpType = "Bounce"
getgenv().jumpCooldown = 0.7

isMobile = UserInputService.TouchEnabled

bhopConnection = nil
bhopLoaded = false
characterConnection = nil
frictionTables = {}

Character = nil
Humanoid = nil
HumanoidRootPart = nil
LastJump = 0

GROUND_CHECK_DISTANCE = 3.5
MAX_SLOPE_ANGLE = 45
AIR_RANGE = 0.1

findFrictionTables = function()
frictionTables = {}
for _, t in pairs(getgc(true)) do
if type(t) == "table" and rawget(t, "Friction") then
table.insert(frictionTables, {obj = t, original = t.Friction})
end
end
end

setFriction = function(value)
for _, e in ipairs(frictionTables) do
if e.obj and type(e.obj) == "table" and rawget(e.obj, "Friction") then
e.obj.Friction = value
end
end
end

resetBhopFriction = function()
for _, e in ipairs(frictionTables) do
if e.obj and type(e.obj) == "table" and rawget(e.obj, "Friction") then
e.obj.Friction = e.original
end
end
frictionTables = {}
end

applyBhopFriction = function()
if getgenv().bhopMode == "Acceleration" then
findFrictionTables()
if #frictionTables > 0 then
setFriction(getgenv().bhopAccelValue or -0.5)
end
else
resetBhopFriction()
end
end

IsOnGround = function()
if not Character or not HumanoidRootPart or not Humanoid then return false end

state = Humanoid:GetState()
if state == Enum.HumanoidStateType.Jumping or 
state == Enum.HumanoidStateType.Freefall or
state == Enum.HumanoidStateType.Swimming then
return false
end

raycastParams = RaycastParams.new()
raycastParams.FilterType = Enum.RaycastFilterType.Blacklist
raycastParams.FilterDescendantsInstances = {Character}
raycastParams.IgnoreWater = true

rayOrigin = HumanoidRootPart.Position
rayDirection = Vector3.new(0, -GROUND_CHECK_DISTANCE, 0)
raycastResult = workspace:Raycast(rayOrigin, rayDirection, raycastParams)

if not raycastResult then return false end

surfaceNormal = raycastResult.Normal
angle = math.deg(math.acos(surfaceNormal:Dot(Vector3.new(0, 1, 0))))

return angle <= MAX_SLOPE_ANGLE
end

updateBhop = function()
if not bhopLoaded then return end

character = player.Character
humanoid = character and character:FindFirstChild("Humanoid")
if not character or not humanoid then
return
end

isBhopActive = getgenv().autoJumpEnabled or getgenv().bhopHoldActive

if isBhopActive then
now = tick()
if IsOnGround() and (now - LastJump) > getgenv().jumpCooldown then
if getgenv().autoJumpType == "Realistic" then
game:GetService("Players").LocalPlayer.PlayerScripts.Events.temporary_events.JumpReact:Fire()
task.wait(0.1)
game:GetService("Players").LocalPlayer.PlayerScripts.Events.temporary_events.EndJump:Fire()
else
humanoid:ChangeState(Enum.HumanoidStateType.Jumping)
end
LastJump = now
end
end
end

loadBhop = function()
if bhopLoaded then return end

bhopLoaded = true

if bhopConnection then
bhopConnection:Disconnect()
end
bhopConnection = RunService.Heartbeat:Connect(updateBhop)
applyBhopFriction()
end

unloadBhop = function()
if not bhopLoaded then return end

bhopLoaded = false

if bhopConnection then
bhopConnection:Disconnect()
bhopConnection = nil
end

getgenv().bhopHoldActive = false
resetBhopFriction()
end

checkBhopState = function()
shouldLoad = getgenv().autoJumpEnabled or getgenv().bhopHoldActive

if shouldLoad then
loadBhop()
else
unloadBhop()
end
end

reapplyBhopOnRespawn = function()
if getgenv().autoJumpEnabled or getgenv().bhopHoldActive then
wait(0.5)
applyBhopFriction()
checkBhopState()
end
end

setupJumpButton = function()
success, err = pcall(function()
touchGui = player:WaitForChild("PlayerGui", 5):WaitForChild("TouchGui", 5)
if not touchGui then return end
touchControlFrame = touchGui:WaitForChild("TouchControlFrame", 5)
if not touchControlFrame then return end
jumpButton = touchControlFrame:WaitForChild("JumpButton", 5)
if not jumpButton then return end

jumpButton.MouseButton1Down:Connect(function()
if featureStates.BhopHold then
getgenv().bhopHoldActive = true
checkBhopState()
end
end)

jumpButton.MouseButton1Up:Connect(function()
getgenv().bhopHoldActive = false
checkBhopState()
end)
end)
end

setupJumpButton()

RunService.Heartbeat:Connect(function()
   if not Character or not Character:IsDescendantOf(workspace) then
      Character = player.Character or player.CharacterAdded:Wait()
      if Character then
         Humanoid = Character:FindFirstChildOfClass("Humanoid")
         HumanoidRootPart = Character:FindFirstChild("HumanoidRootPart")
      else
         Humanoid = nil
         HumanoidRootPart = nil
      end
   end
end)

if characterConnection then
   characterConnection:Disconnect()
end
characterConnection = player.CharacterAdded:Connect(function(character)
   Character = character
   Humanoid = character:WaitForChild("Humanoid")
   HumanoidRootPart = character:WaitForChild("HumanoidRootPart")
   setupJumpButton()
   reapplyBhopOnRespawn()
end)

MovementTab:CreateSection("Bhop / Bunny Hop")

local AutoJumpTypeDropdown = MovementTab:CreateDropdown({
   Name = "Auto Jump Type",
   Options = {"Bounce", "Realistic"},
   CurrentOption = {"Bounce"},
   MultipleOptions = false,
   Flag = "AutoJumpTypeDropdown",
   Callback = function(options)
      getgenv().autoJumpType = options[1]
   end
})

local BhopToggle = MovementTab:CreateToggle({
   Name = "Bhop",
   CurrentValue = false,
   Flag = "BhopToggle",
   Callback = function(state)
      featureStates.Bhop = state
      getgenv().autoJumpEnabled = state
      checkBhopState()
   end
})

local BhopHoldToggle = MovementTab:CreateToggle({
   Name = "Bhop (Hold Space/Jump)",
   CurrentValue = false,
   Flag = "BhopHoldToggle",
   Callback = function(state)
      featureStates.BhopHold = state
      if not state then
         getgenv().bhopHoldActive = false
         checkBhopState()
      end
   end
})

local BhopModeDropdown = MovementTab:CreateDropdown({
   Name = "Bhop Mode",
   Options = {"Acceleration", "No Acceleration"},
   CurrentOption = {"Acceleration"},
   MultipleOptions = false,
   Flag = "BhopModeDropdown",
   Callback = function(options)
      getgenv().bhopMode = options[1]
      checkBhopState()
   end
})

local BhopAccelInput = MovementTab:CreateInput({
   Name = "Bhop Acceleration (Negative Only)",
   CurrentValue = "-0.5",
   PlaceholderText = "-0.5",
   RemoveTextAfterFocusLost = false,
   Flag = "BhopAccelInput",
   Callback = function(value)
      if tostring(value):sub(1, 1) == "-" then
         local n = tonumber(value)
         if n then
            getgenv().bhopAccelValue = n
            if getgenv().autoJumpEnabled or getgenv().bhopHoldActive then
               applyBhopFriction()
            end
         end
      end
   end
})

local JumpCooldownInput = MovementTab:CreateInput({
   Name = "Jump Cooldown (Seconds)",
   CurrentValue = "0.7",
   PlaceholderText = "0.7",
   RemoveTextAfterFocusLost = false,
   Flag = "JumpCooldownInput",
   Callback = function(value)
      local n = tonumber(value)
      if n and n > 0 then
         getgenv().jumpCooldown = n
      end
   end
})