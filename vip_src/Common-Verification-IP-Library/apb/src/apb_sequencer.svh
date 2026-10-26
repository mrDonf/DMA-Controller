class apb_sequencer extends uvm_sequencer #(apb_item);
  `uvm_component_utils(apb_sequencer)
  apb_agent_cfg cfg;
  function new(string name, uvm_component parent);
    super.new(name, parent);
  endfunction
endclass : apb_sequencer
