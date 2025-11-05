local cli = require("git.cli")
local Diff = require("git.Diff")

local ns = vim.api.nvim_create_namespace("gitstage")
local ns_sep = vim.api.nvim_create_namespace("gitstage_sep")

local function warn(msg)
    vim.api.nvim_echo({ { "\n" .. msg, "WarningMsg" } }, false, {})
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
        zindex = 200,
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
        zindex = 50,
    })
    vim.api.nvim_set_option_value("winhighlight", "Normal:Normal,FloatBorder:Normal", { scope = "local", win = pwin })
    vim.api.nvim_set_option_value("wrap", false, { scope = "local", win = pwin })
    return pbuf, pwin
end

local gitdiff

local function gitcommit(flags, msg)
    local buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_name(buf, "COMMIT_EDITMSG")
    vim.bo[buf].filetype = "gitcommit"
    vim.bo[buf].buftype = "acwrite"
    vim.bo[buf].swapfile = false
    vim.bo[buf].bufhidden = "wipe"
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, msg)
    vim.bo[buf].modified = false
    local win = vim.api.nvim_open_win(buf, true, {
        relative = "editor",
        row = 0,
        col = 0,
        width = vim.o.columns,
        height = vim.o.lines - 1,
        focusable = false,
        zindex = 50,
    })
    vim.api.nvim_set_option_value("winhighlight", "Normal:Normal,FloatBorder:Normal", { scope = "local", win = win })
    vim.api.nvim_set_option_value("wrap", false, { scope = "local", win = win })
    vim.api.nvim_create_autocmd("BufWriteCmd", {
        buffer = buf,
        callback = function()
            local lines = vim.api.nvim_buf_get_lines(0, 0, -1, false)
            local m = {}
            for _, line in ipairs(lines) do
                if line:sub(1, 1) == "#" then
                    break
                end
                table.insert(m, line)
            end
            local res = cli.commit(flags, table.concat(m, "\n"))
            if res.code ~= 0 then
                warn(table.concat(res.stderr, "\n"))
                return
            end
            vim.bo.modified = false
            vim.schedule(function()
                if vim.api.nvim_buf_is_valid(buf) then
                    vim.api.nvim_buf_delete(buf, { force = true })
                end
            end)
            vim.api.nvim_echo({ { table.concat(res.stdout, "\n") } }, false, {})
        end
    })
end

local function gitstatus(file)
    local lines = cli.status()
    if not lines then
        warn("git status failed")
        return
    end
    if #lines == 1 then
        warn("No changes detected. working tree clean")
        return
    end

    local qbuf, qwin = setup_query()
    local pbuf, pwin = setup_preview()
    vim.api.nvim_set_option_value("cursorline", true, { scope = "local", win = pwin })
    local function update_content(f)
        local branch = lines[1]
        table.remove(lines, 1)
        vim.api.nvim_buf_clear_namespace(qbuf, ns, 0, -1)
        vim.api.nvim_buf_set_extmark(qbuf, ns, 0, 0, {
            virt_text = { { branch:sub(3) } },
            virt_text_pos = "right_align",
            strict = false,
        })

        vim.api.nvim_buf_clear_namespace(pbuf, ns, 0, -1)
        vim.api.nvim_buf_set_lines(pbuf, 0, -1, false, lines)
        if f then
            for i, line in ipairs(lines) do
                if line:sub(#line - #f + 1) == f or line:find(" " .. f .. " ", 1, true) then
                    vim.api.nvim_win_set_cursor(pwin, { i, 0 })
                    break
                end
            end
        end
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
    end
    update_content(file)

    local closed = false
    local function close(accept, selection)
        if closed then
            return
        end
        local arg
        if accept and selection then
            local line = vim.api.nvim_win_get_cursor(pwin)[1]
            arg = lines[line]:sub(4)
        end
        if accept then
            gitdiff(arg)
        end
        closed = true
        vim.api.nvim_buf_delete(qbuf, {})
        vim.api.nvim_buf_delete(pbuf, {})
    end
    local function first()
        vim.api.nvim_win_set_cursor(pwin, { 1, 0 })
    end
    local function last()
        vim.api.nvim_win_set_cursor(pwin, { #lines, 0 })
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
    vim.api.nvim_create_autocmd('WinEnter', {
        buffer = pbuf,
        callback = function()
            vim.api.nvim_set_current_win(qwin)
        end
    })
    local function keymap(lhs, func, args)
        vim.keymap.set("n", lhs, function()
            func(unpack(args or {}))
        end, { buffer = qbuf, nowait = true })
    end
    local function toggle_status()
        local line = vim.api.nvim_win_get_cursor(pwin)[1]
        local f = lines[line]:sub(4)
        local res = cli.toggle_status(f)
        if res.code ~= 0 then
            warn(table.concat(res.stderr, '\n'))
        end
        lines = cli.status()
        update_content(f)
    end
    local function commit(flags)
        local msg = cli.commitmsg(flags)
        if not msg then
            warn("failed to create commit message")
        elseif #msg == 0 then
            warn("nothing to commit")
        else
            close(nil)
            gitcommit(flags, msg)
        end
    end
    keymap("<esc>", close, { nil })
    keymap("q", close, { nil })
    keymap("o", close, { true, true })
    keymap("O", close, { true, false })
    keymap("<cr>", close, { true, true })
    keymap("j", move, { 1 })
    keymap("<down>", move, { 1 })
    keymap("k", move, { -1 })
    keymap("<up>", move, { -1 })
    keymap("gg", first, {})
    keymap("G", last, {})
    keymap("<space>", toggle_status, {})
    keymap("c", commit, { {} })
    keymap("A", commit, { { "--amend" } })
end

function StatusColumn1()
    if vim.v.virtnum < 0 then
        return "  "
    end
    return "%#Added#▎ "
end

function StatusColumn2()
    if vim.v.virtnum < 0 then
        return "  "
    end
    return "%#Removed#▎ "
end

function gitdiff(file)
    local area = 2
    local diff = Diff:new({}, false)

    local qbuf, qwin = setup_query()
    local pbuf, pwin = setup_preview()
    vim.api.nvim_set_option_value("signcolumn", "auto", { scope = "local", win = pwin })
    vim.api.nvim_set_option_value("cursorline", false, { scope = "local", win = pwin })
    vim.bo[pbuf].filetype = "diff"

    local function set_filemark(f)
        vim.api.nvim_buf_clear_namespace(qbuf, ns, 0, -1)
        vim.api.nvim_buf_set_extmark(qbuf, ns, 0, 0, {
            virt_text = { { f } },
            virt_text_pos = "right_align",
            strict = false,
        })
    end
    if file then
        set_filemark(file)
    end

    local closed = false
    local function close()
        if closed then
            return
        end
        gitstatus(file)
        closed = true
        vim.api.nvim_buf_delete(qbuf, {})
        vim.api.nvim_buf_delete(pbuf, {})
    end
    vim.api.nvim_create_autocmd('WinEnter', {
        buffer = pbuf,
        callback = function()
            vim.api.nvim_set_current_win(qwin)
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
        if not file then
            vim.print(diff:is_header(dselection[1]))
            set_filemark(diff:file(dselection[1]))
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
    end
    local function first()
        if diff:empty() then
            return
        end
        local h = diff:header()
        set_selection(diff:select(1, { h + 1, h + 1 }))
    end
    local function last()
        if diff:empty() then
            return
        end
        local c = #diff.lines
        set_selection(diff:select(-1, { c + 1, c + 1 }))
    end
    local function move(step)
        if diff:empty() then
            return
        end
        local sel = diff:select(step)
        if sel then
            set_selection(sel, step)
        end
    end
    local function move_file(step)
        if diff:empty() then
            return
        end
        local sel = diff:select_file(step)
        if sel then
            set_selection(sel, step)
        end
    end
    local function toggle_mode()
        if diff:empty() or not diff.selection then
            return
        end
        set_selection(diff:toggle_mode())
    end
    local function update_area(partial)
        local stc = "%!v:lua.StatusColumn" .. area .. "()"
        vim.api.nvim_set_option_value("statuscolumn", stc, { scope = "local", win = pwin })
        local out
        if partial then
            local hb, _, e = diff:bounds(diff.selection[1])
            local f = diff:file(hb)
            local d = cli.diff(f, area == 1)
            if not d then
                warn("git diff failed")
                return
            end
            out = {}
            vim.list_extend(out, diff.lines, 1, hb - 1)
            vim.list_extend(out, d)
            vim.list_extend(out, diff.lines, e + 1, #diff.lines)
        else
            out = cli.diff(file, area == 1)
            if not out then
                warn("git diff failed")
                return
            end
        end

        diff = Diff:new(out and out or {}, diff.line_mode)
        vim.api.nvim_buf_set_lines(pbuf, 0, -1, false, diff.lines)

        vim.api.nvim_buf_clear_namespace(pbuf, ns_sep, 0, -1)
        for i, line in ipairs(diff.lines) do
            if i > 1 and line:find("^diff %-%-git ") then
                local emptyline = { { string.rep(" ", vim.o.columns) } }
                vim.api.nvim_buf_set_extmark(pbuf, ns_sep, i - 1, 0, {
                    virt_lines = { emptyline, emptyline },
                    virt_lines_above = true,
                    end_row = i - 1,
                    strict = false,
                })
            end
        end
    end
    local function toggle_area()
        area = area == 1 and 2 or 1
        update_area()
        move(1)
    end
    local function apply(discard)
        if not diff.selection then
            return
        end
        local sel = diff.selection
        local res
        if area == 2 then
            if discard then
                res = cli.apply(diff:patch_with_selection(), { "-R" })
            else
                res = cli.apply(diff:patch_with_selection(), { "--cached" })
            end
        else
            local f = diff:file(diff.selection[1])
            res = cli.restore(f)
            if res.code == 0 then
                local patch = diff:patch_without_selection()
                if patch then
                    local b = f:find(" -> ", 1, true)
                    if b then
                        patch = vim.list_extend({}, patch, 6, #patch)
                    end
                    res = cli.apply(patch, { "--cached" })
                end
            end
        end
        if res.code ~= 0 then
            warn(table.concat(res.stderr, '\n'))
        else
            update_area(true)
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
    keymap("<esc>", close, {})
    keymap("q", close, {})
    keymap("j", move, { 1 })
    keymap("<down>", move, { 1 })
    keymap("k", move, { -1 })
    keymap("<up>", move, { -1 })
    keymap("J", move_file, { 1 })
    keymap("K", move_file, { -1 })
    keymap("gg", first, {})
    keymap("G", last, {})
    keymap("v", toggle_mode, {})
    keymap("<tab>", toggle_area, {})
    keymap("<space>", apply, {})
    keymap("d", apply, { true })
    update_area()
    move(1)
end

local function pick_commit()
    local function line2item(line)
        local sp = line:find(" ", 1, true)
        if sp then
            return { hash = line:sub(1, sp - 1), msg = line:sub(sp + 1) }
        end
        return { msg = line }
    end
    local function log(on_list, opts)
        -- picker.cmd_items("git", )
    end
end

local function setup()
    vim.keymap.set('n', ' x', function()
        if not cli.find_root() then
            warn("Not a git repository")
            return
        end
        gitstatus()
    end)
end

return { setup = setup }
