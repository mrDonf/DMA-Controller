#!/usr/bin/env python3
"""
cov_report.py - summary of the RTL code coverage per design unit (dma_* modules)
                from `vcover report -code bcesft -bydu <merged.ucdb>` output.

  python scripts/cov_report.py sim/regress/<stamp>        (uses merged.ucdb there)
"""
import os, re, subprocess, sys

QUESTA = os.environ.get("QUESTA_BIN", r"C:/questasim64_10.7c/win64")
KEYS = [("Stmts", "stmt"), ("Branches", "branch"), ("FEC Condition Terms", "cond"),
        ("FEC Expression Terms", "expr"), ("States", "fsm_st"), ("Transitions", "fsm_tr"),
        ("Toggle Bins", "toggle")]
RTL_UNITS = ("dma_apb_if", "dma_biu", "dma_cdc_sync", "dma_ch_", "dma_channel", "dma_fifo_ff", "dma_lpi",
             "dma_lrg_arb", "dma_reset_sync", "dma_rs_", "dma_sram_2p", "dma_top", "dma_trig_mtx", "dma_unit")

def main():
    rdir = sys.argv[1]
    ucdb = os.path.join(rdir, "merged.ucdb")
    out = subprocess.run([os.path.join(QUESTA, "vcover"), "report", "-code", "bcesft", "-bydu", ucdb],
                         capture_output=True, text=True).stdout
    rows, tot = [], {k: [0, 0] for _, k in KEYS}
    for blk in re.split(r"\n(?==== Design Unit:)", out):
        m = re.search(r"=== Design Unit: \w+\.(\w+)", blk)
        if not m or not m.group(1).startswith(RTL_UNITS):
            continue
        r = {"unit": m.group(1)}
        for key, short in KEYS:
            mm = re.search(r"\n\s*%s\s+(\d+)\s+(\d+)\s+(\d+)\s+([\d.]+)" % re.escape(key), blk)
            if mm:
                r[short] = float(mm.group(4))
                tot[short][0] += int(mm.group(1)); tot[short][1] += int(mm.group(2))
        rows.append(r)
    hdr = ["unit"] + [s for _, s in KEYS]
    lines = ["| " + " | ".join(hdr) + " |", "|" + "---|" * len(hdr)]
    for r in rows:
        lines.append("| " + " | ".join([r["unit"]] + ["%.1f" % r[s] if s in r else "-" for s in hdr[1:]]) + " |")
    lines.append("| **total** | " + " | ".join(
        "**%.1f**" % (100.0 * tot[s][1] / tot[s][0]) if tot[s][0] else "-" for s in hdr[1:]) + " |")
    txt = "\n".join(lines)
    open(os.path.join(rdir, "cov_rtl_summary.md"), "w").write(txt + "\n")
    print(txt)

if __name__ == "__main__":
    main()
