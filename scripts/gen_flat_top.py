#!/usr/bin/env python3
"""
gen_flat_top.py - generate a configuration specific wrapper of rtl/dma_top.sv
                  with the per-index signal names of the DMA-350 TRM (chapter 3):

    trig_in_<TI>_req / _req_type / _ack / _ack_type, trig_out_<TO>_req / _ack
    str_out_<N>_tvalid / _tready / _tdata / _tstrb / _tlast
    str_in_<N>_tvalid / _tready / _tdata / _tstrb / _tlast, str_in_<N>_flush
    gpo_ch_<N>

  * stream ports only for the channels of CH_STREAM_MASK, GPO only for CH_GPO_MASK
  * M1 ports only when AXI5_M1_PRESENT, CHID ports only when CHID_WIDTH > 0,
    trigger ports only when NUM_TRIGGER_IN / OUT > 0 (unused inputs tied off)
  * every other port keeps the dma_top name

The port list is parsed from rtl/dma_top.sv, so the wrapper follows RTL changes.

  python scripts/gen_flat_top.py --name dma_ctrl --num-ch 4 --ti 4 --to 4 \
      --stream-mask 0x03 --gpo-mask 0x0F --m1 1 -o rtl/gen/dma_ctrl.sv
"""
import argparse, os, re, sys

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), ".."))
PORT_RE = re.compile(r"^\s*(input|output)\s+logic\s*((?:\[[^\]]+\]\s*)*)\s*(\w+)\s*,?\s*(//.*)?$")

def parse_ports(path):
    ports, in_ports = [], False
    for line in open(path):
        if re.match(r"^\)\s*\(", line):
            in_ports = True
            continue
        if in_ports and re.match(r"^\);", line):
            break
        if not in_ports:
            continue
        m = PORT_RE.match(line)
        if m:
            dims = re.findall(r"\[[^\]]+\]", m.group(2))
            ports.append((m.group(1), dims, m.group(3)))
    return ports

def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--name", default="dma_ctrl")
    ap.add_argument("--num-ch", type=int, default=4)
    ap.add_argument("--aw", type=int, default=32)
    ap.add_argument("--dw", type=int, default=64)
    ap.add_argument("--chid-w", type=int, default=0)
    ap.add_argument("--gpo-w", type=int, default=8)
    ap.add_argument("--gpo-mask", type=lambda s: int(s, 0), default=0xFF)
    ap.add_argument("--stream-mask", type=lambda s: int(s, 0), default=0x00)
    ap.add_argument("--ext-mask", type=lambda s: int(s, 0), default=0xFF)
    ap.add_argument("--fifo-depth", default="16,16,16,16,16,16,16,16", help="8 comma separated depths (words)")
    ap.add_argument("--ti", type=int, default=4)
    ap.add_argument("--to", type=int, default=4)
    ap.add_argument("--ti-sync", type=lambda s: int(s, 0), default=0xFFFFFFFF)
    ap.add_argument("--to-sync", type=lambda s: int(s, 0), default=0xFFFFFFFF)
    ap.add_argument("--m1", type=int, default=0)
    ap.add_argument("--secext", type=int, default=1)
    ap.add_argument("--mem-impl", type=int, default=0)
    ap.add_argument("-o", "--out", default=None)
    a = ap.parse_args()

    nch = a.num_ch
    if not 1 <= nch <= 8:
        sys.exit("--num-ch must be 1..8")
    fd = [int(x) for x in a.fifo_depth.split(",")]
    if len(fd) != 8:
        sys.exit("--fifo-depth needs 8 values")
    stream = [c for c in range(nch) if (a.stream_mask >> c) & 1]
    gpo = [c for c in range(nch) if (a.gpo_mask >> c) & 1] if a.gpo_w > 0 else []
    ports = parse_ports(os.path.join(ROOT, "rtl", "dma_top.sv"))

    hdr, decl, conn, body = [], [], [], []

    def keep(name):
        if name.endswith("_m1") and not a.m1:
            return False
        if re.match(r"^(aw|ar)chid(valid)?_m\d$", name) and a.chid_w == 0:
            return False
        return True

    for d, dims, name in ports:
        w = " ".join(dims)
        # ---- trigger inputs / outputs: one port group per index
        if name.startswith("trig_in_") or name.startswith("trig_out_"):
            n = a.ti if name.startswith("trig_in_") else a.to
            sub = name.split("_", 2)[2]                          # req / req_type / ack / ack_type
            pfx = "trig_in" if name.startswith("trig_in_") else "trig_out"
            elem = " ".join(dims[1:])
            decl.append("  logic %s %s;" % (w, name))
            for i in range(n):
                pn = "%s_%d_%s" % (pfx, i, sub)
                hdr.append("  %-6s logic %-12s %s" % (d, elem, pn))
                if d == "input":
                    body.append("  assign %s[%d] = %s;" % (name, i, pn))
                else:
                    body.append("  assign %s = %s[%d];" % (pn, name, i))
            if d == "input" and n == 0:
                body.append("  assign %s = '0;" % name)
            conn.append((name, name))
            continue
        # ---- AXI-Stream: per enabled channel
        m = re.match(r"^str_(out|in)_(\w+)$", name)
        if m:
            elem = " ".join(dims[1:])
            decl.append("  logic %s %s;" % (w, name))
            for c in range(nch):
                if c in stream:
                    pn = "str_%s_%d_%s" % (m.group(1), c, m.group(2))
                    hdr.append("  %-6s logic %-12s %s" % (d, elem, pn))
                    body.append("  assign %s[%d] = %s;" % (name, c, pn) if d == "input" else "  assign %s = %s[%d];" % (pn, name, c))
                elif d == "input":
                    body.append("  assign %s[%d] = '0;" % (name, c))
            conn.append((name, name))
            continue
        # ---- GPO per enabled channel
        if name == "gpo_ch":
            decl.append("  logic %s %s;" % (w, name))
            for c in gpo:
                hdr.append("  %-6s logic %-12s gpo_ch_%d" % (d, " ".join(dims[1:]), c))
                body.append("  assign gpo_ch_%d = %s[%d];" % (c, name, c))
            conn.append((name, name))
            continue
        if not keep(name):
            if d == "input":
                conn.append((name, "'0"))
            else:
                conn.append((name, ""))
            continue
        hdr.append("  %-6s logic %-12s %s" % (d, w, name))
        conn.append((name, name))

    lines = []
    lines.append("//-----------------------------------------------------------------------------")
    lines.append("// %s.sv - GENERATED by scripts/gen_flat_top.py, do not edit." % a.name)
    lines.append("// Configuration wrapper of dma_top with the TRM per-index port names.")
    lines.append("//   " + " ".join(sys.argv[1:]))
    lines.append("//-----------------------------------------------------------------------------")
    lp = [("NUM_CHANNELS", "%d" % nch), ("ADDR_WIDTH", "%d" % a.aw), ("DATA_WIDTH", "%d" % a.dw),
          ("ID_WIDTH", "(NUM_CHANNELS > 1) ? $clog2(NUM_CHANNELS) : 1"), ("STRB_WIDTH", "DATA_WIDTH / 8"),
          ("POIS_WIDTH", "(DATA_WIDTH + 63) / 64"), ("CHW", "%d" % max(1, a.chid_w)), ("GW", "%d" % max(1, a.gpo_w)),
          ("NTI", "%d" % max(1, a.ti)), ("NTO", "%d" % max(1, a.to))]
    lines.append("module %s #(" % a.name)
    lines.append(",\n".join("  localparam int %-12s = %s" % x for x in lp))
    lines.append(") (")
    lines.append(",\n".join(hdr))
    lines.append(");")
    lines.append("")
    lines += decl
    lines.append("")
    lines += body
    lines.append("")
    lines.append("  dma_top #(")
    params = [("NUM_CHANNELS", str(nch)), ("ADDR_WIDTH", str(a.aw)), ("DATA_WIDTH", str(a.dw)),
              ("CHID_WIDTH", str(a.chid_w)), ("GPO_WIDTH", str(a.gpo_w)),
              ("CH_GPO_MASK", "8'h%02X" % (a.gpo_mask & 0xFF)), ("CH_STREAM_MASK", "8'h%02X" % (a.stream_mask & 0xFF)),
              ("CH_EXT_FEAT_MASK", "8'h%02X" % (a.ext_mask & 0xFF)),
              ("CH_FIFO_DEPTH", "'{%s}" % ", ".join(str(x) for x in fd)),
              ("NUM_TRIGGER_IN", str(a.ti)), ("NUM_TRIGGER_OUT", str(a.to)),
              ("TRIG_IN_SYNC_EN_MASK", "32'h%08X" % a.ti_sync), ("TRIG_OUT_SYNC_EN_MASK", "32'h%08X" % a.to_sync),
              ("AXI5_M1_PRESENT", "1'b%d" % (1 if a.m1 else 0)), ("SECEXT_PRESENT", "1'b%d" % (1 if a.secext else 0)),
              ("MEM_IMPL", str(a.mem_impl))]
    lines.append(",\n".join("    .%s(%s)" % p for p in params))
    lines.append("  ) u_dma (")
    lines.append(",\n".join("    .%s(%s)" % c for c in conn))
    lines.append("  );")
    lines.append("endmodule : %s" % a.name)
    txt = "\n".join(lines) + "\n"
    if a.out:
        os.makedirs(os.path.dirname(os.path.abspath(a.out)), exist_ok=True)
        open(a.out, "w").write(txt)
        print("wrote", a.out)
    else:
        sys.stdout.write(txt)

if __name__ == "__main__":
    main()
