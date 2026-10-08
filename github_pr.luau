-- GitHub state belongs to the host that owns the repository. Inventory blocks
-- share this cache so one sidebar per tab does not multiply gh requests.
local M = {}
local caches = {}
local STATUS_TTL_MS = 120000
local ERROR_TTL_MS = 30000
local REPO_TTL_MS = 600000

local gh = tern.fs.exists("/opt/homebrew/bin/gh") and "/opt/homebrew/bin/gh"
	or (tern.fs.exists("/usr/bin/gh") and "/usr/bin/gh") or "gh"

local function trim(value)
	return string.gsub(value or "", "%s+$", "")
end

local function error_text(result, fallback)
	local detail = trim(result.stderr ~= "" and result.stderr or result.stdout)
	return detail ~= "" and string.sub(detail, 1, 300) or fallback
end

local function decode(bytes)
	local ok, value = pcall(tern.json.decode, bytes)
	return ok and value or nil
end

local function repo_from_json(bytes)
	local value = decode(bytes)
	if type(value) ~= "table" or type(value.nameWithOwner) ~= "string"
		or type(value.url) ~= "string" or type(value.defaultBranchRef) ~= "table"
		or type(value.defaultBranchRef.name) ~= "string" then return nil end
	local owner, name = string.match(value.nameWithOwner, "^([^/]+)/([^/]+)$")
	local host, url_owner, url_name = string.match(value.url,
		"^https://([^/]+)/([^/]+)/([^/]+)/?$")
	if not owner or not name or not host or not url_owner or not url_name
		or string.lower(owner) ~= string.lower(url_owner)
		or string.lower(name) ~= string.lower(url_name) then return nil end
	return { url = string.gsub(value.url, "/$", ""), host = host,
		owner = owner, base = value.defaultBranchRef.name }
end

local function latest_pr(bytes, branch, owner, head)
	local body = trim(bytes)
	if body == "[]" then return { kind = "none" } end
	local ok, values = pcall(tern.json.decode, body)
	if not ok or type(values) ~= "table" then
		return nil, body == "" and "GitHub returned an empty PR response"
			or "Could not decode GitHub PR response: " .. tostring(values)
	end
	local best = nil
	for _, value in values do
		if type(value) == "table" and value.headRefName == branch
			and type(value.headRepositoryOwner) == "table"
			and type(value.headRepositoryOwner.login) == "string"
			and string.lower(value.headRepositoryOwner.login) == string.lower(owner)
			and type(value.url) == "string" and string.match(value.url, "^https://")
			and type(value.createdAt) == "string" then
			local kind = (value.state == "MERGED" or
				(value.mergedAt and value.mergedAt ~= tern.json.null)) and "merged"
				or (value.state == "OPEN" and (value.isDraft and "draft" or "open")
					or (value.state == "CLOSED" and "closed" or nil))
			-- An open PR still belongs to the branch while local commits are pending.
			-- A completed PR describes this worktree only at its last PR commit.
			if kind and ((kind == "open" or kind == "draft")
				or (type(value.headRefOid) == "string" and value.headRefOid == head)) then
				local candidate = { kind = kind, url = value.url, created = value.createdAt }
				if not best or ((kind == "open" or kind == "draft")
					and best.kind ~= "open" and best.kind ~= "draft")
					or ((kind == "open" or kind == "draft") == (best.kind == "open" or best.kind == "draft")
						and candidate.created > best.created) then
					best = candidate
				end
			end
		end
	end
	return best or { kind = "none" }
end

local function cache_for(common_dir)
	local cache = caches[common_dir]
	if cache then return cache end
	cache = { watchers = {}, branches = {}, queue = {}, wanted = {}, heads = {},
		repo = nil, repo_error = nil, repo_checked = 0, repo_loading = false,
		running = false, push_busy = {} }
	caches[common_dir] = cache
	return cache
end

local function notify(cache)
	local live = {}
	for _, pane in tern.pane.list() do live[pane.pane] = true end
	for pane, cx in cache.watchers do
		if live[pane] then cx:render() else cache.watchers[pane] = nil end
	end
end

local function push_remote_owner(url)
	local host, owner = string.match(url, "^git@([^:]+):([^/]+)/[^/]+%.git$")
	if not host then host, owner = string.match(url, "^git@([^:]+):([^/]+)/[^/]+$") end
	if not host then host, owner = string.match(url, "^https?://([^/]+)/([^/]+)/[^/]+") end
	if not host then host, owner = string.match(url, "^ssh://[^@]+@([^/]+)/([^/]+)/[^/]+") end
	return host, owner
end

local drain
drain = function(cache)
	if cache.running or not cache.repo or #cache.queue == 0 then return end
	local branch = table.remove(cache.queue, 1)
	local record = cache.branches[branch]
	if not record then return drain(cache) end
	record.queued = false
	record.loading = true
	cache.running = true
	local path = cache.paths[branch]
	local head = cache.heads[branch]
	local function finish(value, err)
		record.loading = false
		cache.running = false
		if cache.branches[branch] ~= record or cache.heads[branch] ~= head then
			if cache.branches[branch] == record then M.request_branch(cache, branch, false) end
			drain(cache)
			return
		end
		record.checked = tern.now()
		record.value = value
		record.error = err
		notify(cache)
		drain(cache)
	end
	local function run(argv, options, callback)
		local ok, err = pcall(function() tern.process.run(argv, options, callback) end)
		if not ok then finish(nil, tostring(err)) end
	end
	if not path then return finish(nil, "Worktree path is unavailable") end
	run({ "git", "-C", path, "for-each-ref",
		"--format=%(push:remotename)|%(upstream:remotename)", "refs/heads/" .. branch },
		{ timeout_ms = 10000 }, function(ref)
			if ref.status ~= 0 then return finish(nil, error_text(ref, "Cannot find push remote")) end
			local push_remote, tracking_remote = string.match(trim(ref.stdout), "^([^|]*)|([^|]*)$")
			if not push_remote then return finish(nil, "Cannot determine the branch's push remote") end
			local remote = push_remote ~= "" and push_remote or
				(tracking_remote ~= "" and tracking_remote or "origin")
			run({ "git", "-C", path, "remote", "get-url", "--push", remote },
				{ timeout_ms = 10000 }, function(remote_url)
					if remote_url.status ~= 0 then
						return finish(nil, error_text(remote_url, "No push remote configured"))
					end
					local host, owner = push_remote_owner(trim(remote_url.stdout))
					if not host or string.lower(host) ~= string.lower(cache.repo.host) then
						return finish(nil, "Push remote is not on " .. cache.repo.host)
					end
					local argv = { gh, "pr", "list", "--head", branch, "--state", "all",
						"--limit", "100", "--json",
						"headRefName,headRefOid,headRepositoryOwner,url,state,mergedAt,createdAt,isDraft" }
					run(argv, { cwd = path, timeout_ms = 20000 }, function(result)
						if result.status ~= 0 then
							return finish(nil, error_text(result, "Could not check GitHub PRs"))
						end
						local value, parse_error = latest_pr(result.stdout, branch, owner, head)
						finish(value, parse_error)
					end)
				end)
		end)
end

function M.request_branch(cache, branch, force)
	local record = cache.branches[branch]
	if not record then
		record = { checked = 0, loading = false, queued = false }
		cache.branches[branch] = record
	end
	if record.loading or record.queued then return end
	local ttl = record.error and ERROR_TTL_MS or STATUS_TTL_MS
	if not force and record.checked > 0 and tern.now() - record.checked < ttl then return end
	record.queued = true
	table.insert(cache.queue, branch)
	drain(cache)
end

local function request_repo(cache)
	if cache.repo_loading then return end
	if cache.repo_checked > 0 then
		local ttl = cache.repo_error and ERROR_TTL_MS or REPO_TTL_MS
		if tern.now() - cache.repo_checked < ttl then return end
	end
	cache.repo_loading = true
	local ok, err = pcall(function()
		tern.process.run({ gh, "repo", "view", "--json", "nameWithOwner,url,defaultBranchRef" },
			{ cwd = cache.cwd, timeout_ms = 20000 }, function(result)
				cache.repo_loading = false
				cache.repo_checked = tern.now()
				if result.status == 0 then
					cache.repo = repo_from_json(result.stdout)
					cache.repo_error = cache.repo and nil or "GitHub returned invalid repository data"
				else
					cache.repo = nil
					cache.repo_error = error_text(result, "No GitHub repository is configured")
				end
				if cache.repo then
					for branch in cache.wanted do
						if branch ~= cache.repo.base then M.request_branch(cache, branch, false) end
					end
				end
				notify(cache)
			end)
	end)
	if not ok then
		cache.repo_loading = false
		cache.repo_checked = tern.now()
		cache.repo = nil
		cache.repo_error = tostring(err)
		notify(cache)
	end
end

function M.attach(common_dir, cwd, entries, cx, force)
	local cache = cache_for(common_dir)
	cache.cwd = cwd
	cache.watchers[cx.pane] = cx
	local wanted = {}
	local paths = {}
	local heads = {}
	for _, entry in entries do
		if entry.branch then
			local branch = string.gsub(entry.branch, "^refs/heads/", "")
			wanted[branch] = true
			paths[branch] = entry.path
			heads[branch] = entry.head
		end
	end
	cache.wanted = wanted
	cache.paths = paths
	cache.heads = heads
	for branch in cache.branches do
		if not wanted[branch] then cache.branches[branch] = nil end
	end
	for branch, record in cache.branches do
		if record.head ~= heads[branch] then
			record.head = heads[branch]
			record.checked = 0
			record.value = nil
		end
	end
	if force then
		cache.repo_checked = 0
		for _, record in cache.branches do record.checked = 0 end
	end
	request_repo(cache)
	if cache.repo then
		for branch in cache.wanted do
			if branch ~= cache.repo.base then M.request_branch(cache, branch, false) end
		end
	end
end

function M.status(common_dir, entry)
	if not entry.branch then return { kind = "detached" } end
	local cache = caches[common_dir]
	if not cache then return { kind = "checking" } end
	if cache.repo_error and not cache.repo then
		return { kind = "unavailable", error = cache.repo_error }
	end
	if not cache.repo then return { kind = "checking" } end
	local branch = string.gsub(entry.branch, "^refs/heads/", "")
	if branch == cache.repo.base then return { kind = "base" } end
	local record = cache.branches[branch]
	if not record or not record.value then
		return { kind = record and record.error and "unavailable" or "checking",
			error = record and record.error or nil }
	end
	if record.error then return { kind = "unavailable", error = record.error } end
	return record.value
end

local function encode(value)
	return (string.gsub(value, "[^%w%-._~]", function(char)
		return string.format("%%%02X", string.byte(char))
	end))
end

local function open_github(cx, url)
	local encoded = string.gsub(url, ".", function(byte)
		return string.format("%02x", string.byte(byte))
	end)
	cx:open("tern-worktree://github/" .. encoded)
end

local function create_url(repo, branch, push_owner)
	local head = push_owner and string.lower(push_owner) ~= string.lower(repo.owner)
		and encode(push_owner) .. ":" .. encode(branch) or encode(branch)
	return repo.url .. "/compare/" .. encode(repo.base) .. "..." .. head .. "?quick_pull=1"
end

local function fail_push(cache, branch, cx, message)
	cache.push_busy[branch] = nil
	cx:toast("error", "Could not open PR", message)
	notify(cache)
end

local function run_push_step(cache, branch, cx, argv, timeout_ms, callback)
	local ok, err = pcall(function()
		tern.process.run(argv, { timeout_ms = timeout_ms }, callback)
	end)
	if not ok then fail_push(cache, branch, cx, tostring(err)) end
end

local function push_and_open(cache, entry, cx)
	local branch = string.gsub(entry.branch, "^refs/heads/", "")
	if cache.push_busy[branch] then return end
	local repo = cache.repo
	cache.push_busy[branch] = true
	notify(cache)
	local path = entry.path
	run_push_step(cache, branch, cx,
		{ "git", "-C", path, "symbolic-ref", "--quiet", "--short", "HEAD" },
		10000, function(current)
			if current.status ~= 0 or trim(current.stdout) ~= branch then
				fail_push(cache, branch, cx, "This worktree no longer has branch " .. branch)
				return
			end
			run_push_step(cache, branch, cx, { "git", "-C", path, "for-each-ref",
				"--format=%(push:remotename)|%(upstream:remotename)", "refs/heads/" .. branch },
				10000, function(upstream)
					if upstream.status ~= 0 then
						fail_push(cache, branch, cx, error_text(upstream, "Cannot find push remote"))
						return
					end
					local push_remote, tracking_remote = string.match(trim(upstream.stdout), "^([^|]*)|([^|]*)$")
					if not push_remote then
						fail_push(cache, branch, cx, "Cannot determine the branch's push remote")
						return
					end
					local remote = push_remote ~= "" and push_remote or
						(tracking_remote ~= "" and tracking_remote or "origin")
					run_push_step(cache, branch, cx,
						{ "git", "-C", path, "remote", "get-url", "--push", remote },
						10000, function(remote_url)
							if remote_url.status ~= 0 then
								fail_push(cache, branch, cx, error_text(remote_url, "No push remote configured"))
								return
							end
							local host, owner = push_remote_owner(trim(remote_url.stdout))
							if not host or string.lower(host) ~= string.lower(repo.host) then
								fail_push(cache, branch, cx, "Push remote is not on " .. repo.host)
								return
							end
							local argv = { "git", "-C", path, "push" }
							if tracking_remote == "" then table.insert(argv, "-u") end
							table.insert(argv, remote)
							table.insert(argv, "HEAD:refs/heads/" .. branch)
							run_push_step(cache, branch, cx, argv, 120000, function(pushed)
								cache.push_busy[branch] = nil
								notify(cache)
								if pushed.status ~= 0 then
									cx:toast("error", "Could not push PR branch",
										error_text(pushed, "Git push failed"))
									return
								end
								open_github(cx, create_url(repo, branch, owner))
							end)
						end)
				end)
		end)
end

function M.activate(common_dir, entry, cx)
	local cache = caches[common_dir]
	local status = M.status(common_dir, entry)
	if status.kind == "base" and cache and cache.repo then
		open_github(cx, cache.repo.url .. "/pulls")
		return
	end
	if status.url then open_github(cx, status.url); return end
	if status.kind == "none" and cache and cache.repo then
		push_and_open(cache, entry, cx)
	elseif status.kind == "unavailable" then
		cx:toast("error", "GitHub PR status unavailable", status.error or "Refresh and try again")
	else
		cx:toast("info", "No PR action for this worktree", status.kind)
	end
end

function M.busy(common_dir, entry)
	local cache = caches[common_dir]
	local branch = entry.branch and string.gsub(entry.branch, "^refs/heads/", "")
	return cache and branch and cache.push_busy[branch] or false
end

return M
