// -----------------------------------------------------------------------------
// axi5_agent - role selected by cfg.role (uvm_config_db key "cfg"); cfg.datachk_en / wakeup_en also enable the interface
//              checks AXI_A_DATACHK / AXI_A_WAKEUP
//   VIP_MASTER   sequencer + manager driver + monitor (+ coverage)
//   VIP_SLAVE    subordinate driver (memory) + monitor (+ coverage)
//   VIP_MONITOR  monitor (+ coverage), drives nothing
// -----------------------------------------------------------------------------
class axi5_agent extends uvm_agent;
  `uvm_component_utils(axi5_agent)

  axi5_agent_cfg     cfg;
  axi5_sequencer     sqr;
  axi5_master_driver mdrv;
  axi5_slave_driver  sdrv;
  axi5_monitor       mon;
  axi5_coverage      cov;
  uvm_analysis_port #(axi5_item) ap;

  function new(string name, uvm_component parent);
    super.new(name, parent);
  endfunction

  function void build_phase(uvm_phase phase);
    super.build_phase(phase);
    if (!uvm_config_db #(axi5_agent_cfg)::get(this, "", "cfg", cfg))
      `vip_fatal("AXI5_CFG", $sformatf("no axi5_agent_cfg for %s (uvm_config_db key \"cfg\")", get_full_name()))
    if (cfg.vif == null) `vip_fatal("AXI5_CFG", "axi5_agent_cfg.vif is null")
    if (AXI5_DATA_W > 1024) `vip_fatal("AXI5_CFG", "AXI5_DATA_W above 1024 bits is not supported")
    is_active = (cfg.role == VIP_MONITOR) ? UVM_PASSIVE : UVM_ACTIVE;
    cfg.post_randomize_mem();
    mon = axi5_monitor::type_id::create("mon", this);
    if (cfg.coverage_en) cov = axi5_coverage::type_id::create("cov", this);
    case (cfg.role)
      VIP_MASTER: begin
        sqr  = axi5_sequencer::type_id::create("sqr", this);
        mdrv = axi5_master_driver::type_id::create("mdrv", this);
      end
      VIP_SLAVE: sdrv = axi5_slave_driver::type_id::create("sdrv", this);
      default: ;
    endcase
  endfunction

  function void connect_phase(uvm_phase phase);
    super.connect_phase(phase);
    mon.cfg = cfg; mon.vif = cfg.vif;
    ap = mon.ap;
    if (cov != null) begin cov.cfg = cfg; mon.ap.connect(cov.analysis_export); end
    if (mdrv != null) begin
      mdrv.cfg = cfg; mdrv.vif = cfg.vif; sqr.cfg = cfg;
      mdrv.seq_item_port.connect(sqr.seq_item_export);
    end
    if (sdrv != null) begin sdrv.cfg = cfg; sdrv.vif = cfg.vif; end
  endfunction

  function void start_of_simulation_phase(uvm_phase phase);
    cfg.vif.checks_en = cfg.checks_en;
    cfg.vif.datachk_en = cfg.datachk_en;                // interface properties: every agent on the bus must agree
    cfg.vif.wakeup_check_en = cfg.wakeup_en;
  endfunction
endclass : axi5_agent
