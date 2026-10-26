// axi5_agent_cfg - configuration of one AXI5 agent (uvm_config_db key "cfg")
//   AXI5 interface properties: datachk_en (Check_Type: WDATACHK / RDATACHK driven and checked), wakeup_en (AWAKEUP driven
//   by the manager and checked), atomics_en (subordinate executes atomics; otherwise it answers SLVERR with the right
//   number of read data beats), poison_en (subordinate stores and returns poison)
class axi5_agent_cfg extends uvm_object;
  `uvm_object_utils(axi5_agent_cfg)

  axi5_vif_t  vif;
  vip_role_e  role            = VIP_MASTER;
  bit         coverage_en     = 1'b1;
  bit         checks_en       = 1'b1;
  int unsigned timeout_cycles = 4096;       // any handshake must complete within this many cycles
  bit         datachk_en      = 1'b1;
  bit         wakeup_en       = 1'b1;
  bit         atomics_en      = 1'b1;
  bit         poison_en       = 1'b1;

  // ---- manager knobs
  int unsigned max_wr_outstanding = 8;      // write bursts issued but not yet answered
  int unsigned max_rd_outstanding = 8;
  int unsigned bready_pct = 100;            // probability (%) per cycle that BREADY is high
  int unsigned rready_pct = 100;
  axi5_inject_e inject    = AXI5_INJ_NONE;
  int unsigned inject_pct = 100;
  int unsigned wakeup_idle_cycles = 4;      // AWAKEUP stays high this many cycles after the last transaction completed

  // ---- subordinate knobs
  vip_sparse_mem mem;
  vip_mem_init_e mem_init   = MEM_INIT_ADDR_HASH;
  int unsigned awready_pct  = 100;          // probability (%) per cycle of AWREADY / WREADY / ARREADY
  int unsigned wready_pct   = 100;
  int unsigned arready_pct  = 100;
  int unsigned b_delay_min  = 0;            // cycles between "write complete" and BVALID
  int unsigned b_delay_max  = 0;
  int unsigned r_delay_min  = 0;            // cycles before the first R beat and between R beats
  int unsigned r_delay_max  = 0;
  bit          r_gap_sep    = 1'b0;         // 1: gaps between R beats from r_gap_min/max (r_delay = first beat latency only)
  int unsigned r_gap_min    = 0;
  int unsigned r_gap_max    = 0;
  bit          ooo          = 1'b0;         // out-of-order responses between different IDs
  bit          interleave   = 1'b0;         // interleave R beats of different IDs
  bit          exclusive_en = 1'b1;         // exclusive monitor (EXOKAY)
  int unsigned err_pct      = 0;            // % of bursts answered with SLVERR
  bit [AXI5_ADDR_W-1:0] base_addr = '0;     // mapped window (size 0 = everything)
  longint unsigned      size      = 0;
  bit                   unmapped_decerr = 1'b0;   // out-of-window accesses answer DECERR
  bit [AXI5_ADDR_W-1:0] err_lo = '1;        // [err_lo, err_hi] answers SLVERR
  bit [AXI5_ADDR_W-1:0] err_hi = '0;

  function new(string name = "axi5_agent_cfg");
    super.new(name);
  endfunction

  function void post_randomize_mem();
    if (mem == null) mem = new();
    mem.init_mode = mem_init;
  endfunction

  function bit is_mapped(bit [AXI5_ADDR_W-1:0] a);
    if (size == 0) return 1'b1;
    return (a >= base_addr) && (longint'(a) < longint'(base_addr) + longint'(size));
  endfunction

  function bit in_err_window(bit [AXI5_ADDR_W-1:0] a);
    return (err_lo <= err_hi) && (a >= err_lo) && (a <= err_hi);
  endfunction

  // can the subordinate answer this address with an error?
  function bit error_possible(bit [AXI5_ADDR_W-1:0] a);
    return (err_pct != 0) || in_err_window(a) || (unmapped_decerr && !is_mapped(a));
  endfunction
endclass : axi5_agent_cfg
