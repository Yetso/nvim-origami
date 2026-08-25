local ns = vim.api.nvim_create_namespace("origami.foldText")

---@alias Origami.VirtTextChunk {[1]: string, [2]?: string[]}

---@alias Origami.FoldtextComponentProvider fun(data: Origami.FoldtextRedrawData, foldstart: number, foldend: number): Origami.VirtTextChunk[]

---Data fetched once per window redraw and shared by all folds in it
---@class Origami.FoldtextRedrawData
---@field diagnostics vim.Diagnostic[]
---@field diagIcons string[]
---@field diagHls string[]
---@field diagIconSeparator string
---@field gitsignsHunks? table[] hunks from `gitsigns.get_hunks()`
---@field miniDiffHunks? table[] hunks from `MiniDiff.get_buf_data().hunks`

--------------------------------------------------------------------------------

vim.opt.fillchars:append { fold = " " }
do
	-- initialize in current window when lazy-loading `nvim-origami`
	for _, winid in pairs(vim.api.nvim_list_wins()) do
		vim.wo[winid].foldtext = "" -- keep syntax highlighting
	end
	-- override foldtext in new windows that set foldtext
	vim.api.nvim_create_autocmd("WinNew", {
		desc = "Origami: Set foldtext in all windows",
		callback = function(ctx)
			local winid = vim.fn.bufwinid(ctx.buf)
			vim.wo[winid].foldtext = ""
		end,
	})
end

--------------------------------------------------------------------------------

---@param buf number
---@param config Origami.config
---@return Origami.FoldtextRedrawData
local function getRedrawData(buf, config)
	local data = { ---@type Origami.FoldtextRedrawData
		diagnostics = {},
		diagIcons = { "E", "W", "I", "H" },
		diagHls = { "DiagnosticError", "DiagnosticWarn", "DiagnosticInfo", "DiagnosticHint" },
		diagIconSeparator = config.foldtext.diagnosticsIconSeparator,
	}

	local diagnosticsEnabled = vim.diagnostic.is_enabled { bufnr = buf }
	if config.foldtext.diagnosticsCount and diagnosticsEnabled then
		data.diagnostics = vim.diagnostic.get(buf)

		-- get config from `vim.diagnostic.config`
		local signConfig = vim.diagnostic.config().signs
		if type(signConfig) == "function" then signConfig = signConfig(_, buf) end -- see #24
		if type(signConfig) == "table" then
			data.diagIcons = signConfig.text or data.diagIcons
			data.diagHls = signConfig.linehl or data.diagHls
		end
	end

	-- checked on every redraw, so git plugins loaded after `nvim-origami` are used
	if config.foldtext.gitsignsCount then
		local gitsignsInstalled, gitsigns = pcall(require, "gitsigns")
		local minidiffInstalled, MiniDiff = pcall(require, "mini.diff")
		if gitsignsInstalled then
			data.gitsignsHunks = gitsigns.get_hunks(buf) or {}
		elseif minidiffInstalled then
			local bufData = MiniDiff.get_buf_data(buf)
			data.miniDiffHunks = bufData and bufData.hunks or {}
		end
	end

	return data
end

---@type Origami.FoldtextComponentProvider
local function getDiagnosticsInFold(data, foldstart, foldend)
	-- get count by severity in the folded lines
	local diagsInFold = {
		[vim.diagnostic.severity.ERROR] = 0,
		[vim.diagnostic.severity.WARN] = 0,
		[vim.diagnostic.severity.INFO] = 0,
		[vim.diagnostic.severity.HINT] = 0,
	}
	for _, diag in ipairs(data.diagnostics) do
		local lnum = diag.lnum + 1
		if lnum > foldstart and lnum <= foldend then -- exclude 1st folded line since still visible
			diagsInFold[diag.severity] = diagsInFold[diag.severity] + 1
		end
	end

	-- convert count info into virtual text table for `set_extmark`
	local chunks = {} ---@type Origami.VirtTextChunk[]
	for severity, count in ipairs(diagsInFold) do
		if count > 0 then
			table.insert(chunks, { " " }) -- separate, so the padding does not get hlgroup
			local text = data.diagIcons[severity] .. data.diagIconSeparator .. count
			table.insert(chunks, { text, { data.diagHls[severity] } })
		end
	end
	return chunks
end

---@type Origami.FoldtextComponentProvider
local function getGitHunksInFold(data, foldstart, foldend)
	local typeIcons = { change = "~", delete = "-", add = "+" }
	local typeHls = { change = "GitSignsChange", delete = "GitSignsDelete", add = "GitSignsAdd" }

	-- get count by type in the folded lines: for deletions check if deletion is
	-- in the fold, for additions/changes, calculate the overlap of hunk and fold
	local hunksInFold = { change = 0, delete = 0, add = 0 }
	for _, h in ipairs(data.gitsignsHunks) do
		if h.type == "delete" then
			local deletionLine = h.added.start -- SIC even for deletions, correctly shifted line is in `.added`
			local isInFold = deletionLine >= foldstart and deletionLine <= foldend
			if isInFold then hunksInFold["delete"] = hunksInFold["delete"] + h.removed.count end
		else
			local hunkStart = h.added.start
			local hunkEnd = hunkStart - 1 + h.added.count
			local overlapStart = math.max(foldstart + 1, hunkStart) -- + 1 since 1st folded line still visible
			local overlapEnd = math.min(foldend, hunkEnd)
			local overlap = overlapEnd - overlapStart + 1
			if overlap > 0 then hunksInFold[h.type] = hunksInFold[h.type] + overlap end
		end
	end

	-- convert count info into virtual text table for `set_extmark`
	local chunks = {} ---@type Origami.VirtTextChunk[]
	for _, type in pairs { "add", "change", "delete" } do
		if hunksInFold[type] > 0 then
			table.insert(chunks, { " " }) -- separate, so the padding does not get hlgroup
			local text = typeIcons[type] .. hunksInFold[type]
			table.insert(chunks, { text, { typeHls[type] } })
		end
	end

	return chunks
end

---@type Origami.FoldtextComponentProvider
local function getGitHunksInFoldWithMiniDiff(data, foldstart, foldend)
	local typeIcons = { change = "~", delete = "-", add = "+" }
	local typeHls =
		{ change = "MiniDiffSignChange", delete = "MiniDiffSignDelete", add = "MiniDiffSignAdd" }

	-- get count by type in the folded lines: for deletions check if deletion is
	-- in the fold, for additions/changes, calculate the overlap of hunk and fold
	local hunksInFold = { change = 0, delete = 0, add = 0 }
	for _, h in ipairs(data.miniDiffHunks) do
		if h.type == "delete" then
			local deletionLine = h.buf_start > 0 and h.buf_start or 1
			local isInFold = deletionLine >= foldstart and deletionLine <= foldend
			if isInFold then hunksInFold["delete"] = hunksInFold["delete"] + h.ref_count end
		else
			local hunkStart = h.buf_start
			local hunkEnd = hunkStart - 1 + h.buf_count
			local overlapStart = math.max(foldstart + 1, hunkStart)
			local overlapEnd = math.min(foldend, hunkEnd)
			local overlap = overlapEnd - overlapStart + 1
			if overlap > 0 then hunksInFold[h.type] = hunksInFold[h.type] + overlap end
		end
	end

	-- Convert counts into virtual text chunks for `set_extmark`
	local chunks = {} ---@type Origami.VirtTextChunk[]
	for _, typ in ipairs { "add", "change", "delete" } do
		if hunksInFold[typ] > 0 then
			table.insert(chunks, { " " }) -- separate, so the padding does not get hlgroup
			local text = typeIcons[typ] .. hunksInFold[typ]
			table.insert(chunks, { text, { typeHls[typ] } })
		end
	end

	return chunks
end
--------------------------------------------------------------------------------

---@param win number
---@param buf number
---@param foldstart number
---@param leftcol number
---@param data Origami.FoldtextRedrawData
---@return number foldend
local function renderFoldedSegments(win, buf, foldstart, leftcol, data)
	local config = require("origami.config").config
	local foldend = vim.fn.foldclosedend(foldstart)

	-- get virtual text components
	local lineCountText = config.foldtext.lineCount.template:format(foldend - foldstart)
	local virtText = { ---@type Origami.VirtTextChunk[]
		{ lineCountText, { config.foldtext.lineCount.hlgroup } },
	}
	if config.foldtext.diagnosticsCount then
		local diagnostics = getDiagnosticsInFold(data, foldstart, foldend)
		if #diagnostics > 0 then table.insert(virtText, { " " }) end
		vim.list_extend(virtText, diagnostics)
	end
	if config.foldtext.gitsignsCount then
		local hunks = {} ---@type Origami.VirtTextChunk[]
		if data.gitsignsHunks then
			hunks = getGitHunksInFold(data, foldstart, foldend)
		elseif data.miniDiffHunks then
			hunks = getGitHunksInFoldWithMiniDiff(data, foldstart, foldend)
		end
		if #hunks > 0 then table.insert(virtText, { " " }) end
		vim.list_extend(virtText, hunks)
	end
	local padding = config.foldtext.padding.width
	if type(padding) == "function" then
		local currentVirtualTextLength = 0
		for _, inner in ipairs(virtText) do
			currentVirtualTextLength = currentVirtualTextLength + #inner[1]
		end
		padding = padding(win, foldstart, currentVirtualTextLength)
	end
	table.insert(virtText, 1, {
		(config.foldtext.padding.character):rep(padding),
		config.foldtext.padding.hlgroup,
	})

	-- add text as extmark (`virtcol` of `$` is one past the end of the line)
	local wincol = math.max(0, vim.fn.virtcol { foldstart, "$" } - 1 - leftcol)

	vim.api.nvim_buf_set_extmark(buf, ns, foldstart - 1, 0, {
		virt_text = virtText,
		virt_text_win_col = wincol,
		hl_mode = "combine",
		ephemeral = true, -- only for decorators in a redraw cycle
		priority = config.foldtext.priority,
	})

	return foldend
end

vim.api.nvim_set_decoration_provider(ns, {
	on_win = function(_, win, buf, topline, botline)
		local config = require("origami.config").config
		if vim.list_contains(config.foldtext.disableOnFt, vim.bo[buf].filetype) then return end

		local wininfo = vim.fn.getwininfo(win)[1]
		local leftcol = wininfo and wininfo.leftcol or 0 ---@diagnostic disable-line: undefined-field
		local data ---@type Origami.FoldtextRedrawData? only fetched if there is a closed fold

		vim.api.nvim_win_call(win, function()
			local line = topline
			while line <= botline do
				local foldstart = vim.fn.foldclosed(line)
				if foldstart > -1 then
					data = data or getRedrawData(buf, config)
					line = renderFoldedSegments(win, buf, foldstart, leftcol, data)
				end
				line = line + 1
			end
		end)
	end,
})

--------------------------------------------------------------------------------
