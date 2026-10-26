#!/usr/bin/env python3
"""
vcdwave.py - VCD reader (cycle sampling) and WaveJSON builder for the AXI DMA waveform documents.

Sampling rule: a value is sampled 1 ps before every rising edge of `clk` (what the flops of the
next edge see). Column k of a figure is the value that is present between rising edge k and
rising edge k+1, i.e. a signal drawn as changing at the left border of column k changed at
edge k. A handshake (VALID and READY both 1 in a column) is therefore transferred at the
right border (rising edge) of that column.
"""
import json, re

CLK_FIRST_EDGE_PS = 5000
CLK_PERIOD_PS = 10000

class Vcd:
    def __init__(self, path):
        self.timescale_ps = 1
        self.sig = {}          # name -> dict(width, ev=[(t, int|None)])
        self._parse(path)
        self.ncyc = (self.t_end - CLK_FIRST_EDGE_PS) // CLK_PERIOD_PS
        self._cache = {}
        self._rawc = {}

    # ------------------------------------------------------------------ parsing
    def _parse(self, path):
        scope, ids, groups = [], {}, {}
        ev = {}                                   # id -> [(t, str)]
        t = 0
        self.t_end = 0
        with open(path, errors="replace") as f:
            txt = f.read()
        head, body = txt.split("$enddefinitions", 1)
        m = re.search(r"\$timescale\s*(\d+)\s*(\w+)", head)
        if m:
            self.timescale_ps = int(m.group(1)) * {"fs": 0.001, "ps": 1, "ns": 1000, "us": 1e6}[m.group(2)]
        for line in head.splitlines():
            tk = line.split()
            if not tk:
                continue
            if tk[0] == "$scope":
                scope.append(tk[2])
            elif tk[0] == "$upscope":
                scope.pop()
            elif tk[0] == "$var" and tk[1] != "parameter":
                width, vid, name = int(tk[2]), tk[3], tk[4]
                rest = tk[5:-1]
                idx = rest[0] if rest else ""
                m2 = re.match(r"\[(\d+)(?::(\d+))?\]", idx)
                mch = [re.match(r"g_ch\[(\d+)\]", s) for s in scope]
                prefix = ""
                for mm in mch:
                    if mm:
                        prefix = "ch%s." % mm.group(1)
                full = prefix + name
                if m2 and width == 1 and m2.group(2) is None:        # single bit of a split vector
                    groups.setdefault(full, {})[int(m2.group(1))] = vid
                else:
                    ids.setdefault(vid, []).append((full, width))
                ev.setdefault(vid, [])
        # events
        cur = None
        for tok in body.split("\n"):
            tok = tok.strip()
            if not tok or tok.startswith("$"):
                continue
            if tok[0] == "#":
                t = int(tok[1:]) * self.timescale_ps
                self.t_end = max(self.t_end, int(t))
            elif tok[0] in "bB":
                val, vid = tok[1:].split()
                if vid in ev:
                    ev[vid].append((int(t), val))
            elif tok[0] in "01xXzZ":
                if tok[1:] in ev:
                    ev[tok[1:]].append((int(t), tok[0]))
        def toint(s):
            """-> (value, x-mask): x / z bits are 0 in value and 1 in the mask"""
            return (int(re.sub(r"[xXzZ]", "0", s), 2), int(re.sub(r"[01]", "0", re.sub(r"[xXzZ]", "1", s)), 2))
        for vid, lst in ids.items():
            for full, width in lst:
                self.sig[full] = dict(width=width, ev=[(tt, toint(v)) for tt, v in ev[vid]])
        for full, bits in groups.items():
            width = max(bits) + 1
            cur_bits = {b: (0, 1) for b in bits}
            times = sorted({tt for b, vid in bits.items() for tt, _ in ev[vid]})
            per = {b: ev[vid] for b, vid in bits.items()}
            ptr = {b: 0 for b in bits}
            out = []
            for tt in times:
                for b in bits:
                    lst = per[b]
                    while ptr[b] < len(lst) and lst[ptr[b]][0] <= tt:
                        cur_bits[b] = toint(lst[ptr[b]][1]); ptr[b] += 1
                out.append((tt, (sum((v[0] & 1) << b for b, v in cur_bits.items()),
                                 sum((v[1] & 1) << b for b, v in cur_bits.items()))))
            self.sig[full] = dict(width=width, ev=out)

    # ------------------------------------------------------------------ sampling
    def has(self, name):
        return name in self.sig

    def series(self, name):
        """per-cycle list (index k: value between edge k and edge k+1)"""
        if name in self._cache:
            return self._cache[name]
        if name not in self.sig:
            raise KeyError("signal %s not in VCD" % name)
        raw = self.raw(name)
        out = [None if (x is None or x[1]) else x[0] for x in raw]
        self._cache[name] = out
        return out

    def raw(self, name):
        """per-cycle (value, x-mask) pairs (None before the first value change)"""
        if name in self._rawc:
            return self._rawc[name]
        ev = self.sig[name]["ev"]
        out, p, cur = [], 0, None
        for k in range(self.ncyc):
            ts = CLK_FIRST_EDGE_PS + (k + 1) * CLK_PERIOD_PS - 1
            while p < len(ev) and ev[p][0] <= ts:
                cur = ev[p][1]; p += 1
            out.append(cur)
        self._rawc[name] = out
        return out

    def width(self, name):
        return self.sig[name]["width"]

    def add(self, name, series, width=1):
        """derived per-cycle series (bit / field of a vector, combination of signals)"""
        self.sig[name] = dict(width=width, ev=[])
        self._cache[name] = series
        return name

    def field(self, name, base, hi, lo=None):
        lo = hi if lo is None else lo
        m = (1 << (hi - lo + 1)) - 1
        out = []
        for x in self.raw(base):
            out.append(None if (x is None or (x[1] >> lo) & m) else (x[0] >> lo) & m)
        return self.add(name, out, hi - lo + 1)

    def ns(self, cyc):
        return (CLK_FIRST_EDGE_PS + cyc * CLK_PERIOD_PS) / 1000.0

# ---------------------------------------------------------------------- selectors
def bit(v, name, b=None):
    if b is None:
        return v.series(name)
    return part(v, name, b, b)

def part(v, name, hi, lo):
    m = (1 << (hi - lo + 1)) - 1
    return [None if (x is None or (x[1] >> lo) & m) else (x[0] >> lo) & m for x in v.raw(name)]

def cond_at(v, spec, k):
    """spec: signal name, '~name' (negated) or tuple/list of those (AND) -> bool at cycle k"""
    if spec is None:
        return True
    if isinstance(spec, (tuple, list)):
        return all(cond_at(v, s, k) for s in spec)
    if spec.startswith("~"):
        x = v.series(spec[1:])[k]
        return x == 0
    x = v.series(spec)[k]
    return bool(x)

def find(cond, start=0, end=None, nth=0):
    """first cycle >= start where cond(k) is true (nth occurrence)"""
    k = start
    n = 0
    end = end if end is not None else 10**9
    while k < end:
        try:
            ok = cond(k)
        except IndexError:
            return None
        if ok:
            if n == nth:
                return k
            n += 1
        k += 1
    return None

# ---------------------------------------------------------------------- WaveJSON builder
class Sig:
    """one displayed row"""
    def __init__(self, label, name, kind="bit", bit=None, hi=None, lo=None, fmt="hex", valid=None, ready=None,
                 col="=", enum=None, digits=None, strip=False, mask=None):
        self.mask = mask          # bit rows: show 'x' (don't care) while this condition is false
        self.label, self.name, self.kind = label, name, kind
        self.bit, self.hi, self.lo = bit, hi, lo
        self.fmt, self.valid, self.ready, self.col, self.enum = fmt, valid, ready, col, enum
        self.digits, self.strip = digits, strip

class Group:
    def __init__(self, name, rows):
        self.name, self.rows = name, rows

def B(label, name=None, bit=None, mask=None):
    return Sig(label, name or label, "bit", bit=bit, mask=mask)

def V(label, name=None, **kw):
    return Sig(label, name or label, "bus", **kw)

def E(label, name, enum, **kw):
    return Sig(label, name, "enum", enum=enum, **kw)

SPACER = None

def _vals(v, s):
    if s.hi is not None:
        return part(v, s.name, s.hi, s.lo)
    return bit(v, s.name, s.bit)

def _fmt(s, v, width):
    if v is None:
        return None
    if s.enum is not None:
        return s.enum.get(v, "%d" % v)
    if s.fmt == "dec":
        return "%d" % v
    n = s.digits or max(1, (width + 3) // 4)
    txt = "%0*x" % (n, v)
    if s.strip:
        txt = "%x" % v
    if s.digits and len(txt) > s.digits:
        txt = txt[-s.digits:]
    return txt

def _columns(segs, data, flat, compress):
    """segments [(s,e)...] -> column list of cycle numbers (None = gap column)"""
    cols = []
    for si, (s, e) in enumerate(segs):
        if si:
            cols.append(None)
        cyc = list(range(s, e + 1))
        if not compress:
            cols += cyc
            continue
        snap = lambda k: tuple(data[id(x)][k] for x in flat)
        i = 0
        while i < len(cyc):
            j = i
            while j + 1 < len(cyc) and snap(cyc[j + 1]) == snap(cyc[i]):
                j += 1
            if j - i + 1 >= compress:
                cols += [cyc[i], None, cyc[j]]
            else:
                cols += cyc[i:j + 1]
            i = j + 1
    return cols

def build(v, rows, win, title=None, hscale=1, compress=0, clk=True, cycle_row=True, marks=(), edges=(), foot=None):
    """returns the WaveJSON dict; win = (start, end) or a list of such segments (joined by a gap column)"""
    segs = [win] if isinstance(win, tuple) else list(win)
    start = segs[0][0]
    flat = []
    for r in rows:
        if isinstance(r, Group):
            flat += [x for x in r.rows if x is not None]
        elif r is not None:
            flat.append(r)
    data = {id(s): _vals(v, s) for s in flat}
    cols = _columns(segs, data, flat, compress)
    colof = {k: c for c, k in enumerate(cols) if k is not None}

    def wave_for(s):
        vals = data[id(s)]
        w, d = [], []
        prev_txt, prev_xfer, in_x = None, False, False
        for k in cols:
            if k is None:
                w.append("|"); prev_txt = None; prev_xfer = False; continue
            x = vals[k]
            if s.kind == "bit":
                w.append("x" if (x is None or (s.mask and not cond_at(v, s.mask, k))) else str(x))
                continue
            if not cond_at(v, s.valid, k) or x is None:
                w.append("." if in_x else "x")
                in_x = True
                prev_txt = None; prev_xfer = False
                continue
            in_x = False
            txt = _fmt(s, x, v.width(s.name))
            xfer = bool(s.ready) and cond_at(v, s.ready, k)
            if txt == prev_txt and not prev_xfer:
                w.append(".")
            else:
                w.append(s.col); d.append(txt)
            prev_txt, prev_xfer = txt, xfer
        out, last = [], None
        for ch in w:
            if s.kind == "bit" and ch == last and ch in "01x":
                out.append(".")
            else:
                out.append(ch)
            if ch != "|":
                last = ch
        return "".join(out), d

    sig_json = []
    if clk:
        sig_json.append({"name": "clk", "wave": "".join("|" if k is None else "p" for k in cols)})
    if cycle_row:
        w, d = [], []
        for k in cols:
            if k is None:
                w.append("|")
            else:
                w.append("2" if (k - start) % 2 == 0 else "3")
                d.append(str(k - start))
        sig_json.append({"name": "cycle", "wave": "".join(w), "data": d})
        sig_json.append({})
    nodes = {}
    for m in marks:
        nodes.setdefault(m["row"], []).append(m)

    def row_json(s):
        w, d = wave_for(s)
        j = {"name": s.label, "wave": w}
        if d:
            j["data"] = d
        if s.label in nodes:
            nd = ["."] * len(w)
            for m in nodes[s.label]:
                if m["cycle"] in colof:
                    nd[colof[m["cycle"]]] = m["node"]
            j["node"] = "".join(nd)
        return j

    for r in rows:
        if r is SPACER:
            sig_json.append({})
        elif isinstance(r, Group):
            sig_json.append([r.name] + [row_json(x) if x is not None else {} for x in r.rows])
        else:
            sig_json.append(row_json(r))
    j = {"signal": sig_json, "config": {"hscale": hscale}}
    if title:
        j["head"] = {"text": title}
    if foot:
        j["foot"] = {"text": foot}
    placed = set()
    for r in sig_json:
        for x in ([r] if isinstance(r, dict) else r[1:]):
            placed |= set(c for c in x.get("node", "") if c != ".")
    keep = []
    for e in edges:
        m = re.match(r"^(\w)[-~|/\\<>=+]+(\w)", e)
        if m and m.group(1) in placed and m.group(2) in placed:
            keep.append(e)
    if keep:
        j["edge"] = keep
    return j

def render_svg(j, path):
    import wavedrom
    svg = wavedrom.render(json.dumps(j))
    svg.saveas(path)
