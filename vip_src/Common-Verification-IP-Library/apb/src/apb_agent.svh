// -----------------------------------------------------------------------------
// apb_agent - role selected by cfg.role (key "cfg" in the uvm_config_db, see apb_agent_cfg)
//   VIP_MASTER   sequencer + master driver + monitor (+ coverage)
//   VIP_SLAVE    slave driver (memory) + monitor (+ coverage)
//   VIP_MONITOR  monitor (+ coverage)  - passive, drives nothing
// -----------------------------------------------------------------------------
class apb_agent extends uvm_agent;
  `uvm_component_utils(apb_agent)

  apb_agent_cfg     cfg;
  apb_sequencer     sqr;
  apb_master_driver mdrv;
  apb_slave_driver  sdrv;
  apb_monitor       mon;
  apb_coverage      cov;
  uvm_analysis_port #(apb_item) ap;          // = monitor.ap

  function new(string name, uvm_component parent);
    super.new(name, parent);
  endfunction

  function void build_phase(uvm_phase phase);
    super.build_phase(phase);
    if (!uvm_config_db #(apb_agent_cfg)::get(this, "", "cfg", cfg))
      `vip_fatal("APB_CFG", $sformatf("no apb_agent_cfg for %s (uvm_config_db key \"cfg\")", get_full_name()))
    if (cfg.vif == null) `vip_fatal("APB_CFG", "apb_agent_cfg.vif is null")
    is_active = (cfg.role == VIP_MONITOR) ? UVM_PASSIVE : UVM_ACTIVE;
    cfg.post_randomize_mem();
    mon = apb_monitor::type_id::create("mon", this);
    if (cfg.coverage_en) cov = apb_coverage::type_id::create("cov", this);
    case (cfg.role)
      VIP_MASTER: begin
        sqr  = apb_sequencer::type_id::create("sqr", this);
        mdrv = apb_master_driver::type_id::create("mdrv", this);
      end
      VIP_SLAVE:  sdrv = apb_slave_driver::type_id::create("sdrv", this);
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
  endfunction
endclass : apb_agent
