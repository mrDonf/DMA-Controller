// -----------------------------------------------------------------------------
// axis_agent - role selected by cfg.role (uvm_config_db key "cfg")
//   VIP_MASTER   sequencer + transmitter + monitor (+ coverage)
//   VIP_SLAVE    receiver (TREADY generator) + monitor (+ coverage)
//   VIP_MONITOR  monitor (+ coverage), drives nothing
// -----------------------------------------------------------------------------
class axis_agent extends uvm_agent;
  `uvm_component_utils(axis_agent)

  axis_agent_cfg     cfg;
  axis_sequencer     sqr;
  axis_master_driver mdrv;
  axis_slave_driver  sdrv;
  axis_monitor       mon;
  axis_coverage      cov;
  uvm_analysis_port #(axis_item) ap;

  function new(string name, uvm_component parent);
    super.new(name, parent);
  endfunction

  function void build_phase(uvm_phase phase);
    super.build_phase(phase);
    if (!uvm_config_db #(axis_agent_cfg)::get(this, "", "cfg", cfg))
      `vip_fatal("AXIS_CFG", $sformatf("no axis_agent_cfg for %s (uvm_config_db key \"cfg\")", get_full_name()))
    if (cfg.vif == null) `vip_fatal("AXIS_CFG", "axis_agent_cfg.vif is null")
    is_active = (cfg.role == VIP_MONITOR) ? UVM_PASSIVE : UVM_ACTIVE;
    mon = axis_monitor::type_id::create("mon", this);
    if (cfg.coverage_en) cov = axis_coverage::type_id::create("cov", this);
    case (cfg.role)
      VIP_MASTER: begin
        sqr  = axis_sequencer::type_id::create("sqr", this);
        mdrv = axis_master_driver::type_id::create("mdrv", this);
      end
      VIP_SLAVE: sdrv = axis_slave_driver::type_id::create("sdrv", this);
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
    cfg.vif.check_keep_mid = cfg.check_keep_mid;
    cfg.vif.max_packet_beats = cfg.max_packet_beats;
  endfunction
endclass : axis_agent
