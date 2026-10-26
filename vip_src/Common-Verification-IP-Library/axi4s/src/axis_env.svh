// axis_env_cfg / axis_env - transmitter agent (input of the DUT), receiver agent (output of the DUT) and the packet scoreboard
class axis_env_cfg extends uvm_object;
  `uvm_object_utils(axis_env_cfg)
  axis_agent_cfg src_cfg;                   // interface in front of the DUT (role VIP_MASTER, or VIP_MONITOR when another source drives)
  axis_agent_cfg snk_cfg;                   // interface behind the DUT   (role VIP_SLAVE)
  bit            has_scoreboard = 1'b1;
  bit            bytes_only     = 1'b0;
  bit            compare_user   = 1'b1;
  function new(string name = "axis_env_cfg");
    super.new(name);
  endfunction
endclass : axis_env_cfg

class axis_env extends uvm_env;
  `uvm_component_utils(axis_env)

  axis_env_cfg    cfg;
  axis_agent      src, snk;
  axis_scoreboard sb;

  function new(string name, uvm_component parent);
    super.new(name, parent);
  endfunction

  function void build_phase(uvm_phase phase);
    super.build_phase(phase);
    if (!uvm_config_db #(axis_env_cfg)::get(this, "", "cfg", cfg)) `vip_fatal("AXIS_CFG", "no axis_env_cfg")
    uvm_config_db #(axis_agent_cfg)::set(this, "src*", "cfg", cfg.src_cfg);
    uvm_config_db #(axis_agent_cfg)::set(this, "snk*", "cfg", cfg.snk_cfg);
    src = axis_agent::type_id::create("src", this);
    snk = axis_agent::type_id::create("snk", this);
    if (cfg.has_scoreboard) sb = axis_scoreboard::type_id::create("sb", this);
  endfunction

  function void connect_phase(uvm_phase phase);
    super.connect_phase(phase);
    if (sb != null) begin
      sb.bytes_only = cfg.bytes_only; sb.compare_user = cfg.compare_user;
      src.ap.connect(sb.in_imp);
      snk.ap.connect(sb.out_imp);
      src.mon.ap_abort.connect(sb.abort_imp);
      snk.mon.ap_abort.connect(sb.abort_imp);
    end
  endfunction
endclass : axis_env
