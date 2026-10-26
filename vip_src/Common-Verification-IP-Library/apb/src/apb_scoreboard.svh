// -----------------------------------------------------------------------------
// apb_scoreboard - reference-memory scoreboard for a memory-like completer
//   * every OKAY write updates the reference memory (byte strobes honoured)
//   * every OKAY read is compared with the reference memory
//   * PSLVERR is only accepted where the configuration allows it (err_pct, error window, unmapped region)
//   * transfers answered with PSLVERR do not change the reference model
//   The reference memory uses the same initial-value rule as the slave model (cfg.mem_init).
// -----------------------------------------------------------------------------
class apb_scoreboard extends uvm_scoreboard;
  `uvm_component_utils(apb_scoreboard)

  `uvm_analysis_imp_decl(_abort)
  uvm_analysis_imp #(apb_item, apb_scoreboard) imp;
  uvm_analysis_imp_abort #(apb_item, apb_scoreboard) imp_abort;   // transfers cut by a reset
  protected bit unknown [bit [APB_ADDR_W-1:0]];                   // words whose content is undefined after an aborted write
  apb_agent_cfg   cfg;                 // configuration of the completer (windows, error rules)
  vip_sparse_mem  ref_mem;
  int unsigned    n_checked, n_mismatch, n_wr, n_err_seen, n_skipped;

  function new(string name, uvm_component parent);
    super.new(name, parent);
  endfunction

  function void build_phase(uvm_phase phase);
    super.build_phase(phase);
    imp = new("imp", this);
    imp_abort = new("imp_abort", this);
    ref_mem = new();
  endfunction

  function void start_of_simulation_phase(uvm_phase phase);
    if (cfg != null) ref_mem.init_mode = cfg.mem_init;
  endfunction

  function void write_abort(apb_item t);
    if (t.write) unknown[t.addr & ~APB_ADDR_W'(APB_STRB_W - 1)] = 1'b1;
  endfunction

  function void write(apb_item t);
    bit [APB_ADDR_W-1:0] a_al = t.addr & ~APB_ADDR_W'(APB_STRB_W - 1);
    bit mapped = (cfg == null) ? 1'b1 : cfg.is_mapped(t.addr);
    if (t.slverr) begin
      n_err_seen++;
      if (cfg != null && !cfg.error_possible(t.addr))
        `vip_error("APB_SB_ERR", $sformatf("unexpected PSLVERR: %s", t.convert2string()))
      return;
    end
    if (cfg != null && cfg.unmapped_error && !mapped)
      `vip_error("APB_SB_ERR", $sformatf("access to an unmapped address answered OKAY: %s", t.convert2string()))
    if (t.write) begin
      ref_mem.write_le(longint'(a_al), t.data, APB_STRB_W, t.strb);
      if (t.strb == {APB_STRB_W{1'b1}}) unknown.delete(a_al);       // a full-word write defines the word again
      n_wr++;
    end else begin
      bit [APB_DATA_W-1:0] expd = ref_mem.read_le(longint'(a_al), APB_STRB_W);
      n_checked++;
      if (unknown.exists(a_al)) n_skipped++;
      else if (mapped && expd !== t.data) begin
        n_mismatch++;
        `vip_error("APB_SB_MISMATCH", $sformatf("read 0x%0h: got 0x%0h expected 0x%0h", t.addr, t.data, expd))
      end
    end
  endfunction

  function void report_phase(uvm_phase phase);
    `vip_info("APB_SB", $sformatf("writes=%0d reads checked=%0d mismatches=%0d slverr seen=%0d", n_wr, n_checked, n_mismatch, n_err_seen), UVM_LOW)
  endfunction
endclass : apb_scoreboard
