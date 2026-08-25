local ns = vim.api.nvim_create_namespace("origami.foldText")
local config = require("origami.config").config

---@alias Origami.VirtTextChunk {[1]: string, [2]?: string[]}

---@alias Origami.FoldtextComponentProvider fun(buf: number, foldstart: number, foldend: number): Origami.VirtTextChunk[]

---@alias Origami.render_cache { [number]: { tick: number, folds: { [number]: Origami.VirtTextChunk } } }

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

local has_minidiff, MiniDiff = pcall(require, "mini.diff")
local has_gitsigns, gitsigns = pcall(require, "gitsigns")
---@type Origami.FoldtextComponentProvider
local function getDiagnosticsInFold(buf, foldstart, foldend)
	local diagnosticsDisabled = vim.diagnostic.is_enabled { bufnr = buf } == false
	if diagnosticsDisabled then return {} end

	-- get config from `vim.diagnostic.config`
	local signConfig = vim.diagnostic.config().signs
	if type(signConfig) == "function" then signConfig = signConfig(_, buf) end -- see #24
	local diagIcons = { "E", "W", "I", "H" }
	local diagHls = { "DiagnosticError", "DiagnosticWarn", "DiagnosticInfo", "DiagnosticHint" }
	if type(signConfig) == "table" then
		diagIcons = signConfig.text or diagIcons
		diagHls = signConfig.linehl or diagHls
	end

	-- get count by severity in the folded lines
	local diagsInFold = {
		[vim.diagnostic.severity.ERROR] = 0,
		[vim.diagnostic.severity.WARN] = 0,
		[vim.diagnostic.severity.INFO] = 0,
		[vim.diagnostic.severity.HINT] = 0,
	}
	for _, diag in ipairs(vim.diagnostic.get(buf)) do
		local lnum = diag.lnum + 1
		if lnum > foldstart and lnum <= foldend then -- exclude 1st folded line since still visible
			diagsInFold[diag.severity] = diagsInFold[diag.severity] + 1
		end
	end

	-- convert count info into virtual text table for `set_extmark`
	local chunks = {} ---@type Origami.VirtTextChunk[]
	for level, number in ipairs(diagsInFold) do
		if number > 0 then
			table.insert(chunks, { " " }) -- separate, so the padding does not get hlgroup
			local text = diagIcons[level] .. " " .. number
			table.insert(chunks, { text, { diagHls[level] } })
		end
	end
	return chunks
end

---@type Origami.FoldtextComponentProvider
local function getGitHunksInFold(buf, foldstart, foldend)
	local typeIcons = { change = "~", delete = "-", add = "+" }
	local typeHls = { change = "GitSignsChange", delete = "GitSignsDelete", add = "GitSignsAdd" }

	-- get count by type in the folded lines: for deletions check if deletion is
	-- in the fold, for additions/changes, calculate the overlap of hunk and fold
	local hunksInFold = { change = 0, delete = 0, add = 0 }
	for _, h in ipairs(gitsigns.get_hunks(buf) or {}) do
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
local function getGitHunksInFoldWithMiniDiff(buf, foldstart, foldend)
	local typeIcons = { change = "~", delete = "-", add = "+" }
	local typeHls =
		{ change = "MiniDiffSignChange", delete = "MiniDiffSignDelete", add = "MiniDiffSignAdd" }

	local buf_data = MiniDiff.get_buf_data(buf)
	if not buf_data or not buf_data.hunks then return {} end

	-- get count by type in the folded lines: for deletions check if deletion is
	-- in the fold, for additions/changes, calculate the overlap of hunk and fold
	local hunksInFold = { change = 0, delete = 0, add = 0 }
	for _, h in ipairs(buf_data.hunks) do
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

-- Global cache table
local render_cache = {} ---@type Origami.render_cache

---@param win number
---@param buf number
---@param foldstart number
---@return number foldend
local function renderFoldedSegments(win, buf, foldstart, leftcol)
	local current_tick = vim.api.nvim_buf_get_changedtick(buf)
	if not render_cache[buf] or render_cache[buf].tick ~= current_tick then
		render_cache[buf] = { tick = current_tick, folds = {} }
	end

	local foldend = vim.fn.foldclosedend(foldstart)
	local virtText = {} ---@type Origami.VirtTextChunk[]
	if render_cache[buf].folds[foldstart] then
		virtText = render_cache[buf].folds[foldstart]
	else
		-- get virtual text components
		local lineCountText = config.foldtext.lineCount.template:format(foldend - foldstart)
		virtText = {
			{ lineCountText, { config.foldtext.lineCount.hlgroup } },
		}

		if config.foldtext.diagnosticsCount then
			local diagnostics = getDiagnosticsInFold(buf, foldstart, foldend)
			if #diagnostics > 0 then table.insert(virtText, { " " }) end
			vim.list_extend(virtText, diagnostics)
		end
		if config.foldtext.gitsignsCount then
			local hunks = {} ---@type Origami.VirtTextChunk[]
			if has_gitsigns then
				hunks = getGitHunksInFold(buf, foldstart, foldend)
			elseif has_minidiff then
				hunks = getGitHunksInFoldWithMiniDiff(buf, foldstart, foldend)
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
		render_cache[buf].folds[foldstart] = virtText
	end

	-- add text as extmark
	local wincol = math.max(0, vim.fn.virtcol({ foldstart, "$" }) - 1 - leftcol)

	vim.api.nvim_buf_set_extmark(buf, ns, foldstart - 1, 0, {
		virt_text = virtText,
		virt_text_win_col = wincol,
		hl_mode = "combine",
		ephemeral = true, -- only for decorators in a redraw cycle
		priority = config.foldtext.priority,
	})

	return foldend
end

local raw_disabled_fts = config.foldtext.disableOnFt
local disabled_fts_set = {}
for _, ft in ipairs(raw_disabled_fts) do
	disabled_fts_set[ft] = true
end

vim.api.nvim_set_decoration_provider(ns, {
	on_win = function(_, win, buf, topline, botline)
		if disabled_fts_set[vim.bo[buf].filetype] then return end
		local leftcol = vim.fn.getwininfo(win)[1].leftcol
		vim.api.nvim_win_call(win, function()
			local line = topline
			while line <= botline do
				local foldstart = vim.fn.foldclosed(line)
				if foldstart > -1 then line = renderFoldedSegments(win, buf, foldstart, leftcol) end
				line = line + 1
			end
		end)
	end,
})

--------------------------------------------------------------------------------
