--[[
(c) 2025 metatable.dev, all rights reserved.

Description:
  Parses Google Docs HTML exports and renders them as Roblox GUI elements inside a container.

-- Usage:
  local Parse = require(path.to.this.module)
  local guiObject = script.Parent Any GuiObject (e.g., Frame)
  local parserInstance = Parse.new("GOOGLE_DOC_ID", guiObject)

-- Supported Tags:
  - <h1> to <h6>: Renders as headers with different font sizes.
  - <p>, <div>: Paragraph/block text.
  - <ul>, <ol>, <li>: Lists with automatic bullet/numbering support.
  - <img>: External image rendering with size adjustment.
  - <font>, <b>, <i>, <u>, <br>, <a>: RichText styling and links.

-- Features:
  - Parses inline class/style colors from <style> blocks.
  - Replaces common HTML entities (e.g., &nbsp;, &ldquo;).
  - Assigns color and font mapping based on Google Docs export styling.
  - Preserves anchor tags as underlined blue text.
  - Supports clickable internal links that scroll to elements with matching id="..."

-- Limitations:
  - Does not yet support nested lists, hyperlinks, or tables.
  - Only certain inline tags preserved in RichText.

  Requires LuauImageParser (https://github.com/Metatable-Games/LuauImageParser/tree/main) to render images.
]]

local HttpService = game:GetService("HttpService")

local Module = {}
Module.__index = Module

type Element = {
	tag: string,
	attributes: string,
	content: string,
	pos: number,
	src: string?,
}

type ClassColorMap = { [string]: string }
type TagColorMap = { [string]: string }

local VERSION = "v1"
local containerPadding = 12
local defaultSize = 18
local maxImageWidth = 600

local defaultFont = Enum.Font.SourceSans -- Default font for text elements if not specified in the document.
local fontMap: { [string]: Enum.Font } = {
	["Arial"] = Enum.Font.SourceSans,
	["Verdana"] = Enum.Font.SourceSans,
	["Helvetica"] = Enum.Font.SourceSans,
	["Georgia"] = Enum.Font.Gotham,
	["Times New Roman"] = Enum.Font.Gotham,
}

local headerSizeMap: { [string]: number } = {
	h1 = 36,
	h2 = 32,
	h3 = 28,
	h4 = 24,
	h5 = 20,
	h6 = 18,
}

local function applySpanClassesToColors(text: string, classColorMap: ClassColorMap): string
	local iterations = 0
	local changed = true

	while changed and iterations < 5 do
		changed = false
		text, changed = text:gsub(
			'<span[^>]*class="([^"]+)"[^>]*>(.-)</span>',
			function(classAttr: string, inner: string): string
				for c in classAttr:gmatch("%S+") do
					local color = classColorMap[c]
					if color then
						return '<font color="' .. color .. '">' .. inner .. "</font>"
					end
				end
				return inner
			end
		)
		iterations += 1
	end

	return text
end

local function getElementClasses(attributes: string): { string }
	local classAttr = attributes:match('%s+class="([^"]+)"')
	if not classAttr then
		return {}
	end

	local classes: { string } = {}
	for c in classAttr:gmatch("%S+") do
		table.insert(classes, c)
	end
	return classes
end

local function parseElements(bodyContent: string): { Element }
	local elements: { Element } = {}

	for startPos, tag, attributes, content in bodyContent:gmatch("()<(%w+)([^>]*)>(.-)</%2>()") do
		if tag:lower() == "img" then
			continue
		end

		table.insert(elements, {
			tag = tag:lower(),
			attributes = attributes,
			content = content,
			pos = startPos,
		})
	end

	for startPos, attributes in bodyContent:gmatch("()<img%s+(.-)/?>") do
		local src = attributes:match('src="(.-)"') or ""
		table.insert(elements, {
			tag = "img",
			attributes = attributes,
			content = "",
			src = src,
			pos = startPos,
		})
	end

	-- Support <hr> as a special divider
	for startPos in bodyContent:gmatch("()<hr%s*/?>") do
		table.insert(elements, {
			tag = "hr",
			attributes = "",
			content = "",
			pos = startPos,
		})
	end

	table.sort(elements, function(a: Element, b: Element): boolean
		return a.pos < b.pos
	end)

	return elements
end

local function getImageDimensions(attributes: string): (number?, number?)
	return tonumber(attributes:match("width%s*=%s*[\"'](%d+)")), tonumber(attributes:match("height%s*=%s*[\"'](%d+)"))
end

local function parseGlobalStyles(html: string): (TagColorMap, ClassColorMap)
	local tagColorMap: TagColorMap = {}
	local classColorMap: ClassColorMap = {}

	for styleBlock in html:gmatch("<style[^>]*>(.-)</style>") do
		for selector, colorHex in styleBlock:gmatch("([%w%.]+)%s*%{[^}]*color:%s*(#[0-9A-Fa-f]+)") do
			if selector:sub(1, 1) == "." then
				classColorMap[selector:sub(2):lower()] = colorHex
			else
				tagColorMap[selector:lower()] = colorHex
			end
		end
	end

	return tagColorMap, classColorMap
end

local function extractBody(html: string): string?
	return html:match("<body[^>]*>(.-)</body>")
end

local function replaceEntities(text: string): string
	return text:gsub("&nbsp;", " ")
		:gsub("&lspquo;", "‘")
		:gsub("&lsquo;", "‘")
		:gsub("&rsquo;", "’")
		:gsub("&ldquo;", "“")
		:gsub("&rdquo;", "”")
		:gsub("&hellip;", "…")
end

local function cleanText(text: string, classColorMap: ClassColorMap): string
	text = applySpanClassesToColors(text, classColorMap)
	text = replaceEntities(text)

	-- Support <b>, <i>, <u>, <font>, <br>, <a>, strip others
	text = text:gsub("<(/?)(%w+)(.-)>", function(closing, tag, rest)
		tag = tag:lower()
		if tag == "font" or tag == "b" or tag == "i" or tag == "u" or tag == "br" or tag == "a" then
			return "<" .. closing .. tag .. rest .. ">"
		end
		return ""
	end)

	text = text:gsub("%s+", " "):gsub("^%s+", ""):gsub("%s+$", "")
	return text
end

local function getFontFromAttributes(attributes: string): Enum.Font?
	local fontFace = attributes:match("font%-family:%s*[\"']?([^;\"']+)")

	if fontFace then
		return fontMap[fontFace]
	end

	return defaultFont
end

function Module.new(documentId: string, container: GuiObject): any
	local startTick = tick()
	assert(documentId ~= "", "documentId must be a non-empty string.")
	assert(container:IsA("GuiObject"), "container must be a valid GuiObject.")

	local self = setmetatable({}, Module)
	self.documentId = documentId
	self.container = container

	local success, html = pcall(function()
		return HttpService:GetAsync(
			self.documentId and ("https://docs.google.com/document/d/%s/export?format=html"):format(documentId)
		)
	end)

	assert(success and html, "Failed to fetch document contents.")
	self.documentContents = html

	self.tagColorMap, self.classColorMap = parseGlobalStyles(self.documentContents)
	self.documentBody = extractBody(self.documentContents)
	assert(self.documentBody, "Failed to extract body.")

	self.documentElements = parseElements(self.documentBody)
	assert(#self.documentElements > 0, "No valid elements found.")

	local scrollFrame = Instance.new("ScrollingFrame")
	scrollFrame.Name = "ContentFrame"
	scrollFrame.Size = UDim2.new(1, 0, 1, 0)
	scrollFrame.Position = UDim2.new(0.5, 0, 0.5, 0)
	scrollFrame.AnchorPoint = Vector2.new(0.5, 0.5)
	scrollFrame.BackgroundTransparency = 1
	scrollFrame.ScrollBarImageColor3 = Color3.fromRGB(0, 0, 0)
	scrollFrame.BorderSizePixel = 0
	scrollFrame.ScrollBarThickness = 8
	scrollFrame.CanvasSize = UDim2.new(0, 0, 0, 0)
    scrollFrame.AutomaticCanvasSize = Enum.AutomaticSize.Y
	scrollFrame.Parent = container

	local layout = Instance.new("UIListLayout")
	layout.SortOrder = Enum.SortOrder.LayoutOrder
	layout.Parent = scrollFrame

	local UIPadding = Instance.new("UIPadding")
	UIPadding.PaddingBottom = UDim.new(0, containerPadding)
	UIPadding.PaddingTop = UDim.new(0, containerPadding)
	UIPadding.PaddingLeft = UDim.new(0, containerPadding)
	UIPadding.PaddingRight = UDim.new(0, containerPadding)
	UIPadding.Parent = scrollFrame

	self.anchorMap = {} :: { [string]: TextLabel }
	self.anchorHref = {} :: { [string]: TextLabel }

	for _, elem in ipairs(self.documentElements) do
		if elem.tag == "hr" then
			local divider = Instance.new("Frame")
			divider.Name = "Divider"
			divider.Size = UDim2.new(1, -24, 0, 1)
			divider.BackgroundColor3 = Color3.fromRGB(180, 180, 180)
			divider.BorderSizePixel = 0
			divider.LayoutOrder = elem.pos
			divider.Parent = scrollFrame
			continue
		end

		if elem.tag == "img" then
			if elem.src and elem.src:match("^https://docs%.google%.com/drawings/") then
				warn(
					"[GoogleDocsParser] Skipping unsupported Google Drawings image: "
						.. elem.src
						.. ". This is not supported in the viewer as Google blocks it's Http Requests."
				)
				continue
			end

			local imageLabel = Instance.new("ImageLabel")
			imageLabel.Name = "ImagePlaceholder"

			local imgWidth, imgHeight = getImageDimensions(elem.attributes)
			imgWidth = math.min(imgWidth or maxImageWidth, maxImageWidth)
			imgHeight = imgHeight or 200

			imageLabel.Size = UDim2.new(0, imgWidth, 0, imgHeight)
			imageLabel.BackgroundColor3 = Color3.new(0.9, 0.9, 0.9)
			imageLabel.BorderSizePixel = 0
			imageLabel.LayoutOrder = elem.pos
			imageLabel:SetAttribute("ExternalImageURL", elem.src)
			imageLabel:AddTag("ExternalImage")
			imageLabel.Parent = scrollFrame
			continue
		end
		local labelHrefId

		for hrefId in elem.content:gmatch('<a[^>]-href="#([^"]+)"') do
			labelHrefId = hrefId
			break
		end

		local text = cleanText(elem.content, self.classColorMap)

		local tagColor = self.tagColorMap[elem.tag]
		local classes = getElementClasses(elem.attributes)

		local classColor: string? = nil
		for _, c in ipairs(classes) do
			classColor = self.classColorMap[c]
			if classColor then
				break
			end
		end

		local color = classColor or tagColor
		if color then
			text = '<font color="' .. color .. '">' .. text .. "</font>"
		end

		local size = headerSizeMap[elem.tag] or defaultSize
		local richText = ""
		local isListItem = elem.tag == "li"
		local prefix = ""

		-- Check if it's part of an ordered or unordered list
		if isListItem then
			-- Walk backwards to find parent ul/ol
			local listType = "•"

			for i = _, 1, -1 do
				local prev = self.documentElements[i]
				if prev.tag == "ul" then
					listType = "•"
					break
				elseif prev.tag == "ol" then
					listType = tostring(i) .. "."
					break
				end
			end

			prefix = listType .. " "
		end

		if elem.tag:match("^h%d") then
			richText = '\n<b><font size="' .. size .. '">' .. text .. "</font></b>\n"
		elseif elem.tag == "p" or elem.tag == "div" or elem.tag == "ul" or elem.tag == "ol" then
			richText = '\n<font size="' .. size .. '">' .. text .. "</font>\n"
		elseif isListItem then
			richText = "\n" .. prefix .. '<font size="' .. size .. '">' .. text .. "</font>"
		end

		local textLabel = Instance.new("TextLabel")

		-- This will make the text underlined and blue to indicate it's a link.
		if labelHrefId then
			if richText:match('<font color="[^"]+">') then
				-- If there's already a font color, we need to replace it with blue for the link.
				richText = richText:gsub('<font color="[^"]+">', '<font color="#3366cc">')
			else
				-- If no font color, just add the blue font color for the link.
				richText = '<font color="#3366cc">' .. text .. "</font>"
			end

			richText = ("<u>%s</u>"):format(richText)
		end

		textLabel.Name = "TextElement"
		textLabel.Size = UDim2.new(1, 0, 0, 0)
		textLabel.AutomaticSize = Enum.AutomaticSize.Y
		textLabel.TextSize = 5
		textLabel.Text = richText
		textLabel.RichText = true
		textLabel.TextWrapped = true
		textLabel.TextXAlignment = Enum.TextXAlignment.Left
		textLabel.TextYAlignment = Enum.TextYAlignment.Top
		textLabel.BackgroundTransparency = 1
		textLabel.TextScaled = false
		textLabel.LayoutOrder = elem.pos
		textLabel.Font = getFontFromAttributes(elem.attributes)
		textLabel.Parent = scrollFrame

		-- Register the text label in the anchor map if it has an id attribute.
		-- This allows us to create clickable links that scroll to the corresponding element.
		if elem.attributes:find('id="([^"]+)"') then
			local anchorId = elem.attributes:match('id="([^"]+)"')
			self.anchorMap[anchorId] = textLabel
			textLabel.Name = anchorId

			local UIStroke = Instance.new("UIStroke")
			UIStroke.Enabled = false
			UIStroke.Parent = textLabel
			UIStroke.Thickness = 1.5
			UIStroke.Color = Color3.fromRGB(51, 102, 204)
			UIStroke.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
		end

		-- "Button" to move to the anchor point if it has href="#..."
		if labelHrefId then
			-- Array to support multiple hrefs/buttons.
			table.insert(self.anchorHref, {
				id = labelHrefId,
				label = textLabel,
			})
		end
	end

	for _, data in pairs(self.anchorHref) do
		local button = Instance.new("TextButton")
		button.Size = UDim2.new(1, 0, 1.25, 0)
		button.Position = UDim2.new(0, 0, 0, 0)
		button.BackgroundTransparency = 1
		button.Text = ""
		button.Name = data.id
		button.ZIndex = data.label.ZIndex + 1
		button.Parent = data.label

		local ButtonAnchor = script.ButtonAnchor:Clone()
		ButtonAnchor.Parent = button
		ButtonAnchor.Enabled = true
	end

	do
		local textLabel = Instance.new("TextLabel")
		textLabel.Name = "TextElement"
		textLabel.Size = UDim2.new(1, 0, 0, 0)
		textLabel.AutomaticSize = Enum.AutomaticSize.Y
		textLabel.TextSize = 18
		textLabel.Text = ("Rendered by Roblox Google Docs Viewer (%s) by metatable in <b>%.2f secs</b>."):format(
			VERSION,
            tick() - startTick
		)
		textLabel.RichText = true
		textLabel.TextWrapped = true
		textLabel.TextXAlignment = Enum.TextXAlignment.Left
		textLabel.TextYAlignment = Enum.TextYAlignment.Top
		textLabel.BackgroundTransparency = 1
		textLabel.TextScaled = false
		textLabel.LayoutOrder = 99999999
		textLabel.Font = defaultFont
		textLabel.Parent = scrollFrame
	end

	scrollFrame.CanvasSize = UDim2.new(0, 0, 0, layout.AbsoluteContentSize.Y)

	return self
end

return Module
