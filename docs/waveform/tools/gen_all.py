#!/usr/bin/env python3
"""
gen_all.py - generate the figures of docs/waveform from simulation of the repository tests.

  python docs/waveform/tools/wave_build.py --work <dir>                  # once: private build
  python docs/waveform/tools/gen_all.py    --work <dir> [--resim] [--only id,id] [--facts]

For each figure the listed (existing) UVM test is simulated with a fixed seed and a VCD of the DUT
ports; the window is located from DUT events (not from fixed times); WaveJSON and SVG are written to
wavejson/ and svg/. --facts prints the handshake timeline of every window (used for the captions).
Requires `pip install wavedrom` for the SVG rendering.
"""
import argparse, json, os, sys

sys.dont_write_bytecode = True

HERE = os.path.dirname(os.path.abspath(__file__))
OUT = os.path.abspath(os.path.join(HERE, ".."))
sys.path.insert(0, HERE)
from vcdwave import *
import wave_sim

SEED = 1
UNTIL = "400us"

FSM = {0: "IDLE", 1: "LINK", 2: "CFG", 3: "CHK", 4: "MUL", 5: "ALLOC", 6: "ALLOCW", 7: "GPO",
       8: "CTRIG", 9: "XFER", 10: "TOUT", 11: "DONE", 12: "STOP", 13: "FIN"}   # CTRIG = S_CMDTRIG, TOUT = S_TRIGOUT
RESP = {0: "OKAY", 1: "EXOK", 2: "SLVE", 3: "DECE"}   # SLVE = SLVERR, DECE = DECERR, EXOK = EXOKAY
ACK = {0: "OKAY", 1: "DENY", 2: "LOKAY"}
REQ = {0: "SINGLE", 1: "LSINGLE", 2: "BLOCK", 3: "LBLOCK"}
BURST = {0: "FIXED", 1: "INCR", 2: "WRAP"}

# ----------------------------------------------------------------------------- row sets
def _x(p, ch):
    return ("%svalid%s" % (ch, p), "%sready%s" % (ch, p))

def apb_rows():
    return Group("APB", [B("PSEL", "psel"), B("PENABLE", "penable"), B("PWRITE", "pwrite"),
                         V("PADDR", "paddr", valid="psel", strip=True, col="3"),
                         V("PWDATA", "pwdata", valid=("psel", "pwrite"), strip=True, col="4"),
                         B("PREADY", "pready"),
                         V("PRDATA", "prdata", valid=("psel", "~pwrite", "pready"), strip=True, col="4")])

def _addr_ch(chn, label, p, fields, attr):
    vl, rd = _x(p, chn)
    hs_ = (vl, rd)
    r = [B(label + "VALID", vl), B(label + "READY", rd),
         V(label + "ADDR", "%saddr%s" % (chn, p), valid=vl, ready=hs_, strip=True, col="3"),
         V(label + "LEN", "%slen%s" % (chn, p), valid=vl, ready=hs_, fmt="dec", col="3"),
         V(label + "SIZE", "%ssize%s" % (chn, p), valid=vl, ready=hs_, fmt="dec", col="3"),
         E(label + "BURST", "%sburst%s" % (chn, p), BURST, valid=vl, ready=hs_, col="3"),
         V(label + "ID", "%sid%s" % (chn, p), valid=vl, ready=hs_, fmt="dec", col="3")]
    if chn == "ar":
        r.append(B("ARCMDLINK", "arcmdlink" + p))
    if attr:
        r += [V(label + "QOS", "%sqos%s" % (chn, p), valid=vl, ready=hs_, fmt="dec", col="3"),
              V(label + "CACHE", "%scache%s" % (chn, p), valid=vl, ready=hs_, col="3"),
              V(label + "PROT", "%sprot%s" % (chn, p), valid=vl, ready=hs_, col="3")]
    keep = set(fields)
    return [x for x in r if x.label[len(label):] in keep or x.label in keep]

def ar_rows(fields=("VALID", "READY", "ADDR", "LEN", "SIZE", "ID"), attr=False, p="_m0"):
    return Group("AR", _addr_ch("ar", "AR", p, fields, attr))

def aw_rows(fields=("VALID", "READY", "ADDR", "LEN", "SIZE", "ID"), attr=False, p="_m0"):
    return Group("AW", _addr_ch("aw", "AW", p, fields, attr))

def r_rows(data=False, resp=False, p="_m0"):
    vl, rd = _x(p, "r")
    r = [B("RVALID", vl), B("RREADY", rd),
         V("RID", "rid" + p, valid=vl, ready=(vl, rd), fmt="dec", col="3"),
         B("RLAST", "rlast" + p, mask=vl)]
    if resp:
        r.append(E("RRESP", "rresp" + p, RESP, valid=vl, ready=(vl, rd), col="3"))
    if data:
        r.append(V("RDATA", "rdata" + p, valid=vl, ready=(vl, rd), col="4"))
    return Group("R", r)

def w_rows(data=False, p="_m0"):
    vl, rd = _x(p, "w")
    r = [B("WVALID", vl), B("WREADY", rd), B("WLAST", "wlast" + p, mask=vl),
         V("WSTRB", "wstrb" + p, valid=vl, ready=(vl, rd), col="3")]
    if data:
        r.append(V("WDATA", "wdata" + p, valid=vl, ready=(vl, rd), col="4"))
    return Group("W", r)

def b_rows(p="_m0"):
    vl, rd = _x(p, "b")
    return Group("B", [B("BVALID", vl), B("BREADY", rd),
                       V("BID", "bid" + p, valid=vl, ready=(vl, rd), fmt="dec", col="3"),
                       E("BRESP", "bresp" + p, RESP, valid=vl, ready=(vl, rd), col="3")])

def ch_rows(ch=0, fsm=True, status=("enabled",), extra=()):
    r = []
    if fsm:
        r.append(E("FSM ch%d" % ch, "ch%d.st" % ch, FSM, col="2"))
    names = dict(enabled="ch_enabled", err="ch_err", stopped="ch_stopped", paused="ch_paused", irq="irq_channel")
    for s in status:
        r.append(B("%s[%d]" % (names[s], ch), names[s], bit=ch))
    r += list(extra)
    return Group("CH%d" % ch, r)

IRQ = lambda ch=0: B("irq_channel[%d]" % ch, "irq_channel", bit=ch)

# ----------------------------------------------------------------------------- anchors
def apb_xfers(v):
    ps, pe, pr, pw, pa, pd = (v.series(n) for n in ("psel", "penable", "pready", "pwrite", "paddr", "pwdata"))
    return [(k, bool(pw[k]), pa[k], pd[k]) for k in range(v.ncyc) if ps[k] and pe[k] and pr[k]]

def enables(v, ch=None):
    """cycle of every CH_CMD ENABLECMD write -> [(cycle, channel)]"""
    out = []
    for k, w, a, d in apb_xfers(v):
        if w and a is not None and 0x1000 <= a < 0x1800 and (a & 0xFF) == 0 and d is not None and d & 1:
            c = (a - 0x1000) >> 8
            if ch is None or c == ch:
                out.append((k, c))
    return out

def fall(v, name, b, start):
    s = bit(v, name, b)
    return find(lambda k: s[k] == 0, start)

def rise(v, name, b, start):
    s = bit(v, name, b)
    return find(lambda k: s[k] == 1, start)

def hs(v, valid, ready, start=0, nth=0, end=None):
    a, b = v.series(valid), v.series(ready)
    return find(lambda k: a[k] and b[k], start, end, nth)

def apb_write_cycle(v, addr, start=0, nth=0, data=None):
    n = 0
    for k, w, a, d in apb_xfers(v):
        if k >= start and w and a == addr and (data is None or d == data):
            if n == nth:
                return k
            n += 1
    return None

def apb_read_cycle(v, addr, start=0, nth=0):
    n = 0
    for k, w, a, d in apb_xfers(v):
        if k >= start and not w and a == addr:
            if n == nth:
                return k
            n += 1
    return None

def trig_port(v, name, start, nports=4):
    best = None
    for p in range(nports):
        k = rise(v, name, p, start)
        if k is not None and (best is None or k < best[0]):
            best = (k, p)
    return best[1]

def cmd_window(nth, pre=3, post=4, ch=None):
    def f(v):
        k, c = enables(v, ch)[nth]
        e = fall(v, "ch_enabled", c, k + 3)
        return (k - pre, e + post)
    return f

# ----------------------------------------------------------------------------- figures
FIGS = []

def fig(fid, title, test, win, rows, hscale=2, compress=0, plus="", until=None, marks=(), edges=()):
    FIGS.append(dict(id=fid, title=title, test=test, win=win, rows=rows, hscale=hscale, compress=compress,
                     plus=plus, until=until, marks=marks, edges=edges))

# ===== helpers: configuration phase of a figure
CHREG = {0x00: "CMD", 0x04: "STATUS", 0x08: "INTREN", 0x0C: "CTRL", 0x10: "SRCADDR", 0x14: "SRCADDRHI", 0x18: "DESADDR",
         0x1C: "DESADDRHI", 0x20: "XSIZE", 0x24: "XSIZEHI", 0x28: "SRCTRANSCFG", 0x2C: "DESTRANSCFG", 0x30: "XADDRINC",
         0x34: "YADDRSTRIDE", 0x38: "FILLVAL", 0x3C: "YSIZE", 0x40: "TMPLTCFG", 0x44: "SRCTMPLT", 0x48: "DESTMPLT",
         0x4C: "SRCTRIGINCFG", 0x50: "DESTRIGINCFG", 0x54: "TRIGOUTCFG", 0x58: "GPOEN0", 0x60: "GPOVAL0",
         0x68: "STREAMINTCFG", 0x70: "LINKATTR", 0x74: "AUTOCFG", 0x78: "LINKADDR", 0x7C: "LINKADDRHI", 0x90: "ERRINFO"}
APBNAMES = {}
for _c in range(8):
    for _o, _n in CHREG.items():
        APBNAMES[0x1000 + 0x100 * _c + _o] = "CH%d_%s" % (_c, _n)
for _base, _pre in ((0x100, "SEC_"), (0x200, "NSEC_")):
    for _o, _n in ((0x00, "CHINTRSTATUS0"), (0x08, "STATUS"), (0x0C, "CTRL"), (0x14, "CHPTR"), (0x18, "CHCFG")):
        APBNAMES[_base + _o] = _pre + _n

BASE = (0x08, 0x0C, 0x10, 0x18, 0x20, 0x28, 0x2C, 0x30)          # registers every copy command needs
R2D = BASE + (0x34, 0x3C)
RTRIG = BASE + (0x4C,)
RTRIG2 = BASE + (0x4C, 0x50)
RTRIGO = BASE + (0x54,)
RSTR = BASE + (0x68,)
RRST = BASE + (0x74,)
RLINK = (0x08, 0x0C, 0x78)

def apb_cfg_rows():
    return Group("APB", [B("PSEL", "psel"), B("PENABLE", "penable"), B("PWRITE", "pwrite"),
                         E("PADDR", "paddr", APBNAMES, valid="psel", col="3"),
                         V("PWDATA", "pwdata", valid=("psel", "pwrite"), strip=True, col="4"), B("PREADY", "pready")])

def access_start(v, c):
    """first cycle of the APB access that completes in cycle c"""
    pa, ps = v.series("paddr"), v.series("psel")
    s = c
    while s > 0 and ps[s - 1] and pa[s - 1] == pa[c]:
        s -= 1
    return s

def merge(segs, gap=2):
    out = []
    for s, e in sorted(segs):
        if out and s <= out[-1][1] + gap:
            out[-1] = (out[-1][0], max(out[-1][1], e))
        else:
            out.append((s, e))
    return out

def cfg_segments(v, k, ch, regs):
    """APB writes of the command programming block (before the ENABLECMD write in cycle k) that touch `regs`"""
    base = 0x1000 + 0x100 * ch
    xs = [(c, a) for c, w, a, d in apb_xfers(v) if w and c < k and a is not None and base <= a < base + 0x100]
    blk, prev = [], k
    for c, a in reversed(xs):                  # contiguous programming block
        if prev - c > 8:
            break
        blk.append((c, a)); prev = c
    return [(access_start(v, c), c) for c, a in reversed(blk) if (a - base) in regs]

def prog_win(nth, regs, post=4, ch=None, tail=None):
    """configuration writes -> ENABLECMD -> transaction until the channel is disabled again"""
    def f(v):
        k, c = enables(v, ch)[nth]
        segs = cfg_segments(v, k, c, regs)
        if tail:
            segs += tail(v, k, c)
        else:
            segs.append((access_start(v, k), fall(v, "ch_enabled", c, k + 3) + post))
        return merge(segs)
    return f

def copy_rows(ch=0, ar_f=("VALID", "READY", "ADDR", "LEN", "SIZE", "ID"), aw_f=("VALID", "READY", "ADDR", "LEN", "SIZE", "ID")):
    return lambda v: [apb_cfg_rows(), ch_rows(ch, status=("enabled", "irq")), ar_rows(fields=ar_f), r_rows(),
                      aw_rows(fields=aw_f), w_rows(), b_rows()]

def std_marks(nth, ch=None, irq_ch=None):
    """cause / effect markers of one copy command: ENABLECMD -> AR -> R -> AW -> W -> B -> interrupt"""
    def f(v):
        k, c = enables(v, ch)[nth]
        e = fall(v, "ch_enabled", c, k + 3)
        pts = [("a", "PADDR", k), ("b", "ARVALID", hs(v, "arvalid_m0", "arready_m0", k, end=e)),
               ("c", "RVALID", hs(v, "rvalid_m0", "rready_m0", k, end=e)),
               ("d", "AWVALID", hs(v, "awvalid_m0", "awready_m0", k, end=e)),
               ("e", "WVALID", hs(v, "wvalid_m0", "wready_m0", k, end=e)),
               ("f", "BVALID", hs(v, "bvalid_m0", "bready_m0", k, end=e)),
               ("g", "irq_channel[%d]" % c, rise(v, "irq_channel", c, k))]
        return [dict(row=r, cycle=cy, node=n) for n, r, cy in pts if cy is not None]
    return f

STD_EDGES = ["a~>b start latency", "b~>c read data", "c~>d FIFO has the burst", "d~>e", "e~>f write response", "f~>g DONE"]

# ===== 01 APB protocol and start of a command
T1D = "dma_dir_1d_test"
fig("apb_write", "APB write: CH_INTREN, CH_CTRL, CH_SRCADDR of channel 0 (back to back, 3 wait states each)", T1D,
    lambda v: (lambda k: (k - 3, k + 12))(apb_write_cycle(v, 0x1008)), lambda v: [apb_rows()], hscale=2)
fig("apb_read", "APB read: CH_STATUS of channel 0 after the command", T1D,
    lambda v: (lambda k: (k - 3, k + 8))(apb_read_cycle(v, 0x1004)), lambda v: [apb_rows()], hscale=2)
fig("start_latency", "Command start latency: ENABLECMD write -> channel FSM -> first AR", T1D,
    lambda v: (lambda k: (k - 4, hs(v, "arvalid_m0", "arready_m0", k) + 3))(apb_write_cycle(v, 0x1000, data=1)),
    lambda v: [apb_cfg_rows(), ch_rows(0, status=("enabled",)), ar_rows()], hscale=2)

# ===== 02 data movement
fig("copy_1d", "1D copy (TRM Fig. 5-1): program 23 bytes SRCADDR 0x101011 -> DESADDR 0x301014, enable, transfer, interrupt", T1D,
    prog_win(0, BASE, post=6), copy_rows(), hscale=2, marks=std_marks(0), edges=STD_EDGES)
fig("copy_1d_data", "1D copy (TRM Fig. 5-1), zoom: data and byte strobes of the read and write beats", T1D,
    lambda v: (lambda a, b: (a - 1, b + 1))(hs(v, "rvalid_m0", "rready_m0", 100), hs(v, "bvalid_m0", "bready_m0", 100)),
    lambda v: [r_rows(data=True), w_rows(data=True)], hscale=4, compress=4)

TBU = "dma_dir_burst_test"
fig("unopt_unaligned", "Unoptimized access (device memory, TRM 4.3.7): 13 bytes from 0x...003 use one byte per beat", TBU,
    prog_win(0, BASE, post=6), copy_rows(), hscale=2, marks=std_marks(0), edges=STD_EDGES)
fig("opt_unaligned", "Optimized access (normal memory, TRM 4.3.7): the same 13 bytes use full-width beats and write strobes", TBU,
    prog_win(1, BASE, post=6), copy_rows(), hscale=2, marks=std_marks(1), edges=STD_EDGES)
fig("opt_unaligned_end", "Unaligned end address (TRM 4.3.8): 3 bytes from an aligned start", TBU,
    prog_win(2, BASE, post=6), copy_rows(), hscale=2, marks=std_marks(2), edges=STD_EDGES)
fig("burst_1kb", "Burst split at a 1 KB boundary: 8 x 64-bit elements from 0x1013E0", TBU,
    prog_win(3, BASE, post=6), copy_rows(), hscale=2, marks=std_marks(3), edges=STD_EDGES)
fig("burst_maxlen", "MAXBURSTLEN: source SRCMAXBURSTLEN=3 (4 beats), destination DESMAXBURSTLEN=1 (2 beats)", TBU,
    prog_win(4, BASE, post=6), copy_rows(), hscale=2, marks=std_marks(4), edges=STD_EDGES)
fig("burst_fifo2", "FIFO/2 limit: channel 3 (FIFO of 4 words) - bursts of at most 2 beats", TBU,
    prog_win(5, BASE, post=6), copy_rows(3), hscale=2, marks=std_marks(5), edges=STD_EDGES)

T2D = "dma_dir_2d_test"
fig("copy_2d", "2D copy (TRM Fig. 5-5): 9 x 8 bytes, line stride 24, one burst per line", T2D,
    prog_win(0, R2D, post=6), copy_rows(), hscale=2, marks=std_marks(0), edges=STD_EDGES)

def data_win(nth, ch=None, rbeats=8):
    """AR + the first rbeats read beats, a gap, then the write beats up to the last B"""
    def f(v):
        k, c = enables(v, ch)[nth]
        e = fall(v, "ch_enabled", c, k + 3)
        a = hs(v, "rvalid_m0", "rready_m0", k, end=e)
        w = hs(v, "wvalid_m0", "wready_m0", k, end=e)
        b = hs(v, "bvalid_m0", "bready_m0", k, end=e)
        wl = [j for j in range(k, e) if v.series("bvalid_m0")[j] and v.series("bready_m0")[j]][-1]
        return merge([(a - 1, a + rbeats), (w - 1, wl + 1)], gap=1)
    return f

TWR = "dma_dir_wrap1d_test"
RFILL = BASE + (0x38,)
fig("wrap_1d", "1D WRAP (TRM 5.2.2): SRCXSIZE=5 bytes wrapped into DESXSIZE=17 bytes, XTYPE=wrap", TWR,
    prog_win(26, BASE, post=6), copy_rows(), hscale=2, marks=std_marks(26), edges=STD_EDGES)
fig("wrap_1d_data", "1D WRAP, zoom: the 5 source bytes repeat in the write data (byte lanes shifted by the destination offset)", TWR,
    data_win(26), lambda v: [r_rows(data=True), w_rows(data=True)], hscale=4)
fig("fill_1d", "1D FILL (TRM 5.2.2): SRCXSIZE=5 bytes then FILLVAL up to DESXSIZE=17 bytes, XTYPE=fill", TWR,
    prog_win(42, RFILL, post=6), copy_rows(), hscale=2, marks=std_marks(42), edges=STD_EDGES)
fig("fill_1d_data", "1D FILL, zoom: source bytes followed by the FILLVAL pattern in the write data", TWR,
    data_win(42), lambda v: [r_rows(data=True), w_rows(data=True)], hscale=4)

# ===== 03 command linking / restart
TLK = "dma_dir_link_test"
fig("cmd_link", "Command link (TRM 5.7.1 chain A): CH_LINKADDR -> HEADER_0 fetch (ARCMDLINK) -> copy", TLK,
    prog_win(0, RLINK, post=6),
    lambda v: [apb_cfg_rows(), ch_rows(0, status=("enabled", "irq")),
               ar_rows(fields=("VALID", "READY", "ADDR", "LEN", "ID", "CMDLINK")), r_rows(),
               aw_rows(fields=("VALID", "READY", "ADDR", "LEN")), w_rows(), b_rows()], hscale=2, compress=5)

TRS = "dma_restart_test"
def restart_tail(v, k, c):
    """first execution up to the restart (second CFG), a gap, then the last execution"""
    st = v.series("ch%d.st" % c)
    e = fall(v, "ch_enabled", c, k + 3)
    cfg = [j for j in range(k, e) if st[j] == 2 and st[j - 1] != 2]
    return [(access_start(v, k), cfg[0] + 6), (cfg[-1] - 3, e + 6)]
fig("auto_restart", "Auto-restart: CH_AUTOCFG.CMDRESTARTCNT=3 -> 4 executions of one command without CPU access (middle ones elided)", TRS,
    prog_win(0, RRST, tail=restart_tail),
    lambda v: [apb_cfg_rows(), ch_rows(0, status=("enabled", "irq")), ar_rows(fields=("VALID", "READY", "LEN")),
               aw_rows(fields=("VALID", "READY", "LEN")), b_rows()], hscale=1, compress=6)

# ===== 04 triggers
TTC = "dma_trig_cmd_test"
def trig_rows(v, start, nports=4, p=None):
    p = trig_port(v, "trig_in_req", start, nports) if p is None else p
    v.field("treq%d" % p, "trig_in_req", p)
    v.field("tack%d" % p, "trig_in_ack", p)
    v.field("treqt%d" % p, "trig_in_req_type", 2 * p + 1, 2 * p)
    v.field("tackt%d" % p, "trig_in_ack_type", 2 * p + 1, 2 * p)
    return Group("trig_in[%d]" % p, [B("req", "treq%d" % p), E("req_type", "treqt%d" % p, REQ, valid="treq%d" % p, col="3"),
                                     B("ack", "tack%d" % p), E("ack_type", "tackt%d" % p, ACK, valid="tack%d" % p, col="3")])

def trig_cmd_rows(v):
    k, ch = enables(v)[0]
    return [apb_cfg_rows(), ch_rows(ch, status=("enabled", "irq")), trig_rows(v, k),
            ar_rows(fields=("VALID", "READY", "LEN")), aw_rows(fields=("VALID", "READY", "LEN")), b_rows()]

def trig_cmd_win(v):
    k, ch = enables(v)[0]
    st = v.series("ch%d.st" % ch)
    wait = find(lambda j: st[j] == 8, k)
    p = trig_port(v, "trig_in_req", k)
    kr = rise(v, "trig_in_req", p, k)
    e = fall(v, "ch_enabled", ch, k + 3)
    return merge(cfg_segments(v, k, ch, RTRIG) + [(access_start(v, k), wait + 3), (kr - 3, e + 6)])
fig("trig_cmd_hw", "HW source command trigger: SRCTRIGINCFG, channel waits in CMDTRIG, the 4-phase request starts the transfer",
    TTC, trig_cmd_win, trig_cmd_rows, hscale=1, compress=6)

TTR = "dma_dir_trig_test"
def fc_rows(v):
    k, ch = enables(v)[0]
    p0 = trig_rows(v, k, p=0)
    p1 = trig_rows(v, k, p=1)
    for r in p0.rows:
        r.label = "src " + r.label
    for r in p1.rows:
        r.label = "dst " + r.label
    return [apb_cfg_rows(), ch_rows(ch, status=("enabled", "irq")), p0, p1,
            ar_rows(fields=("VALID", "READY", "LEN")), r_rows(), aw_rows(fields=("VALID", "READY", "LEN")),
            w_rows(), b_rows()]
fig("trig_flowctrl", "TRM Fig. 5-17: source DMA-driven flow control (blocks of 10) + destination command trigger",
    TTR, prog_win(0, RTRIG2, post=6), fc_rows, hscale=1, compress=6)

def trigout_rows(v):
    k, ch = enables(v, 0)[3]
    return [apb_cfg_rows(), ch_rows(ch, status=("enabled", "irq")),
            Group("trig_out[0]", [B("req", "trig_out_req", bit=0), B("ack", "trig_out_ack", bit=0)]), w_rows(), b_rows()]
fig("trig_out", "Trigger output (TRM Fig. 5-20): CH_TRIGOUTCFG, TRIGOUT state, 4-phase req/ack at the end of the command", TTR,
    prog_win(3, RTRIGO, post=8), trigout_rows, hscale=1, compress=6)

# ===== 05 stream
TST = "dma_dir_stream_test"
def sout_rows(v):
    v.field("so_valid", "str_out_tvalid", 0); v.field("so_ready", "str_out_tready", 0)
    v.field("so_last", "str_out_tlast", 0); v.field("so_strb", "str_out_tstrb", 7, 0)
    return [apb_cfg_rows(), ch_rows(0, status=("enabled", "irq")), ar_rows(fields=("VALID", "READY", "LEN")), r_rows(),
            Group("STR OUT", [B("tvalid", "so_valid"), B("tready", "so_ready"), B("tlast", "so_last", mask="so_valid"),
                              V("tstrb", "so_strb", valid="so_valid", ready=("so_valid", "so_ready"), col="3")]),
            aw_rows(fields=("VALID",))]
fig("stream_out", "AXI-Stream out only: CH_STREAMINTCFG, source memory -> str_out (no write on the AXI bus)", TST,
    prog_win(0, RSTR, post=6), sout_rows, hscale=1, compress=6)

def sin_rows(v):
    v.field("si_valid", "str_in_tvalid", 0); v.field("si_ready", "str_in_tready", 0)
    v.field("si_last", "str_in_tlast", 0); v.field("si_strb", "str_in_tstrb", 7, 0)
    return [apb_cfg_rows(), ch_rows(0, status=("enabled", "irq")),
            Group("STR IN", [B("tvalid", "si_valid"), B("tready", "si_ready"), B("tlast", "si_last", mask="si_valid"),
                             V("tstrb", "si_strb", valid="si_valid", ready=("si_valid", "si_ready"), col="3")]),
            aw_rows(fields=("VALID", "READY", "LEN")), w_rows(), b_rows()]
fig("stream_in", "AXI-Stream in only: CH_STREAMINTCFG, str_in packet -> destination memory (no read on the AXI bus)", TST,
    prog_win(1, RSTR, post=6), sin_rows, hscale=1, compress=6)

# ===== 06 control
TCT = "dma_ctrl_test"
def pause_tail(v, k, c):
    pk = apb_write_cycle(v, 0x1000, data=0x10)
    rk = apb_write_cycle(v, 0x1000, start=pk, data=0x20)
    pz = rise(v, "ch_paused", 0, pk)
    e = fall(v, "ch_enabled", 0, rk)
    return [(access_start(v, k), access_start(v, k) + 28), (access_start(v, pk), pz + 6), (access_start(v, rk), rk + 30),
            (e - 4, e + 6)]
fig("pause_resume", "PAUSECMD / RESUMECMD (CH_CMD bits 4 / 5) while a transfer is running (slow memory)", TCT,
    prog_win(0, BASE, tail=pause_tail),
    lambda v: [apb_cfg_rows(), ch_rows(0, status=("enabled", "paused", "irq")),
               ar_rows(fields=("VALID", "READY")), r_rows(), aw_rows(fields=("VALID", "READY")), w_rows(), b_rows()],
    hscale=1, compress=8)

def stop_tail(v, k, c):
    sk = apb_write_cycle(v, 0x1100, data=0x8)
    e = fall(v, "ch_enabled", 1, sk)
    return [(access_start(v, k), access_start(v, k) + 28), (access_start(v, sk), e + 6)]
fig("stop", "STOPCMD (CH_CMD bit 3): no new bursts, outstanding transactions finish, STOP -> FIN (channel 1)", TCT,
    prog_win(0, BASE, tail=stop_tail, ch=1),
    lambda v: [apb_cfg_rows(), ch_rows(1, status=("enabled", "stopped", "irq")),
               ar_rows(fields=("VALID", "READY", "LEN")), r_rows(),
               aw_rows(fields=("VALID", "READY", "LEN")), w_rows(), b_rows()], hscale=1, compress=8)

# ===== 07 errors
TER = "dma_err_test"
fig("err_read", "AXI read error: RRESP=SLVERR ends the command with STAT_ERR (channel 0)", TER,
    prog_win(0, BASE, post=8),
    lambda v: [apb_cfg_rows(), ch_rows(0, status=("enabled", "err", "irq")), ar_rows(fields=("VALID", "READY", "LEN")),
               r_rows(resp=True), aw_rows(fields=("VALID", "READY", "LEN")), w_rows(), b_rows()],
    hscale=1, compress=6)
fig("err_write", "AXI write error: BRESP=SLVERR ends the command with STAT_ERR (channel 1)", TER,
    prog_win(1, BASE, post=8),
    lambda v: [apb_cfg_rows(), ch_rows(1, status=("enabled", "err", "irq")), ar_rows(fields=("VALID", "READY", "LEN")),
               r_rows(), aw_rows(fields=("VALID", "READY", "LEN")), w_rows(), b_rows()], hscale=1, compress=6)
fig("err_cfg", "Configuration error (REGVALERR): illegal XTYPE in CH_CTRL is rejected in CHK, no AXI traffic", TER,
    prog_win(3, (0x0C,), post=8),
    lambda v: [apb_cfg_rows(), ch_rows(0, status=("enabled", "err", "irq")), ar_rows(fields=("VALID",)), aw_rows(fields=("VALID",))],
    hscale=1)

# ===== 08 low power
TLP = "dma_lpi_test"
fig("lpi_q", "Q-Channel: clock quiescence request accepted while idle, denied while transferring", TLP,
    lambda v: (lambda a, b: (a - 4, b + 14))(fall(v, "clk_qreqn", None, 0), fall(v, "clk_qreqn", None, fall(v, "clk_qreqn", None, 0) + 30)),
    lambda v: [B("clk_qreqn"), B("clk_qacceptn"), B("clk_qdeny"), B("clk_qactive"),
               ch_rows(0, status=("enabled",))], hscale=2, compress=10)

# ===== 09 arbitration
TMC = "dma_multi_ch_test"
def mc_win(v):
    ens = enables(v)[:4]
    k0 = ens[0][0]
    return merge([(access_start(v, k), k + 1) for k, c in ens] + [(k0, k0 + 70)])
fig("multi_ch_arb", "Four channels enabled back to back: AR / AW arbitration (ID = channel, QOS = CHPRIO)", TMC,
    mc_win,
    lambda v: [apb_cfg_rows(), Group("CH enabled", [B("ch_enabled[%d]" % c, "ch_enabled", bit=c) for c in range(4)]),
               ar_rows(fields=("VALID", "READY", "ADDR", "LEN", "ID", "QOS"), attr=True),
               aw_rows(fields=("VALID", "READY", "ADDR", "LEN", "ID", "QOS"), attr=True), b_rows()], hscale=2, compress=8)

# ===== 10 more operations
def stream_in_group(v):
    v.field("si_valid", "str_in_tvalid", 0); v.field("si_ready", "str_in_tready", 0)
    v.field("si_last", "str_in_tlast", 0); v.field("si_strb", "str_in_tstrb", 7, 0)
    return Group("STR IN", [B("tvalid", "si_valid"), B("tready", "si_ready"), B("tlast", "si_last", mask="si_valid"),
                            V("tstrb", "si_strb", valid="si_valid", ready=("si_valid", "si_ready"), col="3")])

def stream_out_group(v):
    v.field("so_valid", "str_out_tvalid", 0); v.field("so_ready", "str_out_tready", 0)
    v.field("so_last", "str_out_tlast", 0); v.field("so_strb", "str_out_tstrb", 7, 0)
    return Group("STR OUT", [B("tvalid", "so_valid"), B("tready", "so_ready"), B("tlast", "so_last", mask="so_valid"),
                             V("tstrb", "so_strb", valid="so_valid", ready=("so_valid", "so_ready"), col="3")])

R_INOUT = R2D + (0x68,)
fig("stream_inout", "Stream in & out through an external engine (2D, fill): AXI read -> str_out -> engine -> str_in -> AXI write", TST,
    prog_win(7, R_INOUT, post=6),
    lambda v: [apb_cfg_rows(), ch_rows(0, status=("enabled", "irq")), ar_rows(fields=("VALID", "READY", "LEN")), r_rows(),
               stream_out_group(v), stream_in_group(v), aw_rows(fields=("VALID", "READY", "LEN")), w_rows(), b_rows()],
    hscale=1, compress=6)

fig("cmd_link_chain", "Command link chain (TRM 5.7.1 chain B): HEADER_1 (partial update) -> copy -> HEADER_2 -> copy", TLK,
    prog_win(1, RLINK, post=6),
    lambda v: [apb_cfg_rows(), ch_rows(0, status=("enabled", "irq")),
               ar_rows(fields=("VALID", "READY", "LEN", "CMDLINK")), r_rows(),
               aw_rows(fields=("VALID", "READY", "LEN")), w_rows(), b_rows()], hscale=1, compress=5)

def done_pause_tail(v, k, c):
    p = rise(v, "ch_paused", 0, k)
    rk = apb_write_cycle(v, 0x1000, start=p, data=0x20)
    e = fall(v, "ch_enabled", 0, rk)
    return [(access_start(v, k), access_start(v, k) + 6), (p - 24, p + 8), (access_start(v, rk) - 2, e + 6)]
fig("done_pause", "DONEPAUSEEN: the channel pauses (RESUMEWAIT) after the first linked command until RESUMECMD", "dma_dir_done_test",
    prog_win(3, (0x0C, 0x10, 0x18, 0x20, 0x78), tail=done_pause_tail),
    lambda v: [apb_cfg_rows(), ch_rows(0, status=("enabled", "paused", "irq")), ar_rows(fields=("VALID", "READY", "CMDLINK")),
               aw_rows(fields=("VALID", "READY")), b_rows()], hscale=1, compress=6)

fig("trig_sw", "Software triggers: source DMA-driven flow control driven by CH_CMD writes (SRCSWTRIGINREQ), 10 elements in blocks of 4",
    "dma_dir_trig_sw_test", prog_win(0, RTRIG, post=6),
    lambda v: [apb_cfg_rows(), ch_rows(0, status=("enabled", "irq")), ar_rows(fields=("VALID", "READY", "LEN")), r_rows(),
               aw_rows(fields=("VALID", "READY", "LEN")), w_rows(), b_rows()], hscale=1, compress=6)

def trig_internal_win(v):
    ens = enables(v)
    k1, c1 = ens[9]
    k0, c0 = ens[10]
    e1 = fall(v, "ch_enabled", c1, k0)
    return merge(cfg_segments(v, k1, c1, (0x0C, 0x4C)) + [(access_start(v, k1), k1 + 12)] +
                 cfg_segments(v, k0, c0, (0x0C, 0x54)) + [(access_start(v, k0), e1 + 6)])
fig("trig_internal", "Internal trigger: channel 0 trigger output starts channel 1 (source command trigger, no external ports)", TTC,
    trig_internal_win,
    lambda v: [apb_cfg_rows(), Group("enabled", [B("ch_enabled[0]", "ch_enabled", bit=0), B("ch_enabled[1]", "ch_enabled", bit=1)]),
               E("FSM ch0", "ch0.st", FSM, col="2"), E("FSM ch1", "ch1.st", FSM, col="2"),
               Group("irq", [B("irq_channel[0]", "irq_channel", bit=0), B("irq_channel[1]", "irq_channel", bit=1)]),
               ar_rows(fields=("VALID", "READY", "LEN", "ID")), aw_rows(fields=("VALID", "READY", "LEN", "ID")), b_rows()],
    hscale=1, compress=6)

def gpo_rows(v):
    v.field("gpo0", "gpo_ch", 7, 0)
    return Group("GPO", [V("gpo_ch[0][7:0]", "gpo0", fmt="hex", col="3")])
TGP = "dma_gpo_irq_test"
fig("gpo", "General purpose output: GPOEN0 / GPOVAL0 are applied in the GPO state and stay stable after the command", TGP,
    prog_win(0, BASE + (0x58, 0x60), post=8),
    lambda v: [apb_cfg_rows(), ch_rows(0, status=("enabled", "irq")), gpo_rows(v),
               ar_rows(fields=("VALID", "READY", "LEN")), aw_rows(fields=("VALID", "READY", "LEN")), b_rows()], hscale=1)

def autoboot_win(v):
    return [(14, 60), (62, 80), (143, 192), (214, 228)]
fig("autoboot", "Autoboot: after reset the DMA fetches a two-command chain into channel 0 with no APB access", "dma_autoboot_test",
    autoboot_win,
    lambda v: [Group("boot", [B("resetn"), B("boot_en"), V("{boot_addr,2'b00}", "boot_addr", strip=True, col="3")]),
               ch_rows(0, status=("enabled", "irq")),
               ar_rows(fields=("VALID", "READY", "LEN", "CMDLINK")), r_rows(),
               aw_rows(fields=("VALID", "READY", "LEN")), w_rows(), b_rows()],
    hscale=1, until="40us")

def ev_win(sig_req, sig_ack, nth_en, ch):
    def f(v):
        k, c = enables(v, ch)[nth_en]
        rq = find(lambda j: v.series(sig_req)[j] == 1, k)
        ak = find(lambda j: v.series(sig_ack)[j] == 1, rq)
        rl = find(lambda j: v.series(sig_req)[j] == 0, rq)
        al = find(lambda j: v.series(sig_ack)[j] == 0, rl)
        e = fall(v, "ch_enabled", c, k + 3)
        return merge(cfg_segments(v, k, c, BASE) + [(access_start(v, k), access_start(v, k) + 20), (rq - 6, ak + 6),
                                                    (rl - 3, al + 6), (e - 4, e + 6)])
    return f

def ctrl_rows(ch, extra, status):
    return lambda v: [apb_cfg_rows(), ch_rows(ch, status=status), Group("ctrl", extra),
                      ar_rows(fields=("VALID", "READY")), r_rows(), aw_rows(fields=("VALID", "READY")), w_rows(), b_rows()]

fig("allch_pause_hw", "All-channel pause, hardware 4-phase handshake (allch_pause_req / allch_pause_ack, Secure)", TCT,
    ev_win("allch_pause_req_sec", "allch_pause_ack_sec", 2, 0),
    ctrl_rows(0, [B("allch_pause_req_sec"), B("allch_pause_ack_sec")], ("enabled", "paused", "irq")), hscale=1, compress=8)
fig("allch_stop_hw", "All-channel stop, hardware 4-phase handshake (allch_stop_req / allch_stop_ack, Secure)", TCT,
    ev_win("allch_stop_req_sec", "allch_stop_ack_sec", 2, 1),
    ctrl_rows(1, [B("allch_stop_req_sec"), B("allch_stop_ack_sec")], ("enabled", "stopped", "irq")), hscale=1, compress=8)

def cti_win(v):
    k, c = enables(v, 0)[3]
    h = find(lambda j: v.series("halt_req")[j] == 1, k)
    hd = find(lambda j: v.series("halted")[j] == 1, h)
    r = find(lambda j: v.series("restart_req")[j] == 1, hd)
    pr = find(lambda j: v.series("ch_paused")[j] == 0, hd)
    e = fall(v, "ch_enabled", c, k + 3)
    u = [cc for cc, wr, a, d in apb_xfers(v) if wr and a == 0x10C and cc < k]      # SEC_CTRL write (DBGHALTEN)
    extra = [(access_start(v, u[-1]), u[-1])] if u else []
    return merge(extra + cfg_segments(v, k, c, BASE) + [(access_start(v, k), access_start(v, k) + 20), (h - 6, hd + 6),
                                                       (r - 4, pr + 6), (e - 4, e + 6)])
fig("cti_halt", "Cross Trigger Interface: halt_req pauses all channels, halted pulses, restart_req resumes them", TCT,
    cti_win,
    ctrl_rows(0, [B("halt_req"), B("halted"), B("restart_req")], ("enabled", "paused", "irq")), hscale=1, compress=8)

def lpi_p_win(v):
    a = find(lambda j: v.series("preq")[j] == 1, 200)
    b = find(lambda j: v.series("preq")[j] == 1, 400)
    return [(a - 4, a + 42), (b - 6, b + 12)]
fig("lpi_p", "P-Channel: OFF denied while transferring, WARM_RST accepted (channel paused), ON resumes it", TLP,
    lpi_p_win,
    lambda v: [Group("P-Channel", [B("preq"), V("pstate", "pstate", fmt="dec", col="3"), B("paccept"), B("pdeny"),
                                   B("pactive[8] (ON)", "pactive", bit=8)]),
               ch_rows(0, status=("enabled", "paused")), ar_rows(fields=("VALID", "READY")), r_rows(),
               aw_rows(fields=("VALID", "READY")), w_rows()], hscale=1, compress=12)


# ----------------------------------------------------------------------------- facts
def facts(v, s, e, base):
    g = v.series
    def val(n, k):
        x = g(n)[k]
        return "x" if x is None else "%x" % x
    lines = []
    for k in range(s, e + 1):
        t = []
        if g("psel")[k] and g("penable")[k] and g("pready")[k]:
            t.append("APB%s %s=%s" % ("W" if g("pwrite")[k] else "R", val("paddr", k), val("pwdata", k) if g("pwrite")[k] else val("prdata", k)))
        for ch, nm in (("ar", "AR"), ("aw", "AW")):
            if g(ch + "valid_m0")[k] and g(ch + "ready_m0")[k]:
                t.append("%s addr=%s len=%s size=%s id=%s%s" % (nm, val(ch + "addr_m0", k), val(ch + "len_m0", k), val(ch + "size_m0", k), val(ch + "id_m0", k),
                         " CMDLINK" if ch == "ar" and g("arcmdlink_m0")[k] else ""))
        if g("rvalid_m0")[k] and g("rready_m0")[k]:
            t.append("R id=%s last=%s resp=%s" % (val("rid_m0", k), val("rlast_m0", k), val("rresp_m0", k)))
        if g("wvalid_m0")[k] and g("wready_m0")[k]:
            t.append("W last=%s strb=%s" % (val("wlast_m0", k), val("wstrb_m0", k)))
        if g("bvalid_m0")[k] and g("bready_m0")[k]:
            t.append("B id=%s resp=%s" % (val("bid_m0", k), val("bresp_m0", k)))
        for n in ("ch_enabled", "irq_channel", "ch_err", "ch_stopped", "ch_paused", "trig_in_req", "trig_in_ack", "trig_out_req",
                  "trig_out_ack", "str_out_tvalid", "str_in_tvalid", "clk_qreqn", "clk_qacceptn", "clk_qdeny",
                  "allch_pause_req_sec", "allch_pause_ack_sec", "allch_stop_req_sec", "allch_stop_ack_sec", "halt_req", "halted",
                  "restart_req", "preq", "pstate", "paccept", "pdeny", "resetn", "boot_en", "gpo_ch"):
            if k > 0 and g(n)[k] != g(n)[k - 1]:
                t.append("%s %s->%s" % (n, val(n, k - 1), val(n, k)))
        for c in range(4):
            n = "ch%d.st" % c
            if k > 0 and g(n)[k] != g(n)[k - 1]:
                t.append("ch%d %s" % (c, FSM.get(g(n)[k], g(n)[k])))
        if t:
            lines.append("  [%4d]  %s" % (k - base, " | ".join(t)))
    return "\n".join(lines)

# ----------------------------------------------------------------------------- run
def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--work", required=True)
    ap.add_argument("--resim", action="store_true")
    ap.add_argument("--only", default="")
    ap.add_argument("--facts", action="store_true")
    a = ap.parse_args()
    only = set(x for x in a.only.split(",") if x)
    vdir = os.path.join(os.path.abspath(a.work), "vcd")
    os.makedirs(vdir, exist_ok=True)
    os.makedirs(os.path.join(OUT, "wavejson"), exist_ok=True)
    os.makedirs(os.path.join(OUT, "svg"), exist_ok=True)
    cache = {}
    for f in FIGS:
        if only and f["id"] not in only:
            continue
        key = (f["test"], f["plus"])
        path = os.path.join(vdir, "%s.vcd" % f["test"])
        if key not in cache:
            if a.resim or not os.path.exists(path):
                wave_sim.run(a.work, f["test"], SEED, f["until"] or UNTIL, path, f["plus"])
            cache[key] = Vcd(path)
        v = cache[key]
        win = f["win"](v)
        segs = [win] if isinstance(win, tuple) else win
        marks = f["marks"](v) if callable(f["marks"]) else f["marks"]
        j = build(v, f["rows"](v), win, title=f["title"], hscale=f["hscale"], compress=f["compress"],
                  marks=marks, edges=f["edges"])
        with open(os.path.join(OUT, "wavejson", f["id"] + ".json"), "w") as fh:
            json.dump(j, fh, indent=1)
        render_svg(j, os.path.join(OUT, "svg", f["id"] + ".svg"))
        ncol = len(j["signal"][0]["wave"])
        print("%-14s %-24s segments %s  columns %d  t=%.0f ns" % (f["id"], f["test"], segs, ncol, v.ns(segs[0][0])))
        if a.facts:
            for (s, e) in segs:
                print(facts(v, s, e, segs[0][0]))
                print("  ...")

if __name__ == "__main__":
    main()
