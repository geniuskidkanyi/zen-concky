-- zen-conky drawing primitives (cairo).
local T = require 'zen.theme'

local D = {}

local function clamp(v, lo, hi)
    if v ~= v then return lo end -- NaN
    if v < lo then return lo elseif v > hi then return hi end
    return v
end
D.clamp = clamp

local rgb_cache = {}
function D.rgb(hex)
    local c = rgb_cache[hex]
    if not c then
        local h = hex:gsub('#', '')
        c = { tonumber(h:sub(1, 2), 16) / 255,
              tonumber(h:sub(3, 4), 16) / 255,
              tonumber(h:sub(5, 6), 16) / 255 }
        rgb_cache[hex] = c
    end
    return c[1], c[2], c[3]
end

function D.set(cr, hex, a)
    local r, g, b = D.rgb(hex)
    cairo_set_source_rgba(cr, r, g, b, a or 1)
end

function D.rrect(cr, x, y, w, h, r)
    r = math.min(r, w / 2, h / 2)
    cairo_new_sub_path(cr)
    cairo_arc(cr, x + w - r, y + r,     r, -math.pi / 2, 0)
    cairo_arc(cr, x + w - r, y + h - r, r, 0, math.pi / 2)
    cairo_arc(cr, x + r,     y + h - r, r, math.pi / 2, math.pi)
    cairo_arc(cr, x + r,     y + r,     r, math.pi, 3 * math.pi / 2)
    cairo_close_path(cr)
end

-- Text ------------------------------------------------------------------

local ext
local function font(cr, o)
    cairo_select_font_face(cr, o.font or T.font, CAIRO_FONT_SLANT_NORMAL,
        o.bold and CAIRO_FONT_WEIGHT_BOLD or CAIRO_FONT_WEIGHT_NORMAL)
    cairo_set_font_size(cr, o.size or 12)
end

local function advance(cr, s)
    if not ext then
        ext = cairo_text_extents_t:create()
        if tolua and tolua.takeownership then tolua.takeownership(ext) end
    end
    cairo_text_extents(cr, s, ext)
    return ext.x_advance
end

function D.width(cr, s, o)
    font(cr, o or {})
    return advance(cr, tostring(s))
end

-- D.text(cr, s, x, y, {size, color, alpha, bold, font, align='left'|'center'|'right', max=width})
-- Returns the advance width of what was drawn.
function D.text(cr, s, x, y, o)
    o = o or {}
    s = tostring(s or '')
    font(cr, o)
    local w = advance(cr, s)
    if o.max and w > o.max then
        while #s > 1 and w > o.max do
            s = s:sub(1, -2)
            w = advance(cr, s .. '…')
        end
        s = s .. '…'
    end
    if o.align == 'right' then x = x - w elseif o.align == 'center' then x = x - w / 2 end
    D.set(cr, o.color or T.fg, o.alpha)
    cairo_move_to(cr, x, y)
    cairo_show_text(cr, s)
    return w
end

-- Small filled triangle (the UI fonts lack arrow glyphs). x,y = baseline-left.
function D.arrow(cr, x, y, size, up, color)
    local hw, top = size * 0.36, y - size * 0.72
    cairo_new_path(cr)
    if up then
        cairo_move_to(cr, x, y); cairo_line_to(cr, x + 2 * hw, y); cairo_line_to(cr, x + hw, top)
    else
        cairo_move_to(cr, x, top); cairo_line_to(cr, x + 2 * hw, top); cairo_line_to(cr, x + hw, y)
    end
    cairo_close_path(cr)
    D.set(cr, color)
    cairo_fill(cr)
    return 2 * hw + size * 0.3
end

-- Shapes ----------------------------------------------------------------

function D.card(cr, w, h, title, sub)
    D.rrect(cr, 0.5, 0.5, w - 1, h - 1, T.radius)
    D.set(cr, T.card, T.card_alpha)
    cairo_fill_preserve(cr)
    cairo_set_line_width(cr, 1)
    D.set(cr, T.border)
    cairo_stroke(cr)
    if title then D.heading(cr, title, sub, 20, 30, w - 20) end
end

function D.heading(cr, title, sub, x, y, right)
    D.text(cr, title, x, y, { size = 11, bold = true, color = T.dim })
    if sub then D.text(cr, sub, right, y, { size = 11, color = T.faint, align = 'right', max = right - x - 90 }) end
end

function D.hline(cr, x, y, w)
    D.set(cr, T.border)
    cairo_set_line_width(cr, 1)
    cairo_move_to(cr, x, y + 0.5)
    cairo_line_to(cr, x + w, y + 0.5)
    cairo_stroke(cr)
end

function D.dot(cr, x, y, r, color)
    cairo_new_path(cr)
    cairo_arc(cr, x, y, r, 0, 2 * math.pi)
    D.set(cr, color)
    cairo_fill(cr)
end

-- Gauge ring. Angles are cairo degrees (0 = 3 o'clock, clockwise);
-- the default 135..405 is a 270° gauge open at the bottom.
-- o.segments splits the arc into lit/unlit blocks.
function D.ring(cr, cx, cy, r, th, pct, color, o)
    o = o or {}
    pct = clamp(pct or 0, 0, 1)
    local a0, a1 = math.rad(o.from or 135), math.rad(o.to or 405)
    cairo_set_line_width(cr, th)

    if o.segments then
        local n = o.segments
        local gap = math.rad(o.gap or 4)
        local step = (a1 - a0) / n
        local lit = math.floor(pct * n + 0.5)
        cairo_set_line_cap(cr, CAIRO_LINE_CAP_BUTT)
        for i = 1, n do
            local s = a0 + (i - 1) * step + gap / 2
            cairo_new_path(cr)
            cairo_arc(cr, cx, cy, r, s, s + step - gap)
            D.set(cr, i <= lit and color or (o.track or T.track))
            cairo_stroke(cr)
        end
        return
    end

    cairo_set_line_cap(cr, CAIRO_LINE_CAP_ROUND)
    cairo_new_path(cr)
    cairo_arc(cr, cx, cy, r, a0, a1)
    D.set(cr, o.track or T.track)
    cairo_stroke(cr)
    if pct > 0.003 then
        cairo_new_path(cr)
        cairo_arc(cr, cx, cy, r, a0, a0 + (a1 - a0) * pct)
        D.set(cr, color)
        cairo_stroke(cr)
    end
    cairo_set_line_cap(cr, CAIRO_LINE_CAP_BUTT)
end

function D.bar(cr, x, y, w, h, pct, color, vertical)
    pct = clamp(pct or 0, 0, 1)
    local r = math.min(w, h) / 2
    D.rrect(cr, x, y, w, h, r)
    D.set(cr, T.track)
    cairo_fill(cr)
    if pct <= 0.003 then return end
    if vertical then
        local fh = math.max(h * pct, w)
        D.rrect(cr, x, y + h - fh, w, fh, r)
    else
        local fw = math.max(w * pct, h)
        D.rrect(cr, x, y, fw, h, r)
    end
    D.set(cr, color)
    cairo_fill(cr)
end

-- History graphs ----------------------------------------------------------

function D.push(hist, v, cap)
    hist[#hist + 1] = v or 0
    while #hist > cap do table.remove(hist, 1) end
end

function D.peak(hist, floor)
    local m = floor or 0
    for i = 1, #hist do if hist[i] > m then m = hist[i] end end
    return m
end

function D.grid(cr, x, y, w, h, rows)
    D.set(cr, T.grid)
    cairo_set_line_width(cr, 1)
    for i = 0, rows do
        local gy = math.floor(y + h * i / rows) + 0.5
        cairo_move_to(cr, x, gy)
        cairo_line_to(cr, x + w, gy)
    end
    cairo_stroke(cr)
end

-- o: {cap=n samples across width, fill=true, lw=line width}
function D.graph(cr, x, y, w, h, hist, max, color, o)
    o = o or {}
    local n = #hist
    if n < 2 or max <= 0 then return end
    local cap = math.max(o.cap or n, 2)
    local dx = w / (cap - 1)
    local x0 = x + w - (n - 1) * dx

    cairo_new_path(cr)
    for i = 1, n do
        local px = x0 + (i - 1) * dx
        local py = y + h - clamp(hist[i] / max, 0, 1) * h
        if i == 1 then cairo_move_to(cr, px, py) else cairo_line_to(cr, px, py) end
    end
    cairo_set_line_join(cr, CAIRO_LINE_JOIN_ROUND)
    cairo_set_line_width(cr, o.lw or 1.6)
    D.set(cr, color)
    if o.fill == false then
        cairo_stroke(cr)
        return
    end
    cairo_stroke_preserve(cr)
    cairo_line_to(cr, x + w, y + h)
    cairo_line_to(cr, x0, y + h)
    cairo_close_path(cr)
    local r, g, b = D.rgb(color)
    local pat = cairo_pattern_create_linear(0, y, 0, y + h)
    cairo_pattern_add_color_stop_rgba(pat, 0, r, g, b, 0.40)
    cairo_pattern_add_color_stop_rgba(pat, 1, r, g, b, 0.03)
    cairo_set_source(cr, pat)
    cairo_fill(cr)
    cairo_pattern_destroy(pat)
end

return D
