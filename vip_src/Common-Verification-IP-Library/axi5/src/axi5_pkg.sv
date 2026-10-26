// -----------------------------------------------------------------------------
// axi5_pkg - UVM VIP for AMBA AXI5 (IHI0022 Issue H and later, "AXI5" interface)
//
//   Everything of the AXI4 VIP (bursts of up to 256 beats, outstanding transactions, out-of-order responses, read data
//   interleaving, exclusive access, narrow / unaligned transfers, all response codes) plus the AXI5 extensions:
//     Atomic_Transactions  AWATOP: AtomicStore / AtomicLoad (ADD CLR EOR SET SMAX SMIN UMAX UMIN, both endiannesses),
//                          AtomicSwap, AtomicCompare; read data on R with the AWID
//     Poison               WPOISON / RPOISON, one bit per 64 data bits
//     Check_Type           WDATACHK / RDATACHK, odd parity per data byte
//     Unique_ID_Support    AWIDUNQ / BIDUNQ / ARIDUNQ / RIDUNQ
//     Trace_Signals        AWTRACE / WTRACE / BTRACE / ARTRACE / RTRACE
//     Loopback_Signals     AWLOOP / BLOOP / ARLOOP / RLOOP
//     Wakeup_Signals       AWAKEUP
//   Not modelled (see VIP/docs/axi5_vip.md): read data chunking, MTE tags, cache maintenance / stash / prefetch
//   (AxSNOOP), untranslated transactions (MMU signals), NSE / RME, MPAM, consistent decode properties.
//
//   Compile with +define+AXI5_ADDR_W / AXI5_DATA_W / AXI5_ID_W / AXI5_USER_W / AXI5_LOOP_W
//   (defaults 32 / 32 / 4 / 1 / 4). Roles: VIP_MASTER (manager), VIP_SLAVE (memory subordinate), VIP_MONITOR.
//   Item level: one item = one write burst (AW+W+B, + R for atomics with read data) or one read burst (AR+R).
// -----------------------------------------------------------------------------
`ifndef AXI5_PKG_SV
`define AXI5_PKG_SV

`include "uvm_macros.svh"
`include "vip_macros.svh"

`ifndef AXI5_ADDR_W
  `define AXI5_ADDR_W 32
`endif
`ifndef AXI5_DATA_W
  `define AXI5_DATA_W 32
`endif
`ifndef AXI5_ID_W
  `define AXI5_ID_W 4
`endif
`ifndef AXI5_USER_W
  `define AXI5_USER_W 1
`endif
`ifndef AXI5_LOOP_W
  `define AXI5_LOOP_W 4
`endif

package axi5_pkg;
  import uvm_pkg::*;
  import vip_common_pkg::*;

  localparam int AXI5_ADDR_W   = `AXI5_ADDR_W;
  localparam int AXI5_DATA_W   = `AXI5_DATA_W;
  localparam int AXI5_ID_W     = `AXI5_ID_W;
  localparam int AXI5_USER_W   = `AXI5_USER_W;
  localparam int AXI5_LOOP_W   = `AXI5_LOOP_W;
  localparam int AXI5_STRB_W   = AXI5_DATA_W / 8;
  localparam int AXI5_SIZE_MAX = $clog2(AXI5_STRB_W);
  localparam int AXI5_POISON_W = (AXI5_DATA_W + 63) / 64;
  localparam int AXI5_CHUNK_B  = (AXI5_STRB_W < 8) ? AXI5_STRB_W : 8;      // bytes covered by one poison bit on this bus

  typedef virtual vip_axi5_if #(AXI5_ADDR_W, AXI5_DATA_W, AXI5_ID_W, AXI5_USER_W, AXI5_LOOP_W) axi5_vif_t;

  typedef enum bit [1:0] { AXI5_FIXED = 0, AXI5_INCR = 1, AXI5_WRAP = 2 } axi5_burst_e;
  typedef enum bit [1:0] { AXI5_OKAY = 0, AXI5_EXOKAY = 1, AXI5_SLVERR = 2, AXI5_DECERR = 3 } axi5_resp_e;
  typedef enum bit [2:0] { AXI5_ATOP_NONE, AXI5_ATOP_STORE, AXI5_ATOP_LOAD, AXI5_ATOP_SWAP, AXI5_ATOP_COMPARE,
                           AXI5_ATOP_RESERVED } axi5_atop_kind_e;
  // AtomicStore / AtomicLoad operation (AWATOP[2:0])
  typedef enum bit [2:0] { AXI5_AOP_ADD = 0, AXI5_AOP_CLR = 1, AXI5_AOP_EOR = 2, AXI5_AOP_SET = 3,
                           AXI5_AOP_SMAX = 4, AXI5_AOP_SMIN = 5, AXI5_AOP_UMAX = 6, AXI5_AOP_UMIN = 7 } axi5_aop_e;
  typedef enum { AXI5_INJ_NONE, AXI5_INJ_WLAST_EARLY, AXI5_INJ_WLAST_LATE, AXI5_INJ_AW_DROP_VALID, AXI5_INJ_AW_CHANGE,
                 AXI5_INJ_CROSS_4KB, AXI5_INJ_WSTRB_OUTSIDE, AXI5_INJ_RLAST_EARLY, AXI5_INJ_EXOKAY_NORMAL,
                 // AXI5 extensions
                 AXI5_INJ_ATOP_LOCK,      // atomic with AWLOCK set                       -> AXI_A_ATOP
                 AXI5_INJ_ATOP_ALIGN,     // atomic address not aligned                   -> AXI_A_ATOP
                 AXI5_INJ_IDUNQ,          // AWIDUNQ with a same-ID write outstanding     -> AXI_A_IDUNQ
                 AXI5_INJ_WDATACHK,       // wrong WDATACHK parity                        -> AXI_A_DATACHK
                 AXI5_INJ_RDATACHK,       // wrong RDATACHK parity (subordinate)          -> AXI_A_DATACHK
                 AXI5_INJ_TRACE,          // BTRACE / RTRACE not echoed (subordinate)     -> AXI_A_TRACE
                 AXI5_INJ_LOOP,           // BLOOP / RLOOP not echoed (subordinate)       -> AXI_A_LOOP
                 AXI5_INJ_RIDUNQ,         // xIDUNQ of the response wrong (subordinate)   -> AXI_A_IDUNQ
                 AXI5_INJ_WAKEUP,         // VALID without AWAKEUP                        -> AXI_A_WAKEUP
                 AXI5_INJ_ATOP_RBEATS     // atomic read data with one beat too few       -> AXI_A_RLAST
               } axi5_inject_e;

  // address of beat i of a burst (IHI0022 A3.4.1): FIXED keeps the address, INCR aligns after the first beat, WRAP wraps at beats*size
  function automatic bit [AXI5_ADDR_W-1:0] axi5_burst_addr(bit [AXI5_ADDR_W-1:0] a, bit [2:0] sz, axi5_burst_e bt, int unsigned beats, int unsigned i);
    bit [AXI5_ADDR_W-1:0] algn  = a & ~((AXI5_ADDR_W'(1) << sz) - 1);
    bit [AXI5_ADDR_W-1:0] wsz   = AXI5_ADDR_W'(beats) << sz;
    bit [AXI5_ADDR_W-1:0] lower = a & ~(wsz - 1);
    if (i == 0) return a;
    case (bt)
      AXI5_FIXED: return a;
      AXI5_WRAP:  return lower + (((algn - lower) + (AXI5_ADDR_W'(i) << sz)) & (wsz - 1));
      default:    return algn + (AXI5_ADDR_W'(i) << sz);
    endcase
  endfunction

  // byte lanes of the data bus used by beat i
  function automatic bit [AXI5_STRB_W-1:0] axi5_valid_lanes(bit [AXI5_ADDR_W-1:0] a, bit [2:0] sz, axi5_burst_e bt, int unsigned beats, int unsigned i);
    bit [AXI5_ADDR_W-1:0] ba = axi5_burst_addr(a, sz, bt, beats, i);
    int unsigned lo = int'(ba % AXI5_STRB_W);
    int unsigned n  = 1 << sz;
    int unsigned hi = ((lo / n) + 1) * n;
    bit [AXI5_STRB_W-1:0] m = '0;
    for (int l = 0; l < AXI5_STRB_W; l++) if (l >= lo && l < hi) m[l] = 1'b1;
    return m;
  endfunction

  // ---------------------------------------------------------------- atomic transactions (IHI0022 Issue H, atomic accesses)
  function automatic axi5_atop_kind_e axi5_atop_kind(bit [5:0] atop);
    case (atop[5:4])
      2'b00: return (atop == 6'b0) ? AXI5_ATOP_NONE : AXI5_ATOP_RESERVED;
      2'b01: return AXI5_ATOP_STORE;
      2'b10: return AXI5_ATOP_LOAD;
      default: return (atop == 6'b110000) ? AXI5_ATOP_SWAP : (atop == 6'b110001) ? AXI5_ATOP_COMPARE : AXI5_ATOP_RESERVED;
    endcase
  endfunction

  function automatic bit axi5_atop_has_rdata(bit [5:0] atop);
    return axi5_atop_kind(atop) inside {AXI5_ATOP_LOAD, AXI5_ATOP_SWAP, AXI5_ATOP_COMPARE};
  endfunction

  // write data bytes of the whole atomic transaction (outbound: compare + swap for AtomicCompare)
  function automatic int unsigned axi5_atop_total(bit [2:0] sz, bit [7:0] len);
    return (int'(len) + 1) << sz;
  endfunction

  // the window [base, base + total) the write data covers; AWADDR is the operand address (for AtomicCompare the compare value)
  function automatic bit [AXI5_ADDR_W-1:0] axi5_atop_base(bit [AXI5_ADDR_W-1:0] a, int unsigned total);
    return a & ~AXI5_ADDR_W'(total - 1);
  endfunction

  // lanes of beat i of an atomic write: a single transfer carries the whole window (also an AtomicCompare WRAP with
  // AWLEN = 0), longer transactions use full-width beats with the burst addressing
  function automatic bit [AXI5_STRB_W-1:0] axi5_atop_lanes(bit [AXI5_ADDR_W-1:0] a, bit [2:0] sz, axi5_burst_e bt, int unsigned beats,
                                                          int unsigned i);
    if (beats == 1) begin
      int unsigned tot = 1 << sz;
      int unsigned lo  = int'(axi5_atop_base(a, tot) % AXI5_STRB_W);
      bit [AXI5_STRB_W-1:0] m = '0;
      for (int l = 0; l < AXI5_STRB_W; l++) if (l >= lo && l < lo + tot) m[l] = 1'b1;
      return m;
    end
    return axi5_valid_lanes(a, sz, bt, beats, i);
  endfunction

  // read data of an atomic: operand bytes (half the write data for AtomicCompare), INCR from AWADDR with
  // rsize = min(AWSIZE, log2(operand))
  function automatic int unsigned axi5_atop_rbytes(bit [5:0] atop, bit [2:0] sz, bit [7:0] len);
    int unsigned t = axi5_atop_total(sz, len);
    return (axi5_atop_kind(atop) == AXI5_ATOP_COMPARE) ? t / 2 : t;
  endfunction

  function automatic bit [2:0] axi5_atop_rsize(bit [5:0] atop, bit [2:0] sz, bit [7:0] len);
    int unsigned rb = axi5_atop_rbytes(atop, sz, len);
    return (rb >= (1 << sz)) ? sz : 3'($clog2(rb));
  endfunction

  function automatic int unsigned axi5_atop_rbeats(bit [5:0] atop, bit [2:0] sz, bit [7:0] len);
    int unsigned rb = axi5_atop_rbytes(atop, sz, len);
    return (rb + (1 << sz) - 1) >> sz;
  endfunction

  // n-byte operand <-> value (endianness from AWATOP[3] for AtomicStore / AtomicLoad; Swap / Compare move bytes only)
  function automatic bit [127:0] axi5_bytes2val(byte unsigned b[$], bit big);
    bit [127:0] v = '0;
    foreach (b[i]) v[8 * (big ? (b.size() - 1 - i) : i) +: 8] = b[i];
    return v;
  endfunction

  function automatic void axi5_val2bytes(bit [127:0] v, int unsigned n, bit big, ref byte unsigned b[$]);
    b.delete();
    for (int i = 0; i < n; i++) b.push_back(v[8 * (big ? (n - 1 - i) : i) +: 8]);
  endfunction

  // new memory value of the operand bytes. orig / opnd / swp: n bytes in address order (swp: AtomicCompare only)
  function automatic void axi5_atomic_result(bit [5:0] atop, byte unsigned orig[$], byte unsigned opnd[$], byte unsigned swp[$],
                                             ref byte unsigned res[$]);
    axi5_atop_kind_e k = axi5_atop_kind(atop);
    int unsigned n = orig.size();
    bit big = atop[3];
    bit [127:0] o, d, r, msk, sb;
    bit         lt_s, lt_u;
    res = orig;
    case (k)
      AXI5_ATOP_SWAP:    res = opnd;
      AXI5_ATOP_COMPARE: if (orig == opnd) res = swp;
      AXI5_ATOP_STORE, AXI5_ATOP_LOAD: begin
        o = axi5_bytes2val(orig, big); d = axi5_bytes2val(opnd, big);
        msk = (n >= 16) ? '1 : ((128'd1 << (8 * n)) - 1);
        sb  = 128'd1 << (8 * n - 1);
        lt_u = o < d;                                         // unsigned, both zero extended
        lt_s = ((o ^ sb) & msk) < ((d ^ sb) & msk);           // signed: flip the sign bits
        case (axi5_aop_e'(atop[2:0]))
          AXI5_AOP_ADD:  r = (o + d) & msk;
          AXI5_AOP_CLR:  r = o & ~d;
          AXI5_AOP_EOR:  r = o ^ d;
          AXI5_AOP_SET:  r = o | d;
          AXI5_AOP_SMAX: r = lt_s ? d : o;
          AXI5_AOP_SMIN: r = lt_s ? o : d;
          AXI5_AOP_UMAX: r = lt_u ? d : o;
          default:       r = lt_u ? o : d;                    // UMIN
        endcase
        axi5_val2bytes(r & msk, n, big, res);
      end
      default: ;
    endcase
  endfunction

  // odd parity per byte (Check_Type Odd_Parity_Byte_All)
  function automatic bit [AXI5_STRB_W-1:0] axi5_datachk(bit [AXI5_DATA_W-1:0] d);
    bit [AXI5_STRB_W-1:0] p;
    for (int i = 0; i < AXI5_STRB_W; i++) p[i] = ~(^d[8 * i +: 8]);
    return p;
  endfunction

  `include "axi5_cfg.svh"
  `include "axi5_item.svh"
  `include "axi5_sequencer.svh"
  `include "axi5_master_driver.svh"
  `include "axi5_slave_driver.svh"
  `include "axi5_monitor.svh"
  `include "axi5_coverage.svh"
  `include "axi5_scoreboard.svh"
  `include "axi5_agent.svh"
  `include "axi5_env.svh"
  `include "axi5_seq_lib.svh"
endpackage : axi5_pkg

`endif
