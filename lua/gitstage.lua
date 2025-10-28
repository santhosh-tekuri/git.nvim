local ns = vim.api.nvim_create_namespace("gitstage")

local function warn(msg)
    vim.api.nvim_echo({ { msg, "WarningMsg" } }, false, {})
end

local function gitroot()
    local root = vim.fn.systemlist("git rev-parse --show-toplevel")
    if vim.v.shell_error ~= 0 then
        warn("Not a git repository")
        return
    end
    return root[1]
end

local function gitlist(cmd)
    local root = gitroot()
    if not root then
        return
    end
    local res = vim.system(cmd, { cwd = root, text = true }):wait()
    if res.code ~= 0 then
        return nil
    end
    return vim.split(res.stdout, '\n', { trimempty = true })
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

local function gitstatus(cb)
    local root = gitroot()
    if not root then
        return
    end
    local lines = gitlist { "git", "--no-pager", "status", "-uall", "--porcelain=v1" }
    if not lines then
        warn("git status failed")
        return
    elseif #lines == 0 then
        warn("No changes detected. working tree clean")
        return
    end

    local qbuf, qwin = setup_query()
    local pbuf, pwin = setup_preview()
    vim.api.nvim_buf_set_lines(pbuf, 0, -1, false, lines)
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
        local file = nil
        if accept then
            local line = vim.api.nvim_win_get_cursor(pwin)[1]
            file = lines[line]:sub(4)
        end
        closed = true
        vim.api.nvim_buf_delete(qbuf, {})
        vim.api.nvim_buf_delete(pbuf, {})
        if file then
            cb(file)
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

local function gitdiff(file)
    local lines = gitlist { "git", "--no-pager", "diff", file }
    if not lines then
        warn("git diff failed")
        return
    elseif #lines == 0 then
        warn("nothing to stage")
        return
    end
    local qbuf, qwin = setup_query()
    local pbuf, pwin = setup_preview()
    vim.api.nvim_set_option_value("cursorline", false, { scope = "local", win = pwin })
    vim.api.nvim_buf_set_lines(pbuf, 0, -1, false, lines)
    vim.bo[pbuf].filetype = "diff"
    local closed = false
    local function close(accept)
        if closed then
            return
        end
        closed = true
        vim.api.nvim_buf_delete(qbuf, {})
        vim.api.nvim_buf_delete(pbuf, {})
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
                            local from = math.min(line, to)
                            to = math.max(line, to)
                            vfrom, vto = from, to
                            break
                        end
                        to = ln
                    end
                end
                vim.api.nvim_buf_clear_namespace(pbuf, ns, 0, -1)
                vim.api.nvim_buf_set_extmark(pbuf, ns, vfrom - 1, 0, {
                    end_row = vto,
                    strict = false,
                    hl_group = "Visual",
                    hl_eol = true,
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
        vfrom, vto = vfrom - 1, vfrom - 1
        move(1)
    end
    move(1)
    keymap("<esc>", close, { nil })
    keymap("q", close, { nil })
    keymap("j", move, { 1 })
    keymap("<down>", move, { 1 })
    keymap("k", move, { -1 })
    keymap("<up>", move, { -1 })
    keymap("v", toggle_mode, {})
end

gitstatus(function(item)
    gitdiff(item)
end)
