// axi5_env_cfg / axi5_env - manager agent, optional subordinate agent (back-to-back) and the reference scoreboard
class axi5_env_cfg extends uvm_object;
  `uvm_object_utils(axi5_env_cfg)
  axi5_agent_cfg mst_cfg;
  axi5_agent_cfg slv_cfg;
  bit            has_scoreboard = 1'b1;
  function new(string name = "axi5_env_cfg");
    super.new(name);
  endfunction
endclass : axi5_env_cfg

class axi5_env extends uvm_env;
  `uvm_component_utils(axi5_env)

  axi5_env_cfg    cfg;
  axi5_agent      mst, slv;
  axi5_scoreboard sb;

  function new(string name, uvm_component parent);
    super.new(name, parent);
  endfunction

  function void build_phase(uvm_phase phase);
    super.build_phase(phase);
    if (!uvm_config_db #(axi5_env_cfg)::get(this, "", "cfg", cfg)) `vip_fatal("AXI5_CFG", "no axi5_env_cfg")
    if (cfg.mst_cfg != null) begin
      uvm_config_db #(axi5_agent_cfg)::set(this, "mst*", "cfg", cfg.mst_cfg);
      mst = axi5_agent::type_id::create("mst", this);
    end
    if (cfg.slv_cfg != null) begin
      uvm_config_db #(axi5_agent_cfg)::set(this, "slv*", "cfg", cfg.slv_cfg);
      slv = axi5_agent::type_id::create("slv", this);
    end
    if (cfg.has_scoreboard) sb = axi5_scoreboard::type_id::create("sb", this);
  endfunction

  function void connect_phase(uvm_phase phase);
    super.connect_phase(phase);
    if (sb != null) begin
      sb.cfg = (cfg.slv_cfg != null) ? cfg.slv_cfg : cfg.mst_cfg;
      if (mst != null) begin mst.ap.connect(sb.imp); mst.mon.ap_abort.connect(sb.imp_abort); end
      else if (slv != null) begin slv.ap.connect(sb.imp); slv.mon.ap_abort.connect(sb.imp_abort); end
    end
  endfunction
endclass : axi5_env
