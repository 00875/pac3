local urltex = {}

urltex.TextureSize = 1024
urltex.ActivePanel = urltex.ActivePanel or NULL
urltex.Queue = urltex.Queue or {}
urltex.Cache = urltex.Cache or {}
urltex.CacheManager = DLib.CacheManager('pac3_urltex', 512 * 0x00100000)

concommand.Add("pac_urltex_clear_cache", function()
	urltex.Cache = {}
	urltex.Queue = {}
end)

if urltex.ActivePanel:IsValid() then
	urltex.ActivePanel:Remove()
end

local enable = CreateClientConVar("pac_enable_urltex", "1", true)
local EMPTY_FUNC = function() end

local function findFlag(url, flagID)
	local startPos, endPos = url:find(flagID)
	if not startPos then return url, false end

	if url:sub(endPos + 1, endPos + 1) == ' ' or url:sub(startPos - 1, startPos - 1) == ' ' then
		url = url:gsub(' ?' .. flagID .. ' ?', '')
		return url, true
	end

	return url, false
end

function urltex.GetMaterialFromURL(url, callback, skip_cache, shader, size, size_hack, additionalData)
	if size_hack == nil then
		size_hack = true
	end

	if size == nil then
		size = urltex.TextureSize
	end

	additionalData = additionalData or {}
	shader = shader or "VertexLitGeneric"
	if not enable:GetBool() then return end

	local noclampS, noclamp, noclampT

	url, noclampS = findFlag(url, 'noclamps')
	url, noclampT = findFlag(url, 'noclampt')
	url, noclamp = findFlag(url, 'noclamp')

	local hash = DLib.Util.QuickSHA1(url .. ' ' .. size)

	local urlAddress = url
	local urlIndex = url

	if noclamp then
		urlIndex = urlIndex .. ' noclamp'
	elseif noclampS then
		urlIndex = urlIndex .. ' noclampS'
	elseif noclampT then
		urlIndex = urlIndex .. ' noclampT'
	end

	noclamp = noclamp or noclampS and noclampT

	local renderTargetNeeded =
		noclampS or
		noclamp or
		noclampT

	if type(callback) == "function" and not skip_cache and urltex.Cache[urlIndex] then
		local tex = urltex.Cache[urlIndex]
		local mat = CreateMaterial("pac3_urltex_" .. DLib.Util.QuickSHA1(url .. SysTime()), shader, additionalData)
		mat:SetTexture("$basetexture", tex)
		callback(mat, tex)
		return
	end

	callback = callback or EMPTY_FUNC

	if urltex.Queue[urlIndex] then
		table.insert(urltex.Queue[urlIndex].callbacks, callback)
	else
		urltex.Queue[urlIndex] = {
			url = urlAddress,
			urlIndex = urlIndex,
			hash = hash,
			callbacks = {callback},
			tries = 0,
			size = size,
			size_hack = size_hack,
			shader = shader,
			noclampS = noclampS,
			noclampT = noclampT,
			noclamp = noclamp,
			rt = renderTargetNeeded,
			additionalData = additionalData
		}
	end
end

function urltex.Think()
	if not pac.IsEnabled() then return end

	if table.Count(urltex.Queue) > 0 then
		for url, data in pairs(urltex.Queue) do
			-- when the panel is gone start a new one
			if not urltex.ActivePanel:IsValid() then
				urltex.StartDownload(data.url, data)
			end
		end

		urltex.Busy = true
	else
		urltex.Busy = false
	end
end

timer.Create("urltex_queue", 0.1, 0, urltex.Think)

function urltex.StartDownload(url, data)
	if urltex.ActivePanel:IsValid() then
		urltex.ActivePanel:Remove()
	end

	url = pac.FixUrl(url)

	local size = data.size or urltex.TextureSize
	local id = "urltex_download_" .. url
	local pnl
	local frames_passed = 0

	local function createDownloadPanel()
		frames_passed = 0

		pnl = vgui.Create("DHTML")
		-- Tested in PPM/2, this code works perfectly
		pnl:SetVisible(false)
		pnl:SetSize(size, size)
		pnl:SetHTML([[<html>
				<head>
				<style type="text/css">
					html
					{
						overflow:hidden;
						]] .. (data.size_hack and "margin: -8px -8px;" or "margin: 0px 0px;") .. [[
					}
				</style>
				<script>
					window.onload = function() {
						setInterval(function() {
							console.log('REAL_FRAME_PASSED');
						}, 50);
					};
				</script>
				</head>

				<body>
					<img src="]] .. url .. [[" alt="" width="]] .. size .. [[" height="]] .. size .. [[" />
				</body>
			</html>]])

		pnl:Refresh()

		function pnl:ConsoleMessage(msg)
			if msg == 'REAL_FRAME_PASSED' then
				frames_passed = frames_passed + 1
			end
		end

		urltex.ActivePanel = pnl
	end

	local time = 0
	local timeoutNum = 0

	local function onTimeout()
		timeoutNum = timeoutNum + 1

		if IsValid(pnl) then pnl:Remove() end

		if timeoutNum < 5 then
			pac.dprint("material download %q timed out.. trying again for the %ith time", url, timeoutNum)
			-- try again
			createDownloadPanel()
		else
			pac.dprint("material download %q timed out for good", url, timeoutNum)
			hook.Remove("Think", id)
			timer.Remove(id)
			urltex.Queue[data.urlIndex] = nil
		end
	end

	local function think()
		::START::

		-- panel is no longer valid
		if not pnl:IsValid() then
			onTimeout()
			goto START
		end

		while pnl:IsLoading() do
			coroutine.yield()
		end

		while frames_passed < 20 do
			coroutine.yield()
		end

		coroutine.syswait(1)

		pnl:UpdateHTMLTexture()
		local html_mat = pnl:GetHTMLMaterial()

		local attempts = 0

		while not html_mat and attempts < 200 do
			attempts = attempts + 1
			pnl:UpdateHTMLTexture()
			html_mat = pnl:GetHTMLMaterial()
		end

		if not html_mat then return end

		local crc = DLib.Util.QuickSHA1(data.urlIndex .. SysTime())
		local vertex_mat = CreateMaterial("pac3_urltex_" .. crc, data.shader, data.additionalData)
		local tex = html_mat:GetTexture("$basetexture")

		tex:Download()
		vertex_mat:SetTexture("$basetexture", tex)

		urltex.Cache[data.urlIndex] = tex

		timer.Remove(id)

		urltex.Queue[data.urlIndex] = nil

		if data.rt then
			local textureFlags = 0
			textureFlags = textureFlags + 4 -- clamp S
			textureFlags = textureFlags + 8 -- clamp T
			textureFlags = textureFlags + 16 -- anisotropic
			textureFlags = textureFlags + 256 -- no mipmaps
			-- textureFlags = textureFlags + 2048 -- Texture is procedural
			textureFlags = textureFlags + 32768 -- Texture is a render target
			-- textureFlags = textureFlags + 67108864 -- Usable as a vertex texture

			if data.noclamp then
				textureFlags = textureFlags - 4
				textureFlags = textureFlags - 8
			elseif data.noclampS then
				textureFlags = textureFlags - 4
			elseif data.noclampT then
				textureFlags = textureFlags - 8
			end

			local vertex_mat2 = CreateMaterial("pac3_urltex_" .. crc .. "_hack", 'UnlitGeneric', data.additionalData)
			vertex_mat2:SetTexture("$basetexture", tex)

			local rt = GetRenderTargetEx("pac3_urltex_" .. crc, size, size, RT_SIZE_NO_CHANGE, MATERIAL_RT_DEPTH_NONE, textureFlags, CREATERENDERTARGETFLAGS_UNFILTERABLE_OK, IMAGE_FORMAT_RGB888)

			render.PushRenderTarget(rt)
			render.Clear(0, 0, 0, 255, false, false)

			cam.Start2D()
			surface.SetMaterial(vertex_mat2)
			surface.SetDrawColor(255, 255, 255)
			surface.DrawTexturedRect(0, 0, size, size)
			cam.End2D()

			render.PopRenderTarget()
			vertex_mat:SetTexture('$basetexture', rt)

			urltex.Cache[data.urlIndex] = rt
		end

		timer.Simple(0, function()
			pnl:Remove()
		end)

		if data.callbacks then
			for i, callback in pairs(data.callbacks) do
				callback(vertex_mat, rt or tex)
			end
		end
	end

	local thread = coroutine.create(think)

	pac.AddHook("Think", id, function()
		local status, err = coroutine.resume(thread)

		if not status then
			pac.RemoveHook("Think", id)
			error(err)
		end

		if coroutine.status(thread) == "dead" then
			pac.RemoveHook("Think", id)
		end
	end)

	-- 5 sec max timeout, 5 maximal timeouts
	timer.Create(id, 5, 5, onTimeout)
	createDownloadPanel()
end

return urltex
