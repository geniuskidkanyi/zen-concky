-- zen-conky data sources that conky doesn't expose directly (sysfs/procfs).
-- Anything spawning a process runs once at load time, never per frame.
local S = {}

local function read(path)
    local f = io.open(path, 'r')
    if not f then return nil end
    local s = f:read('*l')
    f:close()
    return s
end
S.read = read

local function readn(path) return tonumber(read(path) or '') end

local function lines(cmd)
    local out = {}
    local p = io.popen(cmd .. ' 2>/dev/null')
    if not p then return out end
    for l in p:lines() do out[#out + 1] = l end
    p:close()
    return out
end

-- Topology ----------------------------------------------------------------

function S.ncpu()
    return tonumber(lines('nproc')[1] or '') or 1
end

-- Parses a cpulist like "0-11" or "0,2,4-7" into a set of 0-based ids.
local function cpuset(path)
    local set, s = {}, read(path)
    if not s then return set end
    for part in s:gmatch('[^,]+') do
        local a, b = part:match('(%d+)-(%d+)')
        a, b = tonumber(a or part), tonumber(b or part)
        if a then for i = a, b do set[i] = true end end
    end
    return set
end

-- Hybrid Intel CPUs: which threads are P-cores vs E-cores.
S.ecores = cpuset('/sys/devices/cpu_atom/cpus')

function S.cpu_model()
    for _, l in ipairs(lines('grep -m1 "model name" /proc/cpuinfo')) do
        local m = l:match(':%s*(.*)') or ''
        m = m:gsub('%(R%)', ''):gsub('%(TM%)', ''):gsub('%d+th Gen ', ''):gsub('Intel Core ', '')
             :gsub('CPU', ''):gsub('%s+@.*', ''):gsub('%s+', ' ')
        return (m:gsub('^%s+', ''):gsub('%s+$', ''))
    end
    return 'CPU'
end

-- Average and max current frequency in GHz.
function S.cpufreq(n)
    local sum, max, cnt = 0, 0, 0
    for i = 0, n - 1 do
        local f = readn('/sys/devices/system/cpu/cpu' .. i .. '/cpufreq/scaling_cur_freq')
        if f then
            sum, cnt = sum + f, cnt + 1
            if f > max then max = f end
        end
    end
    if cnt == 0 then return nil, nil end
    return sum / cnt / 1e6, max / 1e6
end

function S.loadavg()
    local s = read('/proc/loadavg') or ''
    local a, b, c = s:match('(%S+)%s+(%S+)%s+(%S+)')
    return a or '-', b or '-', c or '-'
end

-- hwmon -------------------------------------------------------------------

local hw = {}
-- Finds /sys/class/hwmon/hwmonN by chip name (prefix match, since names
-- like "iwlwifi_1" carry suffixes). hwmon numbering changes across boots.
function S.hwmon(name)
    if hw[name] ~= nil then return hw[name] or nil end
    for i = 0, 63 do
        local d = '/sys/class/hwmon/hwmon' .. i
        local n = read(d .. '/name')
        if n and n:sub(1, #name) == name then
            hw[name] = d
            return d
        end
    end
    hw[name] = false
    return nil
end

function S.temp(chip, idx)
    local d = S.hwmon(chip)
    local v = d and readn(d .. '/temp' .. (idx or 1) .. '_input')
    return v and v / 1000
end

function S.fan(chip, idx)
    local d = S.hwmon(chip)
    return d and readn(d .. '/fan' .. idx .. '_input')
end

-- Block device I/O ----------------------------------------------------------

function S.root_disk()
    local src = (lines('findmnt -no SOURCE /')[1] or ''):gsub('%[.*', '')
    local pk = lines('lsblk -no PKNAME ' .. src)[1]
    if pk and pk ~= '' then return pk end
    return src:match('/dev/(%a+%d*n%d+)') or src:match('/dev/(%a+)') or 'sda'
end

local last_io = {}
-- Bytes/s read & written since the previous call.
function S.diskio(dev, interval)
    local f = io.open('/proc/diskstats', 'r')
    if not f then return 0, 0 end
    local rd, wr
    for l in f:lines() do
        local name, r, w = l:match('^%s*%d+%s+%d+%s+(%S+)%s+%d+%s+%d+%s+(%d+)%s+%d+%s+%d+%s+%d+%s+(%d+)')
        if name == dev then rd, wr = tonumber(r) * 512, tonumber(w) * 512 break end
    end
    f:close()
    if not rd then return 0, 0 end
    local p = last_io[dev]
    last_io[dev] = { rd, wr }
    if not p then return 0, 0 end
    return math.max(rd - p[1], 0) / interval, math.max(wr - p[2], 0) / interval
end

-- Network -------------------------------------------------------------------

local iface, iface_checked = nil, -1
-- Default-route interface, falling back to the first interface that is up.
-- Re-evaluated every 15 s so switching Wi-Fi/Ethernet/USB tethering works.
function S.iface(now)
    if now - iface_checked < 15 then return iface end
    iface_checked = now
    local f = io.open('/proc/net/route', 'r')
    if f then
        for l in f:lines() do
            local name, dest = l:match('^(%S+)%s+(%x+)')
            if dest == '00000000' then iface = name break end
        end
        f:close()
    end
    if not iface then
        for _, n in ipairs(lines('ls /sys/class/net')) do
            if n ~= 'lo' and read('/sys/class/net/' .. n .. '/operstate') == 'up' then iface = n break end
        end
    end
    return iface
end

function S.is_wireless(dev)
    return dev ~= nil and read('/sys/class/net/' .. dev .. '/phy80211/name') ~= nil
end

-- Power ---------------------------------------------------------------------

local bat, ac
for _, n in ipairs(lines('ls /sys/class/power_supply')) do
    local d = '/sys/class/power_supply/' .. n
    local t = read(d .. '/type')
    -- Skip peripheral batteries (stylus, mice): they report scope=Device.
    if t == 'Battery' and read(d .. '/scope') ~= 'Device' and not bat then bat = d end
    if t == 'Mains' and not ac then ac = d end
end

function S.battery()
    if not bat then return nil end
    local watts
    local p = readn(bat .. '/power_now')
    if p and p > 0 then
        watts = p / 1e6
    else
        local i, v = readn(bat .. '/current_now'), readn(bat .. '/voltage_now')
        if i and v and i > 0 then watts = i * v / 1e12 end
    end
    return {
        pct    = readn(bat .. '/capacity') or 0,
        status = read(bat .. '/status') or 'Unknown',
        watts  = watts,
        ac     = ac and read(ac .. '/online') == '1',
    }
end

-- Discrete GPU ----------------------------------------------------------------
-- Only reads runtime PM state, which never wakes the GPU. Polling nvidia-smi
-- would keep the dGPU powered up and drain the battery.

local gpu
for _, d in ipairs(lines('ls -d /sys/bus/pci/devices/*')) do
    local class = read(d .. '/class') or ''
    if read(d .. '/vendor') == '0x10de' and class:match('^0x03') then
        local slot = d:match('([^/]+)$')
        local desc = lines('lspci -mm -s ' .. slot)[1] or ''
        local name = desc:match('%[(.-)%]') or 'NVIDIA GPU'
        gpu = { dir = d, name = name:match('(RTX %w+)') or name:match('(GTX %w+)') or name }
        break
    end
end

-- Temperature/load come from bin/zen-gpu.py, which polls NVML only while
-- the GPU is already awake and writes "<epoch> <temp> <util%> <watts> <mem_used> <mem_total>"
-- (or "<epoch> asleep") to $XDG_RUNTIME_DIR/zen-conky-gpu.
local GPU_FILE = (os.getenv('XDG_RUNTIME_DIR') or '/tmp') .. '/zen-conky-gpu'

function S.gpu()
    if not gpu then return nil end
    local g = { name = gpu.name, state = read(gpu.dir .. '/power/runtime_status') or 'unknown' }
    local ts, t, u, w, mu, mt = (read(GPU_FILE) or ''):match('^(%d+) (%S+) (%S+) (%S+) (%S+) (%S+)')
    if ts and os.time() - tonumber(ts) < 40 and g.state == 'active' then
        g.temp, g.util, g.watts = tonumber(t), tonumber(u), tonumber(w)
        g.mem_used, g.mem_total = tonumber(mu), tonumber(mt)
    end
    return g
end

-- Thermal profile & fans ------------------------------------------------------

function S.profile()
    return read('/sys/firmware/acpi/platform_profile') or read('/sys/devices/platform/asus-nb-wmi/throttle_thermal_policy')
end

function S.set_profile(name)
    os.execute('asusctl profile set ' .. name .. ' >/dev/null 2>&1 &')
end

-- asus-wmi pwmN_enable: 0 = full speed, 2 = automatic. N=1 CPU fan, N=2 GPU fan.
local function pwm_path(idx)
    local d = S.hwmon('asus')
    return d and (d .. '/pwm' .. idx .. '_enable')
end

function S.fan_mode(idx)
    local p = pwm_path(idx)
    local v = p and read(p)
    if not v then return nil end
    return v == '0' and 'max' or 'auto'
end

-- Returns true on success; false when the file isn't writable
-- (install the udev rule with: sudo ./start.sh fan-access).
function S.set_fan_mode(idx, mode)
    local p = pwm_path(idx)
    local f = p and io.open(p, 'w')
    if not f then return false end
    local ok = f:write(mode == 'max' and '0' or '2')
    local closed = f:close()
    return ok ~= nil and closed ~= nil
end

return S
