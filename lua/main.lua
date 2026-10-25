--[[ zen-conky — system dashboard for the ASUS Zenbook Duo ScreenPad Plus.

Everything is drawn with cairo in a 1440x432 logical canvas that is scaled
to the conky window, so the same layout fits the 2880x864 panel at native
resolution or any other ultra-wide output.

Layout: CARDS at the bottom of this file. Each card is a function drawing
in its own local coordinate space (0,0 = card top-left).
]]

local here = debug.getinfo(1, 'S').source:match('^@(.*/)')
    or ((os.getenv('ZEN_DIR') or '.') .. '/lua/')
package.path = here .. '?.lua;' .. package.path

require 'cairo'
-- Draw through cairo_xlib on X11. conky 1.24's conky_surface() is only a
-- fallback: in 1.24.2 it can point at a stale surface after conky re-creates
-- its window at startup, and nothing appears (conky logs a deprecation note).
local HAVE_XLIB = pcall(require, 'cairo_xlib')

local T = require 'zen.theme'
local D = require 'zen.draw'
local S = require 'zen.sensors'

local BASE_W, BASE_H = 1440, 432
local PAD = 6
local GCAP = 120 -- samples kept in history graphs

local NCPU  = S.ncpu()
local MODEL = S.cpu_model()
local DISK  = os.getenv('ZEN_DISK') or S.root_disk()
local MOUNT = os.getenv('ZEN_MOUNT') or '/'
-- ZEN_PRIVATE=1 hides hostname, SSID and IP (screenshots, streaming).
local PRIVATE = (os.getenv('ZEN_PRIVATE') or '') ~= '' and os.getenv('ZEN_PRIVATE') ~= '0'

local P = conky_parse
local V = { cores = {} }
local H = { cpu = {}, temp = {}, down = {}, up = {}, rd = {}, wr = {} }

-- Helpers -----------------------------------------------------------------

local function num(s) return tonumber((s or ''):match('%-?[%d%.]+')) or 0 end

local function load_color(p)
    if p >= 90 then return T.red elseif p >= 70 then return T.orange end
    return T.blue
end

local function temp_color(t)
    if not t then return T.faint end
    if t >= 90 then return T.red elseif t >= 75 then return T.orange elseif t >= 60 then return T.yellow end
    return T.green
end

local function fmt_temp(t) return t and string.format('%.0f°C', t) or '—' end

local function rate(b)
    local u, i = { 'B/s', 'KB/s', 'MB/s', 'GB/s' }, 1
    while b >= 1000 and i < #u do b, i = b / 1024, i + 1 end
    return string.format((i > 1 and b < 10) and '%.1f %s' or '%.0f %s', b, u[i])
end

local function trim(s) return ((s or ''):gsub('^%s+', ''):gsub('%s+$', '')) end

-- Touch ---------------------------------------------------------------------
-- Cards register tappable rectangles while drawing; conky_zen_mouse maps the
-- event back into the logical canvas and fires the matching action. The
-- ScreenPad's touchscreen reaches X11 clients as emulated left clicks.

local HITS = {}
local ORIGIN = { x = 0, y = 0 }       -- current card offset while drawing
local VIEW = { ox = 0, oy = 0, s = 1 } -- canvas -> window transform
local UI = {
    pressed = nil,      -- { id, frames } highlight after a tap
    toast = nil,        -- { text, err, frames }
    pending = nil,      -- { profile, frames } optimistic profile while asusd applies it
    proc_sort = 'cpu',  -- 'cpu' | 'mem'
}

local function hit(id, x, y, w, h, fn)
    HITS[#HITS + 1] = { id = id, x = ORIGIN.x + x, y = ORIGIN.y + y, w = w, h = h, fn = fn }
end

local function toast(text, err)
    UI.toast = { text = text, err = err, frames = 8 }
end

local function button(cr, id, x, y, w, h, label, active, color, fn)
    local down = UI.pressed and UI.pressed.id == id
    color = color or T.blue
    D.rrect(cr, x + 0.5, y + 0.5, w - 1, h - 1, 8)
    if active then
        D.set(cr, color, down and 0.55 or 0.25)
    else
        D.set(cr, down and T.border or T.track, down and 1 or 0.6)
    end
    cairo_fill_preserve(cr)
    cairo_set_line_width(cr, 1)
    D.set(cr, active and color or T.border)
    cairo_stroke(cr)
    D.text(cr, label, x + w / 2, y + h / 2 + 4, { size = 11, bold = true, align = 'center',
        color = active and T.fg or T.dim })
    hit(id, x, y, w, h, fn)
end

-- Sampling (once per second) --------------------------------------------------

local function sample(updates, interval)

    V.cpu = num(P('${cpu cpu0}'))
    for i = 1, NCPU do V.cores[i] = num(P('${cpu cpu' .. i .. '}')) end
    V.freq_avg, V.freq_max = S.cpufreq(NCPU)
    V.load1, V.load5, V.load15 = S.loadavg()

    V.t_cpu  = S.temp('coretemp', 1)
    V.t_nvme = S.temp('nvme', 1)
    V.t_wifi = S.temp('iwlwifi', 1)
    V.t_acpi = S.temp('acpitz', 1)
    V.fan_cpu, V.fan_gpu = S.fan('asus', 1), S.fan('asus', 2)

    V.memperc, V.mem, V.memmax = num(P('${memperc}')), P('${mem}'), P('${memmax}')
    V.swapperc, V.swap, V.swapmax = num(P('${swapperc}')), P('${swap}'), P('${swapmax}')

    V.fsperc = num(P('${fs_used_perc ' .. MOUNT .. '}'))
    V.fsused, V.fssize = P('${fs_used ' .. MOUNT .. '}'), P('${fs_size ' .. MOUNT .. '}')
    V.rd, V.wr = S.diskio(DISK, interval)

    V.iface = S.iface(os.time())
    if V.iface then
        local i = V.iface
        V.down = num(P('${downspeedf ' .. i .. '}')) * 1024
        V.up   = num(P('${upspeedf ' .. i .. '}')) * 1024
        V.addr = P('${addr ' .. i .. '}')
        V.tdown, V.tup = P('${totaldown ' .. i .. '}'), P('${totalup ' .. i .. '}')
        V.essid = S.is_wireless(i) and trim(P('${wireless_essid ' .. i .. '}')) or 'Wired'
    else
        V.down, V.up = 0, 0
    end

    V.bat = S.battery()
    V.gpu = S.gpu()
    V.profile = S.profile()
    V.fan1_mode, V.fan2_mode = S.fan_mode(1), S.fan_mode(2)

    V.top = {}
    local var, field = 'top', 'cpu'
    if UI.proc_sort == 'mem' then var, field = 'top_mem', 'mem' end
    for i = 1, 5 do
        V.top[i] = { name = trim(P('${' .. var .. ' name ' .. i .. '}')),
                     val = num(P('${' .. var .. ' ' .. field .. ' ' .. i .. '}')) }
    end

    -- conky's first couple of samples are garbage; keep them out of graphs.
    if updates > 2 then
        D.push(H.cpu, V.cpu, GCAP)
        D.push(H.temp, V.t_cpu or 0, GCAP)
        D.push(H.down, V.down, GCAP)
        D.push(H.up, V.up, GCAP)
        D.push(H.rd, V.rd, GCAP)
        D.push(H.wr, V.wr, GCAP)
    end
end

-- Cards ---------------------------------------------------------------------

local function card_clock(cr, w, h)
    D.card(cr, w, h)

    local tw = D.text(cr, os.date('%H:%M'), 18, 112, { size = 80, font = T.font_light })
    D.text(cr, os.date('%S'), 18 + tw + 6, 112, { size = 26, color = T.blue, font = T.font_light })
    D.text(cr, os.date('%A'), 22, 146, { size = 18 })
    D.text(cr, os.date('%d %B %Y'), 22, 168, { size = 14, color = T.dim })

    -- Month calendar, Monday first.
    local now = os.date('*t')
    local first = os.date('*t', os.time { year = now.year, month = now.month, day = 1, hour = 12 })
    local ndays = os.date('*t', os.time { year = now.year, month = now.month + 1, day = 0, hour = 12 }).day
    local offset = (first.wday + 5) % 7
    local x0, cw = 22, (w - 44) / 7
    local y0, rh = 236, 26

    local names = { 'Mo', 'Tu', 'We', 'Th', 'Fr', 'Sa', 'Su' }
    for c = 1, 7 do
        D.text(cr, names[c], x0 + (c - 0.5) * cw, 208, { size = 11, bold = true, align = 'center',
            color = c >= 6 and T.faint or T.dim })
    end
    for d = 1, ndays do
        local idx = offset + d - 1
        local cx = x0 + (idx % 7 + 0.5) * cw
        local cy = y0 + math.floor(idx / 7) * rh
        if d == now.day then D.dot(cr, cx, cy - 4, 11, T.blue) end
        D.text(cr, d, cx, cy, { size = 12, align = 'center', bold = d == now.day,
            color = d == now.day and T.fg or (idx % 7 >= 5 and T.faint or T.dim) })
    end

    D.hline(cr, 20, h - 42, w - 40)
    D.text(cr, PRIVATE and 'zenbook' or P('${nodename}'), 20, h - 18, { size = 11, color = T.faint })
    D.text(cr, 'up ' .. P('${uptime_short}'), w - 20, h - 18, { size = 11, color = T.faint, align = 'right' })
end

local function stat(cr, x, y, label, value, color)
    D.text(cr, label, x, y, { size = 10, bold = true, color = T.faint })
    D.text(cr, value, x, y + 24, { size = 19, color = color or T.fg })
end

local function card_cpu(cr, w, h)
    D.card(cr, w, h, 'CPU', MODEL .. ' · ' .. NCPU .. ' threads')

    local cx, cy = 92, 124
    D.ring(cr, cx, cy, 58, 10, V.cpu / 100, load_color(V.cpu))
    D.text(cr, string.format('%.0f%%', V.cpu), cx, cy + 10, { size = 30, bold = true, align = 'center' })
    D.text(cr, V.freq_avg and string.format('%.1f GHz', V.freq_avg) or '', cx, cy + 56,
        { size = 12, color = T.dim, align = 'center' })

    stat(cr, 186, 72, 'PACKAGE', fmt_temp(V.t_cpu), temp_color(V.t_cpu))
    stat(cr, 290, 72, 'FAN', V.fan_cpu and (V.fan_cpu .. ' rpm') or '—')
    stat(cr, 186, 136, 'PEAK FREQ', V.freq_max and string.format('%.2f GHz', V.freq_max) or '—')
    stat(cr, 290, 136, 'LOAD AVG', V.load1 .. ' ' .. V.load5)

    -- Per-thread bars, P-cores blue / E-cores cyan.
    D.text(cr, 'THREADS', 20, 208, { size = 10, bold = true, color = T.faint })
    if next(S.ecores) then
        D.dot(cr, w - 92, 204, 3.5, T.blue);  D.text(cr, 'P-core', w - 84, 208, { size = 10, color = T.faint })
        D.dot(cr, w - 40, 204, 3.5, T.cyan);  D.text(cr, 'E', w - 32, 208, { size = 10, color = T.faint })
    end
    local bx, bw, step = 20, w - 40, (w - 40) / NCPU
    local barw = math.max(math.min(step * 0.62, 14), 2)
    for i = 1, NCPU do
        local p = V.cores[i] or 0
        local col = p >= 90 and T.red or (S.ecores[i - 1] and T.cyan or T.blue)
        D.bar(cr, bx + (i - 1) * step + (step - barw) / 2, 218, barw, 58, p / 100, col, true)
    end

    -- Load (filled) with package temperature (line) overlaid.
    local gx, gy, gw, gh = 20, 296, w - 40, h - 316
    D.grid(cr, gx, gy, gw, gh, 4)
    D.graph(cr, gx, gy, gw, gh, H.cpu, 100, T.blue, { cap = GCAP })
    D.graph(cr, gx, gy, gw, gh, H.temp, 100, T.orange, { cap = GCAP, fill = false, lw = 1.2 })
    D.text(cr, 'load', gx + 6, gy + 15, { size = 10, color = T.blue })
    D.text(cr, 'temp', gx + 36, gy + 15, { size = 10, color = T.orange })
end

local function card_memory(cr, w, h)
    D.card(cr, w, h, 'MEMORY')

    local function gauge(cx, label, pct, used, total)
        D.ring(cr, cx, 100, 40, 8, pct / 100, load_color(pct))
        D.text(cr, string.format('%.0f%%', pct), cx, 107, { size = 19, bold = true, align = 'center' })
        D.text(cr, label, cx, 152, { size = 10, bold = true, color = T.faint, align = 'center' })
        D.text(cr, used .. ' / ' .. total, cx, 170, { size = 11, color = T.dim, align = 'center' })
    end
    gauge(w * 0.27, 'RAM', V.memperc, V.mem, V.memmax)
    gauge(w * 0.73, 'SWAP', V.swapperc, V.swap, V.swapmax)

    D.hline(cr, 20, 190, w - 40)
    D.heading(cr, 'STORAGE', DISK, 20, 216, w - 20)
    D.bar(cr, 20, 230, w - 40, 8, V.fsperc / 100, load_color(V.fsperc))
    D.text(cr, MOUNT .. '  ' .. V.fsused .. ' of ' .. V.fssize, 20, 258, { size = 12, color = T.dim })
    D.text(cr, string.format('%.0f%%', V.fsperc), w - 20, 258, { size = 12, align = 'right' })

    local gx, gy, gw, gh = 20, 272, w - 40, 88
    local peak = math.max(D.peak(H.rd, 1048576), D.peak(H.wr, 0))
    D.grid(cr, gx, gy, gw, gh, 3)
    D.graph(cr, gx, gy, gw, gh, H.rd, peak, T.green, { cap = GCAP })
    D.graph(cr, gx, gy, gw, gh, H.wr, peak, T.orange, { cap = GCAP })

    D.text(cr, 'R ' .. rate(V.rd), 20, 384, { size = 12, color = T.green })
    D.text(cr, 'W ' .. rate(V.wr), w - 20, 384, { size = 12, color = T.orange, align = 'right' })
    D.text(cr, 'NVMe ' .. fmt_temp(V.t_nvme), 20, h - 14, { size = 11, color = T.faint })
end

local PROFILES = { { 'quiet', 'Quiet' }, { 'balanced', 'Balanced' }, { 'performance', 'Perf' } }

local function tap_profile(id, name)
    return function()
        S.set_profile(name)
        UI.pending = { profile = id, frames = 6 }
        toast('Profile → ' .. name)
    end
end

local function tap_fan(idx, label)
    return function()
        local mode = (idx == 1 and V.fan1_mode or V.fan2_mode) == 'max' and 'auto' or 'max'
        if S.set_fan_mode(idx, mode) then
            if idx == 1 then V.fan1_mode = mode else V.fan2_mode = mode end
            toast(label .. ' fan → ' .. mode:upper())
        else
            toast('Fan control locked: sudo ./start.sh fan-access', true)
        end
    end
end

local function card_power(cr, w, h)
    local b = V.bat
    D.card(cr, w, h, 'POWER', b and (b.ac and 'on AC' or 'on battery') or nil)

    -- Battery
    local cx, cy = 60, 94
    if b then
        local col = b.pct <= 15 and T.red or (b.pct <= 30 and T.orange or T.green)
        D.ring(cr, cx, cy, 36, 8, b.pct / 100, col, { segments = 10 })
        D.text(cr, b.pct .. '%', cx, cy + 6, { size = 17, bold = true, align = 'center' })
        D.text(cr, b.status, 116, 86, { size = 14, max = w - 136 })
        D.text(cr, b.watts and string.format('%.1f W', b.watts) or (b.ac and 'plugged in' or '—'),
            116, 106, { size = 12, color = T.dim })
    else
        D.text(cr, 'no battery', 20, 94, { size = 12, color = T.faint })
    end

    -- Discrete GPU. Readings only exist while it is awake.
    D.hline(cr, 20, 146, w - 40)
    local g = V.gpu
    if g then
        local on = g.state == 'active'
        D.text(cr, g.name, 20, 170, { size = 12, color = T.dim, max = w - 110 })
        local label = on and 'ACTIVE' or (g.state == 'suspended' and 'ASLEEP' or g.state:upper())
        local lw = D.width(cr, label, { size = 9, bold = true }) + 16
        D.rrect(cr, w - 20 - lw, 157, lw, 18, 9)
        D.set(cr, on and T.orange or T.green, 0.22)
        cairo_fill(cr)
        D.text(cr, label, w - 20 - lw / 2, 170, { size = 9, bold = true, align = 'center',
            color = on and T.orange or T.green })
        if g.temp then
            local x = 20 + D.text(cr, fmt_temp(g.temp), 20, 196, { size = 16, color = temp_color(g.temp) })
            D.text(cr, string.format('  %d%%  ·  %.0f W  ·  %.1f/%.0fG', g.util, g.watts,
                g.mem_used / 1024, g.mem_total / 1024), x, 196, { size = 11, color = T.dim, max = w - 20 - x })
        else
            D.text(cr, on and 'reading…' or 'powered down — saving battery', 20, 196,
                { size = 11, color = T.faint })
        end
    end

    -- Thermal profile (asusd)
    D.hline(cr, 20, 210, w - 40)
    D.heading(cr, 'PROFILE', nil, 20, 232, w - 20)
    local current = UI.pending and UI.pending.profile or V.profile
    local bw = (w - 40 - 12) / 3
    for i, pr in ipairs(PROFILES) do
        local col = i == 1 and T.green or (i == 2 and T.blue or T.orange)
        button(cr, 'profile_' .. pr[1], 20 + (i - 1) * (bw + 6), 242, bw, 34, pr[2],
            current == pr[1], col, tap_profile(pr[1], pr[2] == 'Perf' and 'Performance' or pr[2]))
    end

    -- Fans: tap to force full speed / return to automatic.
    D.heading(cr, 'FANS', 'tap to boost', 20, 302, w - 20)
    local fans = { { 1, 'CPU', V.fan_cpu, V.fan1_mode }, { 2, 'GPU', V.fan_gpu, V.fan2_mode } }
    for i, f in ipairs(fans) do
        local y = 312 + (i - 1) * 42
        D.text(cr, f[2], 20, y + 22, { size = 11, bold = true, color = T.faint })
        D.text(cr, f[3] and (f[3] .. ' rpm') or '—', 58, y + 22, { size = 15 })
        if f[4] then
            button(cr, 'fan' .. f[1], w - 20 - 76, y, 76, 34, f[4] == 'max' and 'MAX' or 'AUTO',
                f[4] == 'max', T.orange, tap_fan(f[1], f[2]))
        end
    end

    if UI.toast then
        D.text(cr, UI.toast.text, w / 2, h - 12, { size = 10, align = 'center', max = w - 24,
            color = UI.toast.err and T.red or T.blue })
    else
        D.text(cr, 'Wi-Fi ' .. fmt_temp(V.t_wifi) .. '   ·   ACPI ' .. fmt_temp(V.t_acpi), w / 2, h - 12,
            { size = 10, align = 'center', color = T.faint })
    end
end

local function card_network(cr, w, h)
    D.card(cr, w, h, 'NETWORK', V.iface or 'offline')

    if V.iface then
        local name = V.essid ~= '' and V.essid or V.iface
        if PRIVATE then name = S.is_wireless(V.iface) and 'Wi-Fi' or 'Ethernet' end
        D.text(cr, name, 20, 58, { size = 15, max = w - 40 })
        D.text(cr, PRIVATE and '•••.•••.•••.•••' or V.addr, 20, 77, { size = 11, color = T.faint, max = w - 40 })
    else
        D.text(cr, 'Disconnected', 20, 58, { size = 15, color = T.dim })
    end

    local aw = D.arrow(cr, 20, 110, 15, false, T.blue)
    D.text(cr, rate(V.down), 20 + aw, 110, { size = 15, color = T.blue })
    local uw = D.text(cr, rate(V.up), w - 20, 110, { size = 15, color = T.orange, align = 'right' })
    D.arrow(cr, w - 20 - uw - aw, 110, 15, true, T.orange)

    local gx, gy, gw, gh = 20, 124, w - 40, 72
    local peak = math.max(D.peak(H.down, 102400), D.peak(H.up, 0))
    D.grid(cr, gx, gy, gw, gh, 3)
    D.graph(cr, gx, gy, gw, gh, H.down, peak, T.blue, { cap = GCAP })
    D.graph(cr, gx, gy, gw, gh, H.up, peak, T.orange, { cap = GCAP })
    if V.iface then
        local x = 20 + D.text(cr, 'session ', 20, 216, { size = 10, color = T.faint })
        x = x + D.arrow(cr, x, 216, 10, false, T.faint)
        x = x + D.text(cr, V.tdown .. '   ', x, 216, { size = 10, color = T.faint })
        x = x + D.arrow(cr, x, 216, 10, true, T.faint)
        D.text(cr, V.tup, x, 216, { size = 10, color = T.faint })
    end

    D.hline(cr, 20, 230, w - 40)
    D.heading(cr, 'PROCESSES', nil, 20, 256, w - 20)
    local mem = UI.proc_sort == 'mem'
    -- Tap the pill to sort by memory instead of CPU.
    button(cr, 'proc_sort', w - 20 - 64, 240, 64, 24, mem and '% RAM' or '% CPU', true,
        mem and T.purple or T.blue, function()
            UI.proc_sort = mem and 'cpu' or 'mem'
            V.top = {}
        end)
    local top = math.max(V.top[1] and V.top[1].val or 0, 0.1)
    for i, p in ipairs(V.top) do
        local y = 286 + (i - 1) * 25
        D.text(cr, p.name, 20, y, { size = 12, max = w - 100 })
        D.text(cr, string.format('%.1f', p.val), w - 20, y, { size = 12, font = T.mono, align = 'right',
            color = T.dim })
        D.bar(cr, 20, y + 6, w - 40, 3, p.val / top, i == 1 and (mem and T.purple or T.blue) or T.faint)
    end
end

local CARDS = {
    { w = 280, draw = card_clock },
    { w = 400, draw = card_cpu },
    { w = 230, draw = card_memory },
    { w = 240, draw = card_power },
    { w = 230, draw = card_network },
}

-- Hooks ---------------------------------------------------------------------

local last_sample

function conky_zen_main()
    if conky_window == nil then return end
    local updates = tonumber(P('${updates}')) or 0
    -- Redraws run faster than once a second so taps feel immediate;
    -- data (and graph history) still advances once per wall-clock second.
    local now = os.time()
    if now ~= last_sample then
        sample(updates, last_sample and math.max(now - last_sample, 1) or 1)
        last_sample = now
    end
    for _, k in ipairs({ 'pressed', 'toast', 'pending' }) do
        local u = UI[k]
        if u then
            u.frames = u.frames - 1
            if u.frames <= 0 then UI[k] = nil end
        end
    end
    -- Drop the optimistic profile as soon as the real one matches.
    if UI.pending and UI.pending.profile == V.profile then UI.pending = nil end

    local W, Hh = conky_window.width, conky_window.height
    local cs, owned
    if HAVE_XLIB and conky_window.drawable then
        cs, owned = cairo_xlib_surface_create(conky_window.display, conky_window.drawable,
            conky_window.visual, W, Hh), true
    elseif conky_surface then
        cs = conky_surface() -- owned by conky: never destroy it
    end
    if not cs then return end
    local cr = cairo_create(cs)

    local s = math.min(W / BASE_W, Hh / BASE_H)
    VIEW.ox, VIEW.oy, VIEW.s = (W - BASE_W * s) / 2, (Hh - BASE_H * s) / 2, s
    cairo_translate(cr, VIEW.ox, VIEW.oy)
    cairo_scale(cr, s, s)
    HITS = {}

    if T.panel_alpha > 0 then
        D.rrect(cr, 0, 0, BASE_W, BASE_H, T.radius + PAD)
        D.set(cr, T.panel, T.panel_alpha)
        cairo_fill(cr)
    end

    local used = 0
    for _, c in ipairs(CARDS) do used = used + c.w end
    local gap = (#CARDS > 1) and (BASE_W - 2 * PAD - used) / (#CARDS - 1) or 0
    local x = PAD
    for _, c in ipairs(CARDS) do
        cairo_save(cr)
        cairo_translate(cr, x, PAD)
        ORIGIN.x, ORIGIN.y = x, PAD
        c.draw(cr, c.w, BASE_H - 2 * PAD)
        cairo_restore(cr)
        x = x + c.w + gap
    end

    cairo_destroy(cr)
    if owned then cairo_surface_destroy(cs) end
end

local DEBUG = os.getenv('ZEN_DEBUG')

function conky_zen_mouse(ev)
    if DEBUG then
        local t = {}
        for k, v in pairs(ev) do t[#t + 1] = k .. '=' .. tostring(v) end
        print('[zen] ' .. table.concat(t, ' '))
        io.stdout:flush()
    end
    if ev.type ~= 'button_down' then return false end
    if ev.button ~= nil and ev.button ~= 'left' and ev.button ~= 1 then return false end
    local lx, ly = (ev.x - VIEW.ox) / VIEW.s, (ev.y - VIEW.oy) / VIEW.s
    local slop = 4 -- fingers are less precise than cursors
    for i = #HITS, 1, -1 do
        local r = HITS[i]
        if lx >= r.x - slop and lx <= r.x + r.w + slop and ly >= r.y - slop and ly <= r.y + r.h + slop then
            UI.pressed = { id = r.id, frames = 2 }
            r.fn()
            return true
        end
    end
    return false
end

function conky_zen_cleanup() end
