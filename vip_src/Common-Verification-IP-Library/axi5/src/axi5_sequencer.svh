class axi5_sequencer extends uvm_sequencer #(axi5_item);
  `uvm_component_utils(axi5_sequencer)
  axi5_agent_cfg cfg;
  function new(string name, uvm_component parent);
    super.new(name, parent);
  endfunction
endclass : axi5_sequencer
