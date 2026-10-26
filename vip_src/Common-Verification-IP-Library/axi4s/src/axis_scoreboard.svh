// -----------------------------------------------------------------------------
// axis_scoreboard - packet scoreboard between two observation points (e.g. before and after a DUT)
//   in_imp   packets seen at the input   (expected, queued in order)
//   out_imp  packets seen at the output  (compared with the oldest expected packet)
//   A reset marker (aborted item without beats) flushes the expectation queue.
//   cfg `bytes_only`: compare only the stream of data bytes (width converters / packers change the beat structure);
//   otherwise beats, TKEEP, TSTRB, TUSER, TID and TDEST must match exactly (TUSER compare can be switched off).
// -----------------------------------------------------------------------------
class axis_scoreboard extends uvm_scoreboard;
  `uvm_component_utils(axis_scoreboard)

  `uvm_analysis_imp_decl(_in)
  `uvm_analysis_imp_decl(_out)
  `uvm_analysis_imp_decl(_abort)
  uvm_analysis_imp_in    #(axis_item, axis_scoreboard) in_imp;
  uvm_analysis_imp_out   #(axis_item, axis_scoreboard) out_imp;
  uvm_analysis_imp_abort #(axis_item, axis_scoreboard) abort_imp;

  bit bytes_only    = 1'b0;
  bit compare_user  = 1'b1;
  bit drop_allowed  = 1'b0;      // a DUT that may drop whole packets (not used by the library tests)

  axis_item exp_q[$];
  int unsigned n_in, n_out, n_match, n_mismatch, n_flush;

  function new(string name, uvm_component parent);
    super.new(name, parent);
  endfunction

  function void build_phase(uvm_phase phase);
    super.build_phase(phase);
    in_imp = new("in_imp", this); out_imp = new("out_imp", this); abort_imp = new("abort_imp", this);
  endfunction

  function void write_in(axis_item t);
    n_in++;
    exp_q.push_back(t);
  endfunction

  function void write_abort(axis_item t);
    if (t.data.size() == 0) begin exp_q.delete(); n_flush++; end
  endfunction

  protected function bit same(axis_item e, axis_item a);
    if (bytes_only) begin
      byte unsigned be[$], ba[$];
      e.bytes(be); a.bytes(ba);
      return be == ba && e.id == a.id && e.dest == a.dest;
    end
    if (!compare_user) begin
      axis_item c;
      $cast(c, a.clone());
      foreach (c.user[i]) if (i < e.user.size()) c.user[i] = e.user[i];
      return e.compare(c);
    end
    return e.compare(a);
  endfunction

  function void write_out(axis_item t);
    n_out++;
    if (exp_q.size() == 0) begin
      n_mismatch++;
      `vip_error("AXIS_SB_EXTRA", $sformatf("packet at the output without a matching input: %s", t.convert2string()))
      return;
    end
    begin
      axis_item e = exp_q.pop_front();
      if (same(e, t)) n_match++;
      else begin
        n_mismatch++;
        `vip_error("AXIS_SB_MISMATCH", $sformatf("expected {%s} got {%s}", e.convert2string(), t.convert2string()))
      end
    end
  endfunction

  function void check_phase(uvm_phase phase);
    if (exp_q.size() != 0 && !drop_allowed)
      `vip_error("AXIS_SB_MISSING", $sformatf("%0d packet(s) entered the DUT but never came out", exp_q.size()))
  endfunction

  function void report_phase(uvm_phase phase);
    `vip_info("AXIS_SB", $sformatf("in=%0d out=%0d matched=%0d mismatches=%0d flushes=%0d", n_in, n_out, n_match, n_mismatch, n_flush), UVM_LOW)
  endfunction
endclass : axis_scoreboard
