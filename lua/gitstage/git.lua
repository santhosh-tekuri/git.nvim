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
    local res = M.system { "git", "--no-pager", "status", "-uall", "--porcelain=v1" }
    return res.code == 0 and res.stdout or nil
end

function M.status_file(file)
    local res = M.system { "git", "--no-pager", "status", "-uall", "--porcelain=v1", file }
    return res.code == 0 and res.stdout[1] or nil
end

function M.diff(file, staged)
    local entry = M.status_file(file)
    if not entry then
        return nil
    end
    local cmd = { "git", "--no-pager", "diff" }
    if staged then
        vim.list_extend(cmd, { "--staged", file })
        local res = M.system(cmd)
        return res.code == 0 and res.stdout or nil
    else
        local status = entry:sub(2, 2)
        local untracked = status == '?'
        if untracked then
            vim.list_extend(cmd, { "--no-index", "/dev/null" })
        end
        table.insert(cmd, file)
        local res = M.system(cmd)
        if untracked then
            res.code = res.code == 0 and 1 or 0
        end
        return res.code == 0 and res.stdout or nil
    end
end

function M.restore(entry)
    local file = entry:sub(4)
    return M.system({ "git", "restore", "--staged", file })
end

function M.stage(patch)
    table.insert(patch, "")
    patch = table.concat(patch, '\n')
    local res = vim.system({ "git", "apply", "--cached", "-" }, { cwd = M.root, text = true, stdin = patch }):wait()
    return {
        code = res.code,
        stdout = res.stdout and vim.split(res.stdout, '\n', { trimempty = true }) or {},
        stderr = res.stderr and vim.split(res.stderr, '\n', { trimempty = true }) or {},
    }
end

return M
