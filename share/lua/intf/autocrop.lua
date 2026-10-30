--[[ Auto-crop black bars built into a video file.

Samples frames across a local file with ffmpeg cropdetect, then crops only
the area that is black in every sample. Picture is never cut, so a frame
that is brighter or taller than the rest widens the crop instead of losing
content.

Enabled through vlcrc: extraintf=luaintf and lua-intf=autocrop
]]

local FFMPEG = (os.getenv("HOME") or "") .. "/homebrew/bin/ffmpeg"
local SAMPLE_POINTS = { 0.10, 0.25, 0.40, 0.55, 0.70, 0.85 }
local MIN_BAR_FRACTION = 0.01

local function log(msg)
    vlc.msg.info("[autocrop] " .. msg)
end

local function shell_quote(s)
    return "'" .. s:gsub("'", "'\\''") .. "'"
end

local function detect_at(path, seconds)
    local cmd = string.format(
        "%s -hide_banner -nostdin -ss %d -i %s -map 0:v:0 -frames:v 12 " ..
        "-vf cropdetect=limit=24:round=2:reset=0 -f null - 2>&1",
        shell_quote(FFMPEG), seconds, shell_quote(path))
    local pipe = io.popen(cmd)
    if not pipe then return nil end
    local w, h, x, y, full_w, full_h
    for line in pipe:lines() do
        local a, b, c, d = line:match("crop=(%d+):(%d+):(%d+):(%d+)")
        if a then w, h, x, y = tonumber(a), tonumber(b), tonumber(c), tonumber(d) end
        if not full_w and line:match("Video:") then
            local fw, fh = line:match("[ ,](%d%d+)x(%d%d+)[ ,]")
            full_w, full_h = tonumber(fw), tonumber(fh)
        end
    end
    pipe:close()
    return w, h, x, y, full_w, full_h
end

-- Union of every sample, so anything picture in any sample stays visible
local function detect_crop(path, duration)
    local left, top, right, bottom, width, height
    for _, point in ipairs(SAMPLE_POINTS) do
        local w, h, x, y, full_w, full_h = detect_at(path, math.floor(duration * point))
        if w then
            width, height = full_w or width, full_h or height
            left = math.min(left or x, x)
            top = math.min(top or y, y)
            right = math.max(right or x + w, x + w)
            bottom = math.max(bottom or y + h, y + h)
        end
    end
    if not left or not width then return nil end
    return right - left, bottom - top, left, top, width, height
end

local function current_uri()
    if not vlc.object.input() then return nil end
    local item = vlc.input.item()
    return item and item:uri(), item
end

-- Restart so the new video output is built with the settings below, resuming
-- where playback was
local function restart_at(time)
    vlc.playlist.stop()
    while vlc.object.input() do
        vlc.misc.mwait(vlc.misc.mdate() + 50000)
    end
    vlc.playlist.play()
    while not vlc.object.input() do
        vlc.misc.mwait(vlc.misc.mdate() + 50000)
    end
    vlc.var.set(vlc.object.input(), "time", time)
end

local function apply_crop(uri, item)
    local path = vlc.strings.decode_uri(uri):gsub("^file://", "")
    local w, h, x, y, width, height = detect_crop(path, item:duration())
    if not w then
        log("no detection result for " .. path)
        return
    end

    log(string.format("detected %dx%d+%d+%d in %dx%d", w, h, x, y, width, height))
    local filter, aspect = "", ""
    if (width - w) / width >= MIN_BAR_FRACTION or
       (height - h) / height >= MIN_BAR_FRACTION then
        -- croppadd keeps subtitles centred, the vout "crop" variable shifts
        -- them up and left. VLC scales its output back to the full frame, so
        -- the aspect ratio has to be set to the cropped shape. Per-item
        -- options are ignored for filters, hence the playlist variables.
        filter = string.format(
            "croppadd{croptop=%d,cropbottom=%d,cropleft=%d,cropright=%d}",
            y, height - h - y, x, width - w - x)
        aspect = string.format("%d:%d", w, h)
    end

    local playlist = vlc.object.playlist()
    if vlc.var.get(playlist, "video-filter") == filter then
        log("crop already correct")
        return
    end

    -- ffmpeg may run for a while, the user can have moved on by now
    if current_uri() == uri then
        vlc.var.set(playlist, "video-filter", filter)
        vlc.var.set(playlist, "aspect-ratio", aspect)
        restart_at(vlc.var.get(vlc.object.input(), "time"))
        log("crop applied: " .. filter)
    end
end

vlc.var.create(vlc.object.playlist(), "aspect-ratio", "")

local handled
while true do
    local uri, item = current_uri()
    if uri ~= handled and uri and uri:match("^file://") and
       item:duration() > 0 and vlc.object.vout() then
        handled = uri
        apply_crop(uri, item)
    end
    vlc.misc.mwait(vlc.misc.mdate() + 250000)
end
