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

function M.system(cmd)
    local res = vim.system(cmd, { cwd = M.root, text = true }):wait()
    return {
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
        return M.stage({
            "diff --git a/" .. old .. " b/" .. new,
            "similarity index 100%",
            "rename from " .. old,
            "rename to " .. new,
        })
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

function M.stage(patch)
    table.insert(patch, "")
    patch = table.concat(patch, '\n')
    local file = io.open("stage.diff", "w")
    if file then
        file:write(patch)
        file:close()
    end
    local res = vim.system({ "git", "apply", "--cached", "-" }, { cwd = M.root, text = true, stdin = patch }):wait()
    return {
        code = res.code,
        stdout = res.stdout and vim.split(res.stdout, '\n', { trimempty = true }) or {},
        stderr = res.stderr and vim.split(res.stderr, '\n', { trimempty = true }) or {},
    }
end

function M.commitmsg()
    local staged = M.system({ "git", "diff", "--staged" })
    if staged.code ~= 0 then
        return nil
    end
    if #staged.stdout == 0 then
        return {}
    end
    local template = [[Please enter the commit message for your changes. Lines starting
with '#' will be ignored, and an empty message aborts the commit.]]

    local msg = { "" }
    for _, line in ipairs(vim.split(template, "\n", { trimempty = true })) do
        if #line == 0 then
            table.insert(msg, "#")
        else
            table.insert(msg, "# " .. line)
        end
    end
    table.insert(msg, "#")
    local res = M.system({ "git", "status" })
    if res.code ~= 0 then
        return nil
    end

    local last = res.stdout[#res.stdout]
    if last:sub(1, #"no changes added to commit") == "no changes added to commit" then
        table.remove(res.stdout)
        table.remove(res.stdout)
    end
    for _, line in ipairs(res.stdout) do
        if #line == 0 then
            table.insert(msg, "#")
        else
            table.insert(msg, "# " .. line)
        end
    end

    table.insert(msg, "#")
    local marker = [[------------------------ >8 ------------------------
Do not modify or remove the line above.
Everything below it will be ignored.]]
    for _, line in ipairs(vim.split(marker, "\n", { trimempty = true })) do
        if #line == 0 then
            table.insert(msg, "#")
        else
            table.insert(msg, "# " .. line)
        end
    end
    vim.list_extend(msg, staged.stdout)

    return msg
end

function M.commit(msg)
    local res = vim.system({ "git", "commit", "-F", "-" }, { cwd = M.root, text = true, stdin = msg }):wait()
    return {
        code = res.code,
        stdout = res.stdout and vim.split(res.stdout, '\n', { trimempty = true }) or {},
        stderr = res.stderr and vim.split(res.stderr, '\n', { trimempty = true }) or {},
    }
end

return M
