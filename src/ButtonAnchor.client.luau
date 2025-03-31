-- (c) 2025 metatable.dev, all rights reserved.

local TweenService = game:GetService("TweenService")

local function getCanvasY(target: GuiObject, scrollFrame: ScrollingFrame): number
	if not target or not target:IsDescendantOf(scrollFrame) then
		return 0
	end

	return target.AbsolutePosition.Y - scrollFrame.AbsolutePosition.Y + scrollFrame.CanvasPosition.Y
end

local button = script.Parent
local label = button.Parent
local scrollFrame = label.Parent
local mapLabel = scrollFrame:FindFirstChild(button.Name)

button.MouseButton1Click:Connect(function()
	assert(mapLabel, "Target label not found for id: " .. button.Name)

	local stroke = mapLabel:FindFirstChildWhichIsA("UIStroke")

	task.spawn(function()
		for i = 2, 0, -1 do
			stroke.Enabled = true
			task.wait(1)
			stroke.Enabled = false
			task.wait(0.25)
		end

		stroke.Enabled = false
	end)

	task.defer(function()
		TweenService:Create(scrollFrame, TweenInfo.new(.25), {
			CanvasPosition = Vector2.new(0, getCanvasY(mapLabel, scrollFrame))
		}):Play()
	end)
end)
