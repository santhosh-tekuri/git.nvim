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

function M.diff(entry, staged)
    local cmd = { "git", "--no-pager", "diff" }
    local file = entry:sub(4)
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

return M
