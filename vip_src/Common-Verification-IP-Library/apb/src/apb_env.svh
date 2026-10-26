// apb_env_cfg / apb_env - requester agent, optional completer agent (back-to-back) and the reference scoreboard
class apb_env_cfg extends uvm_object;
  `uvm_object_utils(apb_env_cfg)
  apb_agent_cfg mst_cfg;                     // null = no master agent
  apb_agent_cfg slv_cfg;                     // null = no slave agent (a DUT answers)
  bit           has_scoreboard = 1'b1;       // needs a memory-like completer (slave agent or DUT behaving as memory)
  function new(string name = "apb_env_cfg");
    super.new(name);
  endfunction
endclass : apb_env_cfg

class apb_env extends uvm_env;
  `uvm_component_utils(apb_env)

  apb_env_cfg    cfg;
  apb_agent      mst, slv;
  apb_scoreboard sb;

  function new(string name, uvm_component parent);
    super.new(name, parent);
  endfunction

  function void build_phase(uvm_phase phase);
    super.build_phase(phase);
    if (!uvm_config_db #(apb_env_cfg)::get(this, "", "cfg", cfg)) `vip_fatal("APB_CFG", "no apb_env_cfg")
    if (cfg.mst_cfg != null) begin
      uvm_config_db #(apb_agent_cfg)::set(this, "mst*", "cfg", cfg.mst_cfg);
      mst = apb_agent::type_id::create("mst", this);
    end
    if (cfg.slv_cfg != null) begin
      uvm_config_db #(apb_agent_cfg)::set(this, "slv*", "cfg", cfg.slv_cfg);
      slv = apb_agent::type_id::create("slv", this);
    end
    if (cfg.has_scoreboard) sb = apb_scoreboard::type_id::create("sb", this);
  endfunction

  function void connect_phase(uvm_phase phase);
    super.connect_phase(phase);
    if (sb != null) begin
      sb.cfg = (cfg.slv_cfg != null) ? cfg.slv_cfg : cfg.mst_cfg;
      if (mst != null) begin mst.ap.connect(sb.imp); mst.mon.ap_abort.connect(sb.imp_abort); end
      else if (slv != null) begin slv.ap.connect(sb.imp); slv.mon.ap_abort.connect(sb.imp_abort); end
    end
  endfunction
endclass : apb_env
