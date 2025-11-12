local M = {}

function M.system(cmd, options)
    options = vim.tbl_deep_extend('force', { cwd = M.root, text = true }, options or {})
    local res = vim.system(cmd, options):wait()
    return {
        ok = res.code == 0,
        code = res.code,
        stdout = res.stdout and vim.split(res.stdout, '\n', { trimempty = true }) or {},
        stderr = res.stderr and vim.split(res.stderr, '\n', { trimempty = true }) or {},
    }
end

function M.init()
    local res = M.system({ "git", "rev-parse", "--show-toplevel" })
    if res.ok then
        M.root = res.stdout[1]
    end
    return res
end

function M.path(file)
    file = vim.fn.fnamemodify(file, ":p")
    if file:sub(1, #M.root) == M.root then
        local ch = file:sub(#M.root + 1, #M.root + 1)
        if ch == '/' or ch == '\\' then
            return file:sub(#M.root + 2)
        end
    end
    return nil
end

function M.check_ignore(file)
    return M.system({ "git", "check-ignore", "--quiet", "--", file })
end

function M.find_git()
    local res = M.system({ "git", "rev-parse", "--git-dir" })
    return res.ok and res.stdout[1] or nil
end

function M.status()
    local res = M.system { "git", "--no-pager", "status", "-b", "-uall", "--porcelain=v1" }
    return res.code == 0 and res.stdout or nil
end

function M.status_file(file)
    local cmd = { "git", "--no-pager", "status", "-uall", "--porcelain=v1", "--" }
    local b, e = file:find(" -> ", 1, true)
    if b then
        vim.list_extend(cmd, { file:sub(1, b - 1), file:sub(e + 1) })
    else
        table.insert(cmd, file)
    end
    local res = M.system(cmd)
    return res.code == 0 and res.stdout[1] or nil
end

function M.is_stage_empty()
    return M.system({ "git", "diff", "--staged", "--exit-code", "--quiet" }).ok
end

function M.diff(file, staged)
    if not file then
        local status = M.status()
        if not status then
            return { ok = false, code = 1, stdout = {}, stderr = { "git status failed" } }
        end
        local diff = {}
        for i, line in ipairs(status) do
            if i > 1 then
                local d = M.diff(line:sub(4), staged)
                if not d.ok then
                    return d
                end
                vim.list_extend(diff, d.stdout)
            end
        end
        return { ok = true, code = 0, stdout = diff, stderr = {} }
    end

    local entry = M.status_file(file)
    if not entry then
        return { code = 0, ok = true, stdout = {}, stderr = {} }
    end

    local cmd = { "git", "--no-pager", "diff" }
    local function add_file(f)
        local b, e = f:find(" -> ", 1, true)
        if b then
            vim.list_extend(cmd, { "--", f:sub(1, b - 1), f:sub(e + 1) })
        else
            vim.list_extend(cmd, { "--", f })
        end
    end
    if staged then
        table.insert(cmd, "--staged")
        add_file(file)
        return M.system(cmd)
    else
        local status = entry:sub(2, 2)
        local untracked = status == '?'
        if untracked then
            table.insert(cmd, "--no-index")
            add_file("/dev/null -> " .. file)
        else
            add_file(file)
        end
        local res = M.system(cmd)
        if untracked then
            res.code = res.code == 0 and 1 or 0
            res.ok = not res.ok
        end
        return res
    end
end

function M.restore(file)
    local b, e = file:find(" -> ", 1, true)
    if b then
        local old, new = file:sub(1, b - 1), file:sub(e + 1)
        local res = M.system({ "git", "restore", "--staged", "--", new })
        if res.code ~= 0 then
            return res
        end
        res = M.system({ "git", "restore", "--staged", "--", old })
        if res.code ~= 0 then
            return res
        end
        return M.apply({
            "diff --git a/" .. old .. " b/" .. new,
            "similarity index 100%",
            "rename from " .. old,
            "rename to " .. new,
        }, { "--cached" })
    else
        return M.system({ "git", "restore", "--staged", "--", file })
    end
end

function M.toggle_status(file)
    local entry = M.status_file(file)
    if not entry then
        return { code = 1, stderr = { "file not found" } }
    end
    local ch = entry:sub(2, 2)
    local b, e = entry:find(" -> ", 1, true)
    if b then
        file = entry:sub(e + 1)
    end
    if ch == '?' or ch ~= ' ' then
        return M.system({ "git", "add", "--", file })
    else
        return M.restore(file)
    end
end

function M.apply(patch, args)
    table.insert(patch, "")
    patch = table.concat(patch, '\n')
    local file = io.open("patch.diff", "w")
    if file then
        file:write(patch)
        file:close()
    end
    local cmd = vim.list_extend({ "git", "apply" }, args or {})
    cmd = vim.list_extend(cmd, { "-" })
    return M.system(cmd, { stdin = patch })
end

function M.commit(flags)
    local cmd = vim.list_extend({ "git", "commit" }, flags or {})
    local editor = vim.api.nvim_get_runtime_file("git_editor.sh", false)[1]
    local opts = {}
    opts = { text = true, env = { GIT_EDITOR = editor .. " " .. vim.v.servername } }
    vim.system(cmd, opts, function(res)
        local msg = res.code == 0 and res.stdout or res.stderr
        if msg and not msg:find("^error: There was a problem with the editor ") then
            vim.schedule_wrap(vim.api.nvim_echo)({ { "\n" .. msg } }, false, {})
        end
    end)
end

return M
