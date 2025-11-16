local cli = require("git.cli")
local Diff = require("git.Diff")
local Status = require("git.Status")

local ns = vim.api.nvim_create_namespace("gitstage")
local ns_sep = vim.api.nvim_create_namespace("gitstage_sep")

local function warn(msg)
    vim.api.nvim_echo({ { "\n" .. msg, "WarningMsg" } }, false, {})
end

local function warn_res(msg, res)
    msg = "\n" .. msg .. "\n" .. table.concat(res.stderr, "\n")
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
        zindex = 200,
    })
    vim.bo[qbuf].modifiable = false
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

local function check_modified_bufs()
    local modified = {}
    for _, buf in ipairs(vim.api.nvim_list_bufs()) do
        if vim.bo[buf].modified and vim.bo[buf].buftype == "" then
            local path = cli.path(vim.fn.bufname(buf))
            if path then
                if not cli.check_ignore(path).ok then
                    table.insert(modified, buf)
                end
            end
        end
    end
    if #modified == 0 then
        return
    end
    local msg = { "there are unsaved buffers:" }
    for _, buf in ipairs(modified) do
        table.insert(msg, "   " .. vim.fn.bufname(buf))
    end
    table.insert(msg, "")
    table.insert(msg, "Do you want save them?")
    if vim.fn.confirm(table.concat(msg, "\n"), "&Yes\n&No", 2) ~= 1 then
        return
    end
    for _, buf in ipairs(modified) do
        vim.api.nvim_buf_call(buf, function()
            vim.cmd("silent! write")
        end)
    end
end

local function terminal(cmd, on_close)
    local buf = vim.api.nvim_create_buf(false, true)
    local win = vim.api.nvim_open_win(buf, true, {
        relative = "editor",
        row = vim.o.lines - 10 - 1,
        col = 0,
        width = vim.o.columns,
        height = 10,
        style = 'minimal',
        zindex = 50,
        title = { { "$ " .. cmd, "NormalFloat" } },
        border = { " ", " ", " ", " ", " ", "", " ", " " },
    })
    vim.cmd.terminal(cmd)
    vim.api.nvim_create_autocmd("WinClosed", {
        pattern = tostring(win),
        callback = on_close,
    })
end

local gitstatus, gitdiff

local function gitcommit(data)
    local f = io.open(data.file, "r")
    if not f then
        warn("failed to open file " .. data.file)
        return
    end
    local content = f:read("*all")
    f:close()
    local msg = vim.split(content, "\n")

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
            table.insert(lines, "")
            local file = io.open(data.file, "w")
            if not file then
                warn("failed to write file " .. data.file)
                return
            end
            file:write(table.concat(lines, "\n"))
            file:close()

            file = io.open(data.pipe, "w")
            if not file then
                warn("failed to write pipe " .. data.pipe)
                return
            end
            file:write("0")
            file:close()
            data.pipe = nil
            vim.bo.modified = false
            vim.schedule(function()
                if vim.api.nvim_buf_is_valid(buf) then
                    vim.api.nvim_buf_delete(buf, { force = true })
                end
            end)
        end
    })
    vim.api.nvim_create_autocmd("WinClosed", {
        pattern = tostring(win),
        callback = function()
            if data.pipe then
                local file = io.open(data.pipe, "w")
                if not file then
                    warn("failed to write pipe " .. data.pipe)
                    return
                end
                file:write("1")
                file:close()
            end
            gitstatus()
        end
    })
end

local function pick_commit(on_close)
    require("picker").pick_git_commit(function(item)
        on_close(item and item.hash or nil)
    end)
end

function gitstatus(file)
    local status = Status:new({ "" }, true)
    local qbuf, qwin = setup_query()
    local pbuf, pwin = setup_preview()
    vim.api.nvim_set_option_value("cursorline", true, { scope = "local", win = pwin })
    local function update_content(f)
        local lines = cli.status()
        if not lines then
            warn("git status failed")
            return
        end
        status = Status:new(lines, status.categorized)

        -- show branch status info
        vim.api.nvim_buf_clear_namespace(qbuf, ns, 0, -1)
        vim.api.nvim_buf_set_extmark(qbuf, ns, 0, 0, {
            virt_text = { { status.branch } },
            virt_text_pos = "right_align",
            strict = false,
        })

        vim.api.nvim_buf_clear_namespace(pbuf, ns, 0, -1)
        vim.api.nvim_buf_set_lines(pbuf, 0, -1, false, status.lines)

        -- highlight status chars
        if status.categorized then
            local emptyline = false
            local function virtline(str)
                emptyline = true
                if emptyline then
                    return { {}, { { str } } }
                else
                    return { { { str } } }
                end
            end
            if status.staged > 0 then
                vim.api.nvim_buf_set_extmark(pbuf, ns, 0, 0, {
                    virt_lines = virtline("Staged:"),
                    virt_lines_above = true,
                })
            end
            if status.unstaged > 0 then
                vim.api.nvim_buf_set_extmark(pbuf, ns, status.staged, 0, {
                    virt_lines = virtline("Unstaged:"),
                    virt_lines_above = true,
                })
            end
            if status.unmerged > 0 then
                vim.api.nvim_buf_set_extmark(pbuf, ns, status.staged + status.unstaged, 0, {
                    virt_lines = virtline("Unmerged:"),
                    virt_lines_above = true,
                })
            end
            if status.untracked > 0 then
                vim.api.nvim_buf_set_extmark(pbuf, ns, status.staged + status.unstaged + status.unmerged, 0, {
                    virt_lines = virtline("Untracked:"),
                    virt_lines_above = true,
                })
            end
            for i, line in ipairs(status.lines) do
                local category = status:category(i)
                if category.staged then
                    vim.api.nvim_buf_set_extmark(pbuf, ns, i - 1, 0, {
                        end_row = i - 1,
                        end_col = 1,
                        hl_group = "Added",
                    })
                elseif category.unstaged then
                    vim.api.nvim_buf_set_extmark(pbuf, ns, i - 1, 0, {
                        end_row = i - 1,
                        end_col = 1,
                        hl_group = "Removed",
                    })
                elseif category.unmerged then
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
                else
                    vim.api.nvim_buf_set_extmark(pbuf, ns, i - 1, 0, {
                        end_row = i - 1,
                        end_col = 1,
                        hl_group = "Removed",
                    })
                end
            end
        else
            for i, line in ipairs(status.lines) do
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

        -- try to retain selection
        if f then
            for i, line in ipairs(status.lines) do
                if line:sub(#line - #f + 1) == f or line:find(" " .. f .. " ", 1, true) then
                    vim.api.nvim_win_set_cursor(pwin, { i, 0 })
                    break
                end
            end
        end
        if vim.fn.getwininfo(pwin)[1].topline == 1 then
            vim.api.nvim_win_call(pwin, function()
                vim.cmd("normal! ")
            end)
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
            arg = status:file(line)
        end
        if accept then
            gitdiff(arg, function()
                gitstatus(arg)
            end)
        end
        closed = true
        vim.api.nvim_buf_delete(qbuf, {})
        if vim.api.nvim_buf_is_valid(pbuf) then
            vim.api.nvim_buf_delete(pbuf, {})
        end
    end
    local function first()
        vim.api.nvim_win_set_cursor(pwin, { 1, 0 })
    end
    local function last()
        vim.api.nvim_win_set_cursor(pwin, { #status.lines, 0 })
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
    vim.api.nvim_create_autocmd('WinClosed', {
        buffer = qbuf,
        callback = function()
            vim.api.nvim_buf_delete(pbuf, {})
        end
    })
    local function keymap(lhs, func, args)
        vim.keymap.set("n", lhs, function()
            func(unpack(args or {}))
        end, { buffer = qbuf, nowait = true })
    end
    local function toggle_status()
        local line = vim.api.nvim_win_get_cursor(pwin)[1]
        local f = status:file(line)
        if status.categorized then
            local cagetory = status:category(line)
            local res
            if cagetory.staged then
                res = cli.unstage_file(f)
            elseif cagetory.unstaged then
                res = cli.stage_file(f)
            else
                res = cli.toggle_status(f)
            end
            if res.code ~= 0 then
                warn(table.concat(res.stderr, '\n'))
            end
            update_content(nil)

            -- retain selection in same category
            line = vim.api.nvim_win_get_cursor(pwin)[1]
            if status:category(line).name ~= cagetory.name then
                if line > 1 and status:category(line - 1).name == cagetory.name then
                    vim.api.nvim_win_set_cursor(pwin, { line - 1, 0 })
                elseif line < #status.lines and status:category(line + 1).name == cagetory.name then
                    vim.api.nvim_win_set_cursor(pwin, { line + 1, 0 })
                end
            end
        else
            local res = cli.toggle_status(f)
            if res.code ~= 0 then
                warn(table.concat(res.stderr, '\n'))
            end
            update_content(f)
        end
    end
    local function commit(flags, do_close)
        if #flags == 0 and cli.is_stage_empty() then
            if vim.fn.confirm("No changes added to commit.\nDo you want to create empty commit?", "&Yes\n&No", 2) ~= 1 then
                return
            end
            flags = { "--allow-empty" }
        end
        if do_close then
            close(nil)
        end
        cli.commit(flags)
    end
    local function fixup(flag)
        pick_commit(function(hash)
            if hash then
                commit({ flag .. hash }, flag == "fixup=")
            end
        end)
    end
    local function toggle_view()
        local line = vim.api.nvim_win_get_cursor(pwin)[1]
        local f = status:file(line)
        status.categorized = not status.categorized
        update_content(f)
    end
    local function next_section()
        if status.categorized then
            local line = vim.api.nvim_win_get_cursor(pwin)[1]
            local category = status:category(line)
            while line + 1 <= #status.lines do
                if status:category(line + 1).name ~= category.name then
                    vim.api.nvim_win_set_cursor(pwin, { line + 1, 0 })
                    return
                end
                line = line + 1
            end
            if #status.lines > 0 and status:category(1).name ~= category.name then
                vim.api.nvim_win_set_cursor(pwin, { 1, 0 })
            end
        end
    end
    local function prev_section()
        local function select_first_line(line)
            local category = status:category(line)
            while line - 1 >= 1 do
                if status:category(line - 1).name ~= category.name then
                    vim.api.nvim_win_set_cursor(pwin, { line, 0 })
                    return
                end
                line = line - 1
            end
            vim.api.nvim_win_set_cursor(pwin, { line, 0 })
        end
        if status.categorized then
            local line = vim.api.nvim_win_get_cursor(pwin)[1]
            local category = status:category(line)
            while line - 1 >= 1 do
                if status:category(line - 1).name ~= category.name then
                    select_first_line(line - 1)
                    return
                end
                line = line - 1
            end
            if #status.lines > 0 and status:category(#status.lines).name ~= category.name then
                select_first_line(#status.lines)
            end
        end
    end
    vim.api.nvim_create_autocmd("User", {
        group = vim.api.nvim_create_augroup("GitCommit", {}),
        pattern = "GitCommit",
        callback = function(args)
            gitcommit(args.data)
            close(nil)
        end,
    })
    keymap("`", toggle_view, {})
    keymap("<tab>", next_section, {})
    keymap("<s-tab>", prev_section, {})
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
    keymap("cc", commit, { {} })
    keymap("ca", commit, { { "--amend" } })
    keymap("ff", fixup, { "--fixup=" })
    keymap("fa", fixup, { "--fixup=amend:" })
    keymap("fr", fixup, { "--fixup=reword:" })
    keymap("F", terminal, { "git fetch", function() update_content() end })
    keymap("p", terminal, { "git pull", function() update_content() end })
    keymap("P", terminal, { "git push", function() update_content() end })
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

function gitdiff(file, on_close)
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
        _ = on_close and on_close()
        closed = true
        vim.api.nvim_buf_delete(qbuf, {})
        if vim.api.nvim_buf_is_valid(pbuf) then
            vim.api.nvim_buf_delete(pbuf, {})
        end
    end
    vim.api.nvim_create_autocmd('WinEnter', {
        buffer = pbuf,
        callback = function()
            vim.api.nvim_set_current_win(qwin)
        end
    })
    vim.api.nvim_create_autocmd('WinClosed', {
        buffer = qbuf,
        callback = function()
            vim.api.nvim_buf_delete(pbuf, {})
        end
    })
    local function keymap(lhs, func, args)
        vim.keymap.set("n", lhs, function()
            func(unpack(args or {}))
        end, { buffer = qbuf, nowait = true })
    end
    local function make_header_visible()
        local sb, se = unpack(diff.selection)
        local hb = diff:hb(sb)
        local info = vim.fn.getwininfo(pwin)[1]
        local top, bot = info.topline, info.botline
        local scroll = math.min(top - hb, bot - se)
        if scroll > 0 then
            vim.api.nvim_win_call(pwin, function()
                vim.cmd("normal! " .. scroll .. "")
            end)
        end
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
        make_header_visible()
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
            if not d.ok then
                warn_res("git diff failed", d)
                return
            end
            out = {}
            vim.list_extend(out, diff.lines, 1, hb - 1)
            vim.list_extend(out, d.stdout)
            vim.list_extend(out, diff.lines, e + 1, #diff.lines)
        else
            local res = cli.diff(file, area == 1)
            if not res.ok then
                warn_res("git diff failed", res)
                return
            end
            out = res.stdout
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
                if vim.fn.confirm("Are you sure you want to discard this change? It is irreversible.", "&Yes\n&No", 2) ~= 1 then
                    return
                end
                res = cli.apply(diff:patch_with_selection(true), { "-R" })
            else
                res = cli.apply(diff:patch_with_selection(), { "--cached" })
            end
        else
            local f = diff:file(diff.selection[1])
            res = cli.clear_staged_changes(f)
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

local function is_gitrepo()
    local res = cli.init()
    if not res.ok then
        warn_res("find root failed", res)
        return false
    end
    if not cli.root then
        warn("Not a git repository")
        return false
    end
    return true
end

vim.api.nvim_create_user_command('GitStatus', function()
    if is_gitrepo() then
        check_modified_bufs()
        gitstatus()
    end
end, { nargs = 0, desc = "Show Git Status" })

vim.api.nvim_create_user_command('GitDiff', function(cmd)
    if is_gitrepo() then
        if #cmd.fargs == 0 then
            check_modified_bufs()
            gitdiff(nil, nil)
        else
            local arg = vim.fn.expandcmd(cmd.fargs[1])
            arg = cli.path(arg)
            if arg == nil then
                warn("not in git repository")
                return
            end
            gitdiff(arg)
        end
    end
end, { nargs = '?', desc = "Show Git Status" })

local function setup()
    vim.keymap.set('n', ' x', "<cmd>GitStatus<cr>")
end

return { setup = setup }
