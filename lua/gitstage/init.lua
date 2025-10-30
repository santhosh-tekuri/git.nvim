local git = require("gitstage.git")

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
                line = line,
                file = lines[line]:sub(4),
                index = lines[line]:sub(1, 1),
                working = lines[line]:sub(2, 2),
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
    local lines = {}
    local function diff()
        local out = git.diff(selection.file, area == 1)
        if not out then
            warn("git diff failed")
            return {}
        end
        return out
    end

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
        gitstatus(selection.line)
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
    local line_mode = false
    local function is_change(line)
        local node = vim.treesitter.get_node({ bufnr = pbuf, pos = { line - 1, 0 } })
        local type = node and node:type() or ""
        return type == "addition" or type == "deletion"
    end
    local vfrom, vto = 0, 0
    local function move(step)
        local last = step == 1 and vim.api.nvim_buf_line_count(pbuf) or 1
        local cur = step == 1 and vto or vfrom
        for line = cur + step, last, step do
            if is_change(line) then
                if line_mode then
                    vfrom, vto = line, line
                else
                    local to = line
                    for ln = line + step, last, step do
                        if not is_change(ln) then
                            break
                        end
                        to = ln
                    end
                    local from = math.min(line, to)
                    to = math.max(line, to)
                    vfrom, vto = from, to
                end
                vim.api.nvim_buf_clear_namespace(pbuf, ns, 0, -1)
                vim.api.nvim_buf_set_extmark(pbuf, ns, vfrom - 1, 0, {
                    end_row = vto,
                    strict = false,
                    hl_group = "Visual",
                    hl_eol = true,
                })

                local change = 0
                local tmp = vfrom
                while true do
                    local ch = lines[tmp]:sub(1, 1)
                    if ch == '+' or ch == '-' then
                        change = change + 1
                        tmp = tmp - 1
                    else
                        break
                    end
                end
                local begin = 0
                while true do
                    local ch = lines[tmp]:sub(1, 1)
                    if ch == '-' or ch == ' ' then
                        begin = begin + 1
                    elseif ch == '@' then
                        local x, y = lines[tmp]:match("^@@ %-(%d+),(%d+) ")
                        if x then
                            begin = begin + tonumber(x)
                            if tonumber(y) > 0 then
                                begin = begin - 1
                            end
                        end
                        break
                    end
                    tmp = tmp - 1
                end

                vim.api.nvim_buf_clear_namespace(qbuf, ns, 0, -1)
                vim.api.nvim_buf_set_extmark(qbuf, ns, 0, 0, {
                    virt_text = { { selection.file }, { " " .. vfrom .. "," .. vto }, { " " .. begin .. "," .. change } },
                    virt_text_pos = "right_align",
                    strict = false,
                })
                vim.api.nvim_win_set_cursor(pwin, { step == 1 and vto or vfrom, 0 })
                return
            end
        end
        if step == -1 then
            vim.api.nvim_win_call(pwin, function()
                vim.cmd("normal! zz")
            end)
        end
    end
    local function toggle_mode()
        line_mode = not line_mode
        while is_change(vfrom) do
            vfrom = vfrom - 1
        end
        vto = vfrom - 1
        move(1)
    end
    local function update_area()
        local hl = area == 1 and "Added" or "Removed"
        vim.api.nvim_set_option_value("statuscolumn", "%#" .. hl .. "#▎ ", { scope = "local", win = pwin })
        lines = diff()
        vim.api.nvim_buf_set_lines(pbuf, 0, -1, false, lines)
        local parser = vim.treesitter.get_parser(pbuf)
        if parser then
            parser:parse(true)
        end
        vfrom, vto = 0, 0
        move(1)
    end
    local function toggle_area()
        area = area == 1 and 2 or 1
        update_area()
    end
    update_area()
    keymap("<esc>", close, { nil })
    keymap("q", close, { nil })
    keymap("j", move, { 1 })
    keymap("<down>", move, { 1 })
    keymap("k", move, { -1 })
    keymap("<up>", move, { -1 })
    keymap("v", toggle_mode, {})
    keymap("<tab>", toggle_area, {})
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
