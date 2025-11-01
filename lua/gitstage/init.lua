local git = require("gitstage.git")
local Diff = require("gitstage.Diff")

local ns = vim.api.nvim_create_namespace("gitstage")

local function warn(msg)
    vim.api.nvim_echo({ { msg, "WarningMsg" } }, false, {})
end

local function setup_query()
    local qbuf = vim.api.nvim_create_buf(false, true)
    vim.b[qbuf].completion = false
    local qwin = vim.api.nvim_open_win(qbuf, true, {
        relative = "editor",
        width = vim.o.columns,
        height = 1,
        row = vim.o.lines,
        col = 0,
        style = "minimal",
        zindex = 250,
    })
    vim.api.nvim_set_option_value("statuscolumn", ":", { scope = "local", win = qwin })
    vim.api.nvim_set_option_value("winhighlight", "NormalFloat:MsgArea", { scope = "local", win = qwin })
    return qbuf, qwin
end

local function setup_preview()
    local pbuf = vim.api.nvim_create_buf(false, true)
    local pwin = vim.api.nvim_open_win(pbuf, false, {
        relative = "editor",
        row = 0,
        col = 0,
        width = vim.o.columns,
        height = vim.o.lines - 1,
        style = 'minimal',
        focusable = false,
        zindex = 50,
    })
    vim.api.nvim_set_option_value("winhighlight", "Normal:Normal,FloatBorder:Normal", { scope = "local", win = pwin })
    vim.api.nvim_set_option_value("wrap", false, { scope = "local", win = pwin })
    vim.api.nvim_set_option_value("cursorline", true, { scope = "local", win = pwin })
    return pbuf, pwin
end

local gitdiff

local function gitstatus(lnum)
    local lines = git.status()
    if not lines then
        warn("git status failed")
        return
    end
    if #lines == 0 then
        warn("No changes detected. working tree clean")
        return
    end

    local qbuf, qwin = setup_query()
    local pbuf, pwin = setup_preview()
    vim.api.nvim_buf_set_lines(pbuf, 0, -1, false, lines)
    vim.api.nvim_win_set_cursor(pwin, { lnum or 1, 0 })
    for i, line in ipairs(lines) do
        vim.api.nvim_buf_set_extmark(pbuf, ns, i - 1, 0, {
            end_row = i - 1,
            end_col = 1,
            hl_group = line:sub(1, 1) == "?" and "Removed" or "Added",
        })
        vim.api.nvim_buf_set_extmark(pbuf, ns, i - 1, 1, {
            end_row = i - 1,
            end_col = 2,
            hl_group = "Removed",
        })
    end

    local closed = false
    local function close(accept)
        if closed then
            return
        end
        local selection = nil
        if accept then
            local line = vim.api.nvim_win_get_cursor(pwin)[1]
            selection = {
                lnum = line,
                line = lines[line],
            }
        end
        closed = true
        vim.api.nvim_buf_delete(qbuf, {})
        vim.api.nvim_buf_delete(pbuf, {})
        if selection then
            gitdiff(selection)
        end
    end
    local function move(i)
        local line = vim.api.nvim_win_get_cursor(pwin)[1] + i
        if line <= 0 then
            line = vim.api.nvim_buf_line_count(pbuf)
        elseif line > vim.api.nvim_buf_line_count(pbuf) then
            line = 1
        end
        vim.api.nvim_win_set_cursor(pwin, { line, 0 })
    end
    vim.api.nvim_create_autocmd('WinLeave', {
        buffer = qbuf,
        callback = function()
            close()
        end
    })
    local function keymap(lhs, func, args)
        vim.keymap.set("n", lhs, function()
            func(unpack(args or {}))
        end, { buffer = qbuf, nowait = true })
    end
    keymap("<esc>", close, { nil })
    keymap("q", close, { nil })
    keymap("o", close, { true })
    keymap("<cr>", close, { true })
    keymap("j", move, { 1 })
    keymap("<down>", move, { 1 })
    keymap("k", move, { -1 })
    keymap("<up>", move, { -1 })
end

function gitdiff(selection)
    local area = 2
    local diff = Diff:new({}, false)

    local qbuf, qwin = setup_query()
    local pbuf, pwin = setup_preview()
    vim.api.nvim_set_option_value("signcolumn", "auto", { scope = "local", win = pwin })
    vim.api.nvim_set_option_value("cursorline", false, { scope = "local", win = pwin })
    vim.bo[pbuf].filetype = "diff"

    local closed = false
    local function close(accept)
        if closed then
            return
        end
        closed = true

        vim.api.nvim_buf_delete(qbuf, {})
        vim.api.nvim_buf_delete(pbuf, {})
        gitstatus(selection.lnum)
    end
    vim.api.nvim_create_autocmd('WinLeave', {
        buffer = qbuf,
        callback = function()
            close()
        end
    })
    local function keymap(lhs, func, args)
        vim.keymap.set("n", lhs, function()
            func(unpack(args or {}))
        end, { buffer = qbuf, nowait = true })
    end
    local function set_selection(dselection, step)
        if not dselection then
            if step == -1 then
                vim.api.nvim_win_call(pwin, function()
                    vim.cmd("normal! zz")
                end)
            end
            return
        end
        local vfrom, vto = unpack(dselection)
        vim.api.nvim_buf_clear_namespace(pbuf, ns, 0, -1)
        vim.api.nvim_buf_set_extmark(pbuf, ns, vfrom - 1, 0, {
            end_row = vto,
            strict = false,
            hl_group = "Visual",
            hl_eol = true,
        })
        vim.api.nvim_win_set_cursor(pwin, { step == 1 and vto or vfrom, 0 })

        local begin, change = unpack(diff:selection_loc())
        vim.api.nvim_buf_clear_namespace(qbuf, ns, 0, -1)
        vim.api.nvim_buf_set_extmark(qbuf, ns, 0, 0, {
            virt_text = { { selection.line:sub(4) }, { " " .. vfrom .. "," .. vto }, { " " .. begin .. "," .. change } },
            virt_text_pos = "right_align",
            strict = false,
        })
    end
    local function move(step)
        if diff:empty() then
            return
        end
        set_selection(diff:select(step))
    end
    local function toggle_mode()
        if diff:empty() then
            return
        end
        set_selection(diff:toggle_mode())
    end
    local function update_area()
        local hl = area == 1 and "Added" or "Removed"
        vim.api.nvim_set_option_value("statuscolumn", "%#" .. hl .. "#▎ ", { scope = "local", win = pwin })
        local out = git.diff(selection.line:sub(4), area == 1)
        if not out then
            warn("git diff failed")
        end
        diff = Diff:new(out and out or {}, diff.line_mode)
        vim.api.nvim_buf_set_lines(pbuf, 0, -1, false, diff.lines)
    end
    local function toggle_area()
        area = area == 1 and 2 or 1
        update_area()
        move(1)
    end
    local function apply()
        if not diff.selection then
            return
        end
        local sel = diff.selection
        local res
        if area == 2 then
            res = git.stage(diff:patch_with_selection())
        else
            res = git.restore(selection.line:sub(4))
            if res.code == 0 then
                local patch = diff:patch_without_selection()
                if patch then
                    res = git.stage(patch)
                end
            end
        end
        if res.code ~= 0 then
            warn(table.concat(res.stderr, '\n'))
        else
            update_area()
            local s = diff:select(1, { sel[1] - 1, sel[1] - 1 })
            if not s then
                s = diff:select(-1, { sel[1], sel[1] })
            end
            if s then
                set_selection(s, 1)
            else
                move(1)
            end
        end
    end
    keymap("<esc>", close, { nil })
    keymap("q", close, { nil })
    keymap("j", move, { 1 })
    keymap("<down>", move, { 1 })
    keymap("k", move, { -1 })
    keymap("<up>", move, { -1 })
    keymap("v", toggle_mode, {})
    keymap("<tab>", toggle_area, {})
    keymap(" ", apply, {})
    update_area()
    move(1)
end

local function setup()
    vim.keymap.set('n', ' x', function()
        if not git.find_root() then
            warn("Not a git repository")
            return
        end
        gitstatus()
    end)
end

return { setup = setup }
