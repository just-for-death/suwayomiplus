-- Boundary: active download subprocess lifecycle.
--
-- Responsibility: own in-memory active jobs, launch downloader workers, poll
-- progress files, handle terminal states, and schedule follow-up polls.
-- Owned state: active job table plus poll-scheduled flag; persisted state still
-- flows through the queue facade and JobStore.
-- Dependencies: queue facade callbacks, KOReader subprocess utilities, progress
-- files, and the plugin i18n facade.
-- External data: worker progress files and subprocess status are treated as
-- untrusted until normalized into queue status and persisted job records.

local I18n = require("suwayomi/i18n")
local ProgressFile = require("suwayomi/downloads/progress_file")

local ActiveJobs = {}
ActiveJobs.__index = ActiveJobs

local REAP_ATTEMPTS = 10
local REAP_INTERVAL_SECONDS = 1

function ActiveJobs:new(options)
    options = options or {}
    local active_jobs = {
        queue = options.queue,
        jobs = options.jobs or {},
        poll_scheduled = false,
    }
    setmetatable(active_jobs, self)
    return active_jobs
end

function ActiveJobs:getCount()
    local count = 0
    for _ in pairs(self.jobs or {}) do
        count = count + 1
    end
    return count
end

function ActiveJobs:getJob(key)
    return self.jobs and self.jobs[key] or nil
end

function ActiveJobs:setJob(job)
    self.jobs = self.jobs or {}
    self.jobs[job.key or self.queue:getKey(job.manga, job.chapter)] = job
end

function ActiveJobs:removeJob(job)
    if not self.jobs then
        return
    end
    self.jobs[job.key or self.queue:getKey(job.manga, job.chapter)] = nil
end

function ActiveJobs:appendSnapshotJobs(snapshot)
    -- Snapshot construction stays here so queue.lua does not need to know the
    -- active job table shape.
    for _index, job in pairs(self.jobs or {}) do
        table.insert(snapshot.active, self.queue:copySnapshotJob(job, "downloading"))
    end
end

function ActiveJobs:schedulePoll()
    if self.poll_scheduled or self:getCount() == 0 then
        return
    end

    self.poll_scheduled = true
    self.queue.ui_manager:scheduleIn(self.queue.POLL_INTERVAL_SECONDS, function()
        self.queue:poll()
    end)
end

function ActiveJobs:writeProgressFallback(progress_path, state, current, total, path, error_message)
    return ProgressFile.writeFallback(progress_path, state, current, total, path, error_message)
end

function ActiveJobs:runDownloaderJob(queued)
    if queued.downloader.downloadChapterWithProgress then
        queued.downloader:downloadChapterWithProgress(
            queued.credentials,
            queued.download_directory,
            queued.manga,
            queued.chapter,
            queued.progress_path
        )
        return
    end

    local result = queued.downloader:startChapterDownload(queued.credentials, queued.download_directory, queued.manga, queued.chapter)
    if not result.ok or result.skipped then
        local state = result.skipped and "skipped" or (result.ok and "downloaded" or "failed")
        self:writeProgressFallback(queued.progress_path, state, result.ok and 1 or 0, result.ok and 1 or 0, result.path, result.error)
        return
    end

    repeat
        result = queued.downloader:downloadNextPage(result.job)
        self:writeProgressFallback(
            queued.progress_path,
            result.ok and (result.done and "downloaded" or "downloading") or "failed",
            result.current or 0,
            result.total or 0,
            result.path,
            result.error
        )
    until not result.ok or result.done
    os.exit(0)
end

function ActiveJobs:stepInlineJob(queued)
    local queue = self.queue
    if not queued or queued.cancelled then
        return
    end

    if not queued.download_job then
        local start_res = queued.downloader:startChapterDownload(
            queued.credentials,
            queued.download_directory,
            queued.manga,
            queued.chapter
        )
        if not start_res.ok or start_res.skipped then
            local final_state = start_res.skipped and "skipped" or (start_res.ok and "downloaded" or "failed")
            self:writeProgressFallback(
                queued.progress_path,
                final_state,
                start_res.ok and 1 or 0,
                start_res.ok and 1 or 0,
                start_res.path,
                start_res.error
            )
            return
        end
        queued.download_job = start_res.job
        queued.total_pages = start_res.total or #start_res.job.pages
    end

    local page_res = queued.downloader:downloadNextPage(queued.download_job)
    local page_state = page_res.ok and (page_res.done and "downloaded" or "downloading") or "failed"
    self:writeProgressFallback(
        queued.progress_path,
        page_state,
        page_res.current or 0,
        page_res.total or queued.total_pages or 0,
        page_res.path,
        page_res.error
    )

    if page_res.ok and not page_res.done then
        queue.ui_manager:scheduleIn(0.05, function()
            self:stepInlineJob(queued)
        end)
    else
        self:finishFromProgress(queued, {
            state = page_res.ok and "downloaded" or "failed",
            current = page_res.current or 0,
            total = page_res.total or queued.total_pages or 0,
            path = page_res.path,
            error = page_res.error,
        })
        if queue.process then
            queue:process()
        end
    end
end

function ActiveJobs:startQueuedJob(queued)
    local queue = self.queue
    local key = queued.key or queue:getKey(queued.manga, queued.chapter)
    if self:getJob(key) then
        queue:setStatus(queued.manga, queued.chapter, { state = "downloading", purpose = queued.purpose })
        return false
    end
    queued.key = key
    queued.started_at = queue.now()
    queued.last_progress_at = queued.started_at
    queued.last_progress_current = nil
    queued.last_progress_state = nil
    queued.progress_path = queue:buildProgressPath(queued.manga, queued.chapter, queued.download_directory)
    os.remove(queued.progress_path)
    queued.credentials = queued.credentials or queue:getCredentialsForJob()
    queue:upsertPersistentJob(queue:buildPersistentJob(queued.manga, queued.chapter, queued.download_directory, "downloading", {
        started_at = queued.started_at,
        last_progress_at = queued.last_progress_at,
        progress = {
            state = "downloading",
            current = 0,
            total = 0,
            updated_at = queued.last_progress_at,
        },
    }))

    queued.pid = 999999 -- dummy PID for active job tracking
    self:setJob(queued)
    queue:setStatus(queued.manga, queued.chapter, {
        state = "downloading",
        current = 0,
        total = 0,
        purpose = queued.purpose,
    })

    queue.ui_manager:scheduleIn(0.05, function()
        self:stepInlineJob(queued)
    end)
    return true
end

function ActiveJobs:process()
    local queue = self.queue
    local started_at = os.time()
    local ok_socket, socket = pcall(require, "socket")
    if ok_socket and socket and socket.gettime then
        started_at = socket.gettime()
    end
    local started_count = 0
    while self:getCount() < queue.max_active_chapters do
        local queued = table.remove(queue.items, 1)
        if not queued then
            break
        end

        if self:startQueuedJob(queued) then
            started_count = started_count + 1
        end
    end

    self:schedulePoll()
    local finished_at = os.time()
    if ok_socket and socket and socket.gettime then
        finished_at = socket.gettime()
    end
    queue:logDebug({
        operation = "downloadQueue.process",
        event = "end",
        started_count = started_count,
        active_count = self:getCount(),
        queued_count = #(queue.items or {}),
        elapsed_ms = math.floor(((finished_at - started_at) * 1000) + 0.5),
    })
end

-- Workers are forked without double_fork, so the parent has to keep calling
-- isSubProcessDone after a kill or the child stays a zombie for the session.
function ActiveJobs:reapSubProcess(pid, attempts_left)
    local queue = self.queue
    if not pid or not queue or not queue.ffi_util or not queue.ffi_util.isSubProcessDone then
        return
    end

    local ok, done = pcall(queue.ffi_util.isSubProcessDone, pid)
    if ok and done then
        return
    end
    attempts_left = (attempts_left or REAP_ATTEMPTS) - 1
    if attempts_left <= 0 or not queue.ui_manager or not queue.ui_manager.scheduleIn then
        return
    end
    queue.ui_manager:scheduleIn(REAP_INTERVAL_SECONDS, function()
        self:reapSubProcess(pid, attempts_left)
    end)
end

function ActiveJobs:terminateJob(active)
    local queue = self.queue
    if not active or not active.pid then
        return
    end
    if queue and queue.ffi_util and queue.ffi_util.terminateSubProcess then
        pcall(queue.ffi_util.terminateSubProcess, active.pid)
    end
    self:reapSubProcess(active.pid)
end

function ActiveJobs:finishWithFailure(active, message)
    local queue = self.queue
    local failure_message = queue:formatFailureMessage(active.manga, active.chapter, message or I18n.t("Chapter download failed."))
    self:terminateJob(active)
    self:removeJob(active)
    if queue.cleanupInterruptedDownload then
        queue:cleanupInterruptedDownload(active)
    end
    os.remove(active.progress_path)
    queue:setStatus(active.manga, active.chapter, { state = "failed" })
    queue:upsertPersistentJob(queue:buildPersistentJob(active.manga, active.chapter, active.download_directory, "failed", {
        started_at = active.started_at,
        last_progress_at = queue.now(),
        progress = {
            state = "failed",
            current = active.last_progress_current or 0,
            total = active.last_progress_total or 0,
            path = active.last_progress_path,
            error = failure_message,
            updated_at = queue.now(),
        },
    }))
    queue.onMessage(failure_message)
end

function ActiveJobs:finishWithCancel(active, options)
    options = options or {}
    local queue = self.queue
    self:terminateJob(active)
    self:removeJob(active)
    if queue.cleanupInterruptedDownload then
        queue:cleanupInterruptedDownload(active)
    end
    os.remove(active.progress_path)
    queue:clearStatus(active.manga, active.chapter)
    if options.process ~= false then
        self:process()
    end
end

function ActiveJobs:cancelAll()
    local active_jobs = {}
    for _index, active in pairs(self.jobs or {}) do
        table.insert(active_jobs, active)
    end

    for _index, active in ipairs(active_jobs) do
        self:finishWithCancel(active, { process = false })
    end
    self:process()
    return #active_jobs
end

function ActiveJobs:recordProgress(active, progress)
    local queue = self.queue
    if not progress or not progress.state then
        return
    end

    if progress.current ~= active.last_progress_current or progress.state ~= active.last_progress_state then
        active.last_progress_at = queue.now()
        active.last_progress_current = progress.current
        active.last_progress_total = progress.total
        active.last_progress_path = progress.path
        active.last_progress_error = progress.error
        active.last_progress_state = progress.state
        queue:upsertPersistentJob(queue:buildPersistentJob(active.manga, active.chapter, active.download_directory, progress.state, {
            started_at = active.started_at,
            last_progress_at = active.last_progress_at,
            progress = {
                state = progress.state,
                current = progress.current,
                total = progress.total,
                path = progress.path,
                error = progress.error,
                updated_at = active.last_progress_at,
            },
        }))
    end
    queue:setStatus(active.manga, active.chapter, {
        state = progress.state,
        current = progress.current,
        total = progress.total,
        purpose = active.purpose,
    })
end

function ActiveJobs:finishFromProgress(active, progress)
    local queue = self.queue
    self:removeJob(active)
    os.remove(active.progress_path)
    if progress and (progress.state == "downloaded" or progress.state == "skipped") then
        local archive_path = queue:getExistingArchivePath(active, progress)
        if not archive_path then
            local message = queue:formatFailureMessage(
                active.manga,
                active.chapter,
                I18n.t("Chapter download finished but the archive is missing.")
            )
            queue:setStatus(active.manga, active.chapter, { state = "failed" })
            queue:upsertPersistentJob(queue:buildPersistentJob(active.manga, active.chapter, active.download_directory, "failed", {
                started_at = active.started_at,
                last_progress_at = active.last_progress_at or queue.now(),
                progress = {
                    state = "failed",
                    current = progress.current,
                    total = progress.total,
                    path = progress.path,
                    error = message,
                    updated_at = active.last_progress_at or queue.now(),
                },
            }))
            queue.onMessage(message)
            return
        end
        queue:removePersistentJob(active.key or queue:getKey(active.manga, active.chapter))
        queue:notifyChapterArchiveReady(
            active.manga,
            active.chapter,
            archive_path
        )
    elseif progress and progress.state == "failed" and queue:jobArchiveExists(active, progress) then
        -- A downloader may report failure after writing a valid CBZ. Keep the
        -- user-facing state aligned with the archive that now exists on disk.
        local archive_path = queue:getExistingArchivePath(active, progress)
        queue:removePersistentJob(active.key or queue:getKey(active.manga, active.chapter))
        queue:setStatus(active.manga, active.chapter, {
            state = "downloaded",
            current = progress.current,
            total = progress.total,
        })
        queue:notifyChapterArchiveReady(active.manga, active.chapter, archive_path)
    elseif progress and progress.state == "failed" then
        local message = queue:formatFailureMessage(
            active.manga,
            active.chapter,
            progress.error or I18n.t("Chapter download failed.")
        )
        queue:upsertPersistentJob(queue:buildPersistentJob(active.manga, active.chapter, active.download_directory, "failed", {
            started_at = active.started_at,
            last_progress_at = active.last_progress_at or queue.now(),
            progress = {
                state = "failed",
                current = progress.current,
                total = progress.total,
                path = progress.path,
                error = message,
                updated_at = active.last_progress_at or queue.now(),
            },
        }))
        queue.onMessage(message)
    end
end

function ActiveJobs:finishWithoutProgress(active)
    local queue = self.queue
    self:removeJob(active)
    os.remove(active.progress_path)
    local archive_path = queue:getExistingArchivePath(active)
    if archive_path then
        queue:removePersistentJob(active.key or queue:getKey(active.manga, active.chapter))
        queue:setStatus(active.manga, active.chapter, {
            state = "downloaded",
            current = active.last_progress_current,
            total = active.last_progress_total,
        })
        queue:notifyChapterArchiveReady(active.manga, active.chapter, archive_path)
        return
    end

    queue:setStatus(active.manga, active.chapter, { state = "failed" })
    local message = queue:formatFailureMessage(active.manga, active.chapter, I18n.t("Chapter download failed."))
    queue:upsertPersistentJob(queue:buildPersistentJob(active.manga, active.chapter, active.download_directory, "failed", {
        started_at = active.started_at,
        last_progress_at = queue.now(),
        progress = {
            state = "failed",
            current = active.last_progress_current or 0,
            total = active.last_progress_total or 0,
            path = active.last_progress_path,
            error = message,
            updated_at = queue.now(),
        },
    }))
    queue.onMessage(message)
end

function ActiveJobs:poll()
    local queue = self.queue
    local started_at = os.time()
    local ok_socket, socket = pcall(require, "socket")
    if ok_socket and socket and socket.gettime then
        started_at = socket.gettime()
    end
    self.poll_scheduled = false
    if self:getCount() == 0 then
        return
    end

    local active_jobs = {}
    for _index, active in pairs(self.jobs or {}) do
        table.insert(active_jobs, active)
    end

    for index = 1, #active_jobs do
        local active = active_jobs[index]
        local progress = ProgressFile.read(active.progress_path)
        self:recordProgress(active, progress)

        if queue.now() - (active.last_progress_at or active.started_at or queue.now()) > queue.WATCHDOG_TIMEOUT_SECONDS then
            -- The worker may have died without writing terminal progress. The
            -- watchdog converts that silent active state into a recoverable
            -- failed job instead of leaving a permanent "downloading" row.
            self:finishWithFailure(active, I18n.t("Chapter download timed out."))
        else
            local done = queue.ffi_util.isSubProcessDone(active.pid)
            local terminal = progress and (progress.state == "downloaded" or progress.state == "skipped" or progress.state == "failed")
            if terminal or done then
                if terminal then
                    self:finishFromProgress(active, progress)
                    if not done then
                        -- The worker wrote its final progress but has not exited
                        -- yet; the job is gone from the table, so reaping has to
                        -- continue on its own.
                        self:reapSubProcess(active.pid)
                    end
                else
                    self:finishWithoutProgress(active)
                end
            end
        end
    end

    self:process()
    local finished_at = os.time()
    if ok_socket and socket and socket.gettime then
        finished_at = socket.gettime()
    end
    queue:logDebug({
        operation = "downloadQueue.poll",
        event = "end",
        polled_count = #active_jobs,
        active_count = self:getCount(),
        queued_count = #(queue.items or {}),
        elapsed_ms = math.floor(((finished_at - started_at) * 1000) + 0.5),
    })
end

return ActiveJobs
