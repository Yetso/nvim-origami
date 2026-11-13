local ns = vim.api.nvim_create_namespace("origami.foldText")

---@alias Origami.VirtTextChunk {[1]: string, [2]?: string[]}

---@alias Origami.FoldtextComponentProvider fun(data: Origami.FoldtextBufCache, foldstart: number, foldend: number): Origami.VirtTextChunk[]

---Diagnostics of a buffer, only rebuilt on `DiagnosticChanged`
---@class Origami.FoldtextDiagData
---@field lnums number[][] sorted 1-based line numbers, indexed by severity
---@field icons string[]
---@field hls string[]

---Virtual text of a fold, without the padding (which can depend on the window)
---@class Origami.FoldtextFoldCache
---@field foldend number
---@field chunks Origami.VirtTextChunk[]
---@field textLength number display width of all chunks
---@field virtText? Origami.VirtTextChunk[] `chunks` with the padding, if the padding is static

---Per-buffer cache, so redraws do not re-fetch and re-count everything
---@class Origami.FoldtextBufCache
---@field config Origami.config config the cache was built with
---@field diagnosticsEnabled? boolean
---@field diagnostics? Origami.FoldtextDiagData
---@field gitTick? number `changedtick` when the git hunks were fetched
---@field hunks? Origami.Hunk[] hunks from gitsigns or mini.diff, in a common format
---@field hunkHls? table<string, string> hlgroup per hunk type, matching the git plugin
---@field folds table<number, Origami.FoldtextFoldCache> indexed by foldstart

---Hunk of gitsigns or mini.diff, converted to one format so they are counted the same way
---@class Origami.Hunk
---@field type "add"|"change"|"delete"
---@field start number first line of the hunk in the buffer (for deletions: line the deletion is at)
---@field count number number of lines in the buffer
---@field removed number number of removed lines

---@type table<number, Origami.FoldtextBufCache>
local cache = {}

local hunkHls = {
	gitsigns = { change = "GitSignsChange", delete = "GitSignsDelete", add = "GitSignsAdd" },
	minidiff = { change = "MiniDiffSignChange", delete = "MiniDiffSignDelete", add = "MiniDiffSignAdd" },
}

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
-- CACHE INVALIDATION

local group = vim.api.nvim_create_augroup("origami.foldText", { clear = true })

vim.api.nvim_create_autocmd("DiagnosticChanged", {
	desc = "Origami: Invalidate cached diagnostics of foldtext",
	group = group,
	callback = function(ctx)
		local bufCache = cache[ctx.buf]
		if not bufCache then return end
		bufCache.diagnostics = nil
		bufCache.folds = {}
	end,
})

vim.api.nvim_create_autocmd("User", {
	desc = "Origami: Invalidate cached git hunks of foldtext",
	group = group,
	pattern = { "GitSignsUpdate", "MiniDiffUpdated" },
	callback = function(ctx)
		-- if the event does not tell which buffer was updated, invalidate all
		local buf = type(ctx.data) == "table" and (ctx.data.buffer or ctx.data.buf_id) or nil
		for b, bufCache in pairs(cache) do
			if not buf or b == buf then
				bufCache.gitTick = nil
				bufCache.folds = {}
			end
		end
	end,
})

vim.api.nvim_create_autocmd("BufWipeout", {
	desc = "Origami: Clear foldtext cache",
	group = group,
	callback = function(ctx) cache[ctx.buf] = nil end,
})

--------------------------------------------------------------------------------

---@param buf number
---@return Origami.FoldtextDiagData
local function getDiagData(buf)
	local data = { ---@type Origami.FoldtextDiagData
		lnums = { {}, {}, {}, {} },
		icons = { "E", "W", "I", "H" },
		hls = { "DiagnosticError", "DiagnosticWarn", "DiagnosticInfo", "DiagnosticHint" },
	}
	for _, diag in ipairs(vim.diagnostic.get(buf)) do
		local lnums = data.lnums[diag.severity]
		if lnums then lnums[#lnums + 1] = diag.lnum + 1 end
	end
	for _, lnums in ipairs(data.lnums) do
		table.sort(lnums)
	end

	-- get config from `vim.diagnostic.config`
	local signConfig = vim.diagnostic.config().signs
	if type(signConfig) == "function" then signConfig = signConfig(_, buf) end -- see #24
	if type(signConfig) == "table" then
		data.icons = signConfig.text or data.icons
		data.hls = signConfig.linehl or data.hls
	end
	return data
end

---Returns the cache of the buffer, re-fetching the data that is outdated.
---@param buf number
---@param config Origami.config
---@return Origami.FoldtextBufCache
local function getBufCache(buf, config)
	local bufCache = cache[buf]
	if not bufCache or bufCache.config ~= config then
		bufCache = { config = config, folds = {} }
		cache[buf] = bufCache
	end

	if config.foldtext.diagnosticsCount then
		-- toggling diagnostics does not necessarily trigger `DiagnosticChanged`
		local enabled = vim.diagnostic.is_enabled { bufnr = buf }
		if enabled ~= bufCache.diagnosticsEnabled then
			bufCache.diagnosticsEnabled = enabled
			bufCache.diagnostics = nil
			bufCache.folds = {}
		end
		if enabled and not bufCache.diagnostics then bufCache.diagnostics = getDiagData(buf) end
	end

	-- re-fetched on buffer changes and on updates of the git plugins, so git
	-- plugins loaded after `nvim-origami` are also used
	local tick = vim.api.nvim_buf_get_changedtick(buf)
	if config.foldtext.gitsignsCount and bufCache.gitTick ~= tick then
		bufCache.gitTick = tick
		bufCache.hunks, bufCache.hunkHls = nil, nil
		bufCache.folds = {}
		local gitsignsInstalled, gitsigns = pcall(require, "gitsigns")
		local minidiffInstalled, MiniDiff = pcall(require, "mini.diff")
		local hunks = {} ---@type Origami.Hunk[]
		if gitsignsInstalled then
			for _, h in ipairs(gitsigns.get_hunks(buf) or {}) do
				-- SIC even for deletions, correctly shifted line is in `.added`
				hunks[#hunks + 1] =
					{ type = h.type, start = h.added.start, count = h.added.count, removed = h.removed.count }
			end
			bufCache.hunks, bufCache.hunkHls = hunks, hunkHls.gitsigns
		elseif minidiffInstalled then
			local bufData = MiniDiff.get_buf_data(buf)
			for _, h in ipairs(bufData and bufData.hunks or {}) do
				-- deletions at the top of the file have `buf_start = 0`
				local start = (h.type == "delete" and h.buf_start == 0) and 1 or h.buf_start
				hunks[#hunks + 1] = { type = h.type, start = start, count = h.buf_count, removed = h.ref_count }
			end
			bufCache.hunks, bufCache.hunkHls = hunks, hunkHls.minidiff
		end
	end

	return bufCache
end

--------------------------------------------------------------------------------

---Number of items in the sorted list that are `<= value`
---@param list number[]
---@param value number
---@return number
local function countUpTo(list, value)
	local low, high = 1, #list + 1
	while low < high do
		local mid = math.floor((low + high) / 2)
		if list[mid] <= value then
			low = mid + 1
		else
			high = mid
		end
	end
	return low - 1
end

---@type Origami.FoldtextComponentProvider
local function getDiagnosticsInFold(data, foldstart, foldend)
	local diag = data.diagnostics
	if not diag then return {} end
	local separator = data.config.foldtext.diagnosticsIconSeparator

	-- get count by severity in the folded lines (excluding the 1st folded line,
	-- since it is still visible) and convert into virtual text for `set_extmark`
	local chunks = {} ---@type Origami.VirtTextChunk[]
	for severity, lnums in ipairs(diag.lnums) do
		local count = countUpTo(lnums, foldend) - countUpTo(lnums, foldstart)
		if count > 0 then
			table.insert(chunks, { " " }) -- separate, so the padding does not get hlgroup
			local text = diag.icons[severity] .. separator .. count
			table.insert(chunks, { text, { diag.hls[severity] } })
		end
	end
	return chunks
end

---@type Origami.FoldtextComponentProvider
local function getGitHunksInFold(data, foldstart, foldend)
	local typeIcons = { change = "~", delete = "-", add = "+" }

	-- get count by type in the folded lines: for deletions check if deletion is
	-- in the fold, for additions/changes, calculate the overlap of hunk and fold
	local hunksInFold = { change = 0, delete = 0, add = 0 }
	for _, h in ipairs(data.hunks) do
		if h.type == "delete" then
			local isInFold = h.start >= foldstart and h.start <= foldend
			if isInFold then hunksInFold.delete = hunksInFold.delete + h.removed end
		else
			local hunkEnd = h.start - 1 + h.count
			local overlapStart = math.max(foldstart + 1, h.start) -- + 1 since 1st folded line still visible
			local overlapEnd = math.min(foldend, hunkEnd)
			local overlap = overlapEnd - overlapStart + 1
			if overlap > 0 then hunksInFold[h.type] = hunksInFold[h.type] + overlap end
		end
	end

	-- convert count info into virtual text table for `set_extmark`
	local chunks = {} ---@type Origami.VirtTextChunk[]
	for _, typ in ipairs { "add", "change", "delete" } do
		if hunksInFold[typ] > 0 then
			table.insert(chunks, { " " }) -- separate, so the padding does not get hlgroup
			local text = typeIcons[typ] .. hunksInFold[typ]
			table.insert(chunks, { text, { data.hunkHls[typ] } })
		end
	end

	return chunks
end
--------------------------------------------------------------------------------

---Virtual text of the fold, cached until the fold, diagnostics, or hunks change
---@param data Origami.FoldtextBufCache
---@param foldstart number
---@param foldend number
---@return Origami.FoldtextFoldCache
local function getFoldCache(data, foldstart, foldend)
	local cached = data.folds[foldstart]
	if cached and cached.foldend == foldend then return cached end

	local config = data.config

	-- get virtual text components
	local lineCountText = config.foldtext.lineCount.template:format(foldend - foldstart)
	local chunks = { ---@type Origami.VirtTextChunk[]
		{ lineCountText, { config.foldtext.lineCount.hlgroup } },
	}
	if config.foldtext.diagnosticsCount then
		local diagnostics = getDiagnosticsInFold(data, foldstart, foldend)
		if #diagnostics > 0 then table.insert(chunks, { " " }) end
		vim.list_extend(chunks, diagnostics)
	end
	if config.foldtext.gitsignsCount then
		local hunks = data.hunks and getGitHunksInFold(data, foldstart, foldend) or {}
		if #hunks > 0 then table.insert(chunks, { " " }) end
		vim.list_extend(chunks, hunks)
	end

	local textLength = 0
	for _, chunk in ipairs(chunks) do
		textLength = textLength + vim.api.nvim_strwidth(chunk[1])
	end

	cached = { foldend = foldend, chunks = chunks, textLength = textLength }
	data.folds[foldstart] = cached
	return cached
end

---@param config Origami.config
---@param width number
---@param chunks Origami.VirtTextChunk[]
---@return Origami.VirtTextChunk[]
local function withPadding(config, width, chunks)
	local virtText = { ---@type Origami.VirtTextChunk[]
		{ (config.foldtext.padding.character):rep(width), config.foldtext.padding.hlgroup },
	}
	return vim.list_extend(virtText, chunks)
end

---@param win number
---@param buf number
---@param foldstart number
---@param leftcol number
---@param data Origami.FoldtextBufCache
---@return number foldend
local function renderFoldedSegments(win, buf, foldstart, leftcol, data)
	local config = data.config
	local foldend = vim.fn.foldclosedend(foldstart)
	local fold = getFoldCache(data, foldstart, foldend)

	local padding = config.foldtext.padding.width
	local virtText = fold.virtText
	if type(padding) == "function" then
		-- not cached, since the user function can depend on the window
		virtText = withPadding(config, padding(win, foldstart, fold.textLength), fold.chunks)
	elseif not virtText then
		virtText = withPadding(config, padding, fold.chunks)
		fold.virtText = virtText
	end

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

		local data ---@type Origami.FoldtextBufCache? only fetched if there is a closed fold
		local leftcol = 0

		vim.api.nvim_win_call(win, function()
			local line = topline
			while line <= botline do
				local foldstart = vim.fn.foldclosed(line)
				if foldstart > -1 then
					if not data then
						data = getBufCache(buf, config)
						leftcol = vim.fn.winsaveview().leftcol
					end
					line = renderFoldedSegments(win, buf, foldstart, leftcol, data)
				end
				line = line + 1
			end
		end)
	end,
})

--------------------------------------------------------------------------------
