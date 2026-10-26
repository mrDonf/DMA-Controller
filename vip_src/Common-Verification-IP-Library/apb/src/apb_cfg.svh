// apb_agent_cfg - configuration of one APB agent (set with uvm_config_db, key "cfg")
class apb_agent_cfg extends uvm_object;
  `uvm_object_utils(apb_agent_cfg)

  apb_vif_t   vif;
  vip_role_e  role            = VIP_MASTER;
  bit         coverage_en     = 1'b1;
  bit         checks_en       = 1'b1;       // interface assertions + monitor checks
  int unsigned timeout_cycles = 2048;       // monitor / master: PREADY must arrive within this many cycles

  // ---- master knobs
  int unsigned idle_min       = 0;          // idle cycles between transfers are taken from the item (idle) ...
  int unsigned idle_max       = 3;          // ... randomised in [idle_min, idle_max] by the sequences
  apb_inject_e inject         = APB_INJ_NONE;
  int unsigned inject_pct     = 100;        // probability (%) that a transfer is corrupted when inject != NONE

  // ---- slave knobs
  vip_sparse_mem mem;                       // backing store (created on demand)
  vip_mem_init_e mem_init     = MEM_INIT_ADDR_HASH;
  int unsigned wait_min       = 0;          // wait states inserted by the completer
  int unsigned wait_max       = 0;
  int unsigned err_pct        = 0;          // % of transfers answered with PSLVERR
  bit          default_pready = 1'b0;       // value of PREADY outside an access phase
  bit          unmapped_error = 1'b0;       // out-of-range accesses answer PSLVERR
  bit [APB_ADDR_W-1:0] base_addr  = '0;     // mapped window [base_addr, base_addr + size) ; size 0 = everything
  longint unsigned     size       = 0;
  bit [APB_ADDR_W-1:0] err_lo     = '1;     // addresses in [err_lo, err_hi] always answer PSLVERR
  bit [APB_ADDR_W-1:0] err_hi     = '0;

  function new(string name = "apb_agent_cfg");
    super.new(name);
  endfunction

  function void post_randomize_mem();
    if (mem == null) mem = new();
    mem.init_mode = mem_init;
  endfunction

  function bit is_mapped(bit [APB_ADDR_W-1:0] a);
    if (size == 0) return 1'b1;
    return (a >= base_addr) && (longint'(a) < longint'(base_addr) + longint'(size));
  endfunction

  function bit in_err_window(bit [APB_ADDR_W-1:0] a);
    return (err_lo <= err_hi) && (a >= err_lo) && (a <= err_hi);
  endfunction

  // can the completer answer this address with an error at all (used by the scoreboard)?
  function bit error_possible(bit [APB_ADDR_W-1:0] a);
    return (err_pct != 0) || in_err_window(a) || (unmapped_error && !is_mapped(a));
  endfunction
endclass : apb_agent_cfg
