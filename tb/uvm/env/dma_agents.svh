//-----------------------------------------------------------------------------
// dma_agents.svh - side band agents of the DMA test bench
//   dma_trig_agent   : trigger input peripherals (4-phase req/ack with types)
//                      and trigger output responders, optionally clocked by
//                      an asynchronous peripheral clock (CDC tests)
//   dma_lpi_driver   : Q-Channel / P-Channel controller model
//   dma_so_sub       : stream-out packet forwarder to the scoreboard
//   dma_stream_engine: external "data processing unit" model closing the
//                      stream loop (str_out -> transform -> str_in)
//-----------------------------------------------------------------------------
class dma_trig_agent extends uvm_component;
  `uvm_component_utils(dma_trig_agent)

  dma_ctrl_vif_t vif;
  bit            async_mode;            // drive / sample with the peripheral clock
  bit            out_auto_ack [int];    // trigger outputs answered automatically
  int unsigned   out_ack_dly_max = 6;
  int unsigned   n_out_hs [int];        // completed output handshakes per port
  int unsigned   n_in_hs  [int];
  bit [1:0]      last_acktype [int];

  function new(string name, uvm_component parent);
    super.new(name, parent);
  endfunction

  task tick();
    if (async_mode) @(posedge vif.per_clk);
    else            @(posedge vif.clk);
  endtask

  task run_phase(uvm_phase phase);
    vif.trig_in_req      <= '0;
    vif.trig_in_req_type <= '0;
    vif.trig_out_ack     <= '0;
    for (int q = 0; q < TB_NTO; q++) begin
      automatic int qq = q;
      fork out_responder(qq); join_none
    end
  endtask

  // trigger output responder
  task out_responder(int q);
    forever begin
      tick();
      if (vif.trig_out_req[q] === 1'b1 && out_auto_ack.exists(q) && out_auto_ack[q]) begin
        repeat ($urandom_range(0, out_ack_dly_max)) tick();
        vif.trig_out_ack[q] <= 1'b1;
        do tick(); while (vif.trig_out_req[q] !== 1'b0);
        repeat ($urandom_range(0, 2)) tick();
        vif.trig_out_ack[q] <= 1'b0;
        if (!n_out_hs.exists(q)) n_out_hs[q] = 0;
        n_out_hs[q]++;
      end
    end
  endtask

  // manual output acknowledge of a pending request
  task out_ack(int q, int timeout = 100000);
    int t = 0;
    while (vif.trig_out_req[q] !== 1'b1 && t < timeout) begin tick(); t++; end
    if (t >= timeout) begin `uvm_error("TRIG", $sformatf("trig_out_%0d req not seen", q)) return; end
    vif.trig_out_ack[q] <= 1'b1;
    do tick(); while (vif.trig_out_req[q] !== 1'b0);
    vif.trig_out_ack[q] <= 1'b0;
    if (!n_out_hs.exists(q)) n_out_hs[q] = 0;
    n_out_hs[q]++;
  endtask

  // one complete input handshake: req with type -> ack (acktype) -> req low -> ack low
  task in_req(int p, bit [1:0] rtype, output bit [1:0] atype, input int timeout = 200000);
    int t = 0;
    vif.trig_in_req_type[p] <= rtype;
    tick();
    vif.trig_in_req[p] <= 1'b1;
    do begin tick(); t++; end while (vif.trig_in_ack[p] !== 1'b1 && t < timeout);
    if (t >= timeout) begin
      `uvm_error("TRIG", $sformatf("trig_in_%0d: no ack within %0d cycles", p, timeout))
      atype = 2'bxx;
      return;
    end
    atype = vif.trig_in_ack_type[p];
    last_acktype[p] = atype;
    repeat ($urandom_range(0, 3)) tick();
    vif.trig_in_req[p] <= 1'b0;
    t = 0;
    do begin tick(); t++; end while (vif.trig_in_ack[p] !== 1'b0 && t < timeout);
    if (!n_in_hs.exists(p)) n_in_hs[p] = 0;
    n_in_hs[p]++;
  endtask

  // raise a request and leave it pending (SW deny / pending request tests)
  task in_raise(int p, bit [1:0] rtype);
    vif.trig_in_req_type[p] <= rtype;
    tick();
    vif.trig_in_req[p] <= 1'b1;
  endtask

  task in_drop_after_ack(int p, output bit [1:0] atype, input int timeout = 200000);
    int t = 0;
    while (vif.trig_in_ack[p] !== 1'b1 && t < timeout) begin tick(); t++; end
    atype = vif.trig_in_ack_type[p];
    vif.trig_in_req[p] <= 1'b0;
    t = 0;
    while (vif.trig_in_ack[p] !== 1'b0 && t < timeout) begin tick(); t++; end
  endtask

  // peripheral driving a flow controlled transfer:
  //   DMA driven     : BLOCK requests until LAST OKAY
  //   peripheral driven : nblk BLOCK requests, the last one LAST BLOCK
  task fc_peripheral(int p, bit per_driven, int nblk, int gap_max = 20, bit use_single = 0);
    bit [1:0] at;
    int i = 0;
    forever begin
      bit last = per_driven && (i == nblk - 1);
      bit [1:0] rt = use_single ? (last ? RQ_LSINGLE : RQ_SINGLE) : (last ? RQ_LBLOCK : RQ_BLOCK);
      repeat ($urandom_range(0, gap_max)) tick();
      in_req(p, rt, at);
      i++;
      if (at === AK_LOKAY) break;
      if (per_driven && last) begin
        `uvm_error("TRIG", $sformatf("trig_in_%0d: LAST request not answered with LAST OKAY (%0b)", p, at))
        break;
      end
      if (i > 100000) break;
    end
  endtask
endclass : dma_trig_agent

// -----------------------------------------------------------------------------
class dma_lpi_driver extends uvm_component;
  `uvm_component_utils(dma_lpi_driver)
  dma_ctrl_vif_t vif;

  function new(string name, uvm_component parent);
    super.new(name, parent);
  endfunction

  task run_phase(uvm_phase phase);
    vif.clk_qreqn <= 1'b1;
    vif.preq      <= 1'b0;
    vif.pstate    <= 4'd8;      // ON
  endtask

  // clock quiescence request; returns 1 if accepted (then exits again)
  task q_cycle(output bit accepted, input int hold = 20);
    int t = 0;
    @(posedge vif.clk);
    vif.clk_qreqn <= 1'b0;
    do begin @(posedge vif.clk); t++; end
    while (vif.clk_qacceptn !== 1'b0 && vif.clk_qdeny !== 1'b1 && t < 1000);
    accepted = (vif.clk_qacceptn === 1'b0);
    if (accepted) repeat (hold) @(posedge vif.clk);
    vif.clk_qreqn <= 1'b1;
    t = 0;
    do begin @(posedge vif.clk); t++; end
    while ((vif.clk_qacceptn !== 1'b1 || vif.clk_qdeny !== 1'b0) && t < 1000);
    if (t >= 1000) `uvm_error("LPI", "Q-Channel did not return to RUN")
  endtask

  // power state request; returns 1 if accepted
  task p_request(bit [3:0] st, output bit accepted);
    int t = 0;
    @(posedge vif.clk);
    vif.pstate <= st;
    @(posedge vif.clk);
    vif.preq <= 1'b1;
    do begin @(posedge vif.clk); t++; end
    while (vif.paccept !== 1'b1 && vif.pdeny !== 1'b1 && t < 100000);
    accepted = (vif.paccept === 1'b1);
    if (t >= 100000) `uvm_error("LPI", "P-Channel request not answered")
    vif.preq <= 1'b0;
    t = 0;
    do begin @(posedge vif.clk); t++; end
    while ((vif.paccept !== 1'b0 || vif.pdeny !== 1'b0) && t < 1000);
  endtask
endclass : dma_lpi_driver

// -----------------------------------------------------------------------------
class dma_so_sub extends uvm_subscriber #(axis_item);
  `uvm_component_utils(dma_so_sub)
  int ch;
  dma_scoreboard sb;
  uvm_analysis_port #(axis_item) fwd;
  function new(string name, uvm_component parent);
    super.new(name, parent);
    fwd = new("fwd", this);
  endfunction
  function void write(axis_item t);
    sb.stream_out(ch, t);
    fwd.write(t);
  endfunction
endclass : dma_so_sub

// -----------------------------------------------------------------------------
// stream engine: when enabled for a channel, every stream-out packet is
// transformed and sent back on stream-in (in & out mode)
class dma_stream_engine extends uvm_subscriber #(axis_item);
  `uvm_component_utils(dma_stream_engine)
  int            ch;
  bit            enable;
  bit [7:0]      xor_key = 8'h5A;
  int            shrink_elems;         // drop this many trailing elements (compression model)
  int            esz = 1;
  axis_sequencer sqr;
  int unsigned   n_pkts;

  function new(string name, uvm_component parent);
    super.new(name, parent);
  endfunction

  static function void xform(byte unsigned in_q[$], bit [7:0] key, int shrink_bytes, ref byte unsigned out_q[$]);
    out_q.delete();
    for (int i = 0; i < int'(in_q.size()) - shrink_bytes; i++) out_q.push_back(in_q[i] ^ key);
  endfunction

  function void write(axis_item t);
    byte unsigned q[$], o[$];
    if (!enable) return;
    t.bytes(q);
    xform(q, xor_key, shrink_elems * esz, o);
    n_pkts++;
    fork
      begin
        dma_axis_send_seq s = new("eng_send");
        s.payload = o;
        s.start(sqr);
      end
    join_none
  endfunction
endclass : dma_stream_engine
