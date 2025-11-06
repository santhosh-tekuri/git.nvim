local M = {}

function M.find_root()
    local root = vim.fn.systemlist("git rev-parse --show-toplevel")
    if vim.v.shell_error ~= 0 then
        M.root = nil
    else
        M.root = root[1]
    end
    return M.root
end

function M.find_git()
    local root = vim.fn.systemlist("git rev-parse --git-dir")
    if vim.v.shell_error ~= 0 then
        return nil
    else
        return root[1]
    end
end

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

function M.diff(file, staged)
    if not file then
        local status = M.status()
        if not status then
            vim.print("git status failed")
            return nil
        end
        local diff = {}
        for i, line in ipairs(status) do
            if i > 1 then
                local d = M.diff(line:sub(4), staged)
                if not d then
                    vim.print("diff " .. line:sub(3) .. " failed")
                    return nil
                end
                vim.list_extend(diff, d)
            end
        end
        return diff
    end
    local entry = M.status_file(file)
    if not entry then
        return nil
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
        local res = M.system(cmd)
        return res.code == 0 and res.stdout or nil
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
        end
        return res.code == 0 and res.stdout or nil
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

function M.commitmsg(flags)
    local file = M.find_git() .. "/COMMIT_EDITMSG"
    os.remove(file)
    local cmd = vim.list_extend({ "git", "commit" }, flags or {})
    M.system(cmd, { env = { GIT_EDITOR = "" } })
    local f = io.open(file, "r")
    if not f then
        return nil
    else
        local content = f:read("*all")
        f:close()
        return vim.split(content, "\n")
    end
end

function M.commit(flags, msg)
    local cmd = vim.list_extend({ "git", "commit" }, flags or {})
    cmd = vim.list_extend(cmd, { "-F", "-" })
    return M.system(cmd, { stdin = msg })
end

return M
