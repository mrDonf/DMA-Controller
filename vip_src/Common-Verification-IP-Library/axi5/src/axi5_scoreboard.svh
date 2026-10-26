// -----------------------------------------------------------------------------
// axi5_scoreboard - reference-memory scoreboard for a memory-like subordinate (bursts observed on the bus)
//   * OKAY / EXOKAY writes update the reference memory with their byte strobes; a write with AxLOCK that answers OKAY
//     (exclusive failed) does not
//   * OKAY / EXOKAY reads are compared on the byte lanes that belong to each beat
//   * SLVERR / DECERR bursts change nothing; they are only accepted where the configuration allows an error
//   * words written by a burst that a reset cut become "unknown" until a full-word write defines them again
//   * AXI5 atomics: the scoreboard executes the operation on its reference memory (independent implementation of the
//     operand window, compare / swap halves and the arithmetic) and compares the returned original value on the operand
//     lanes; error responses change nothing (cfg.atomics_en = 0: every atomic must answer SLVERR)
//   * poison: reference poison per CHUNK_B bytes, compared with RPOISON on every checked read beat
//   Tests keep concurrently running reads and writes on different regions (the scoreboard orders by completion).
// -----------------------------------------------------------------------------
class axi5_scoreboard extends uvm_scoreboard;
  `uvm_component_utils(axi5_scoreboard)

  `uvm_analysis_imp_decl(_abort)
  uvm_analysis_imp #(axi5_item, axi5_scoreboard) imp;
  uvm_analysis_imp_abort #(axi5_item, axi5_scoreboard) imp_abort;
  axi5_agent_cfg cfg;
  vip_sparse_mem ref_mem;
  int unsigned   n_checked, n_mismatch, n_wr, n_err_seen, n_skipped, n_excl_ok, n_excl_fail;
  int unsigned   n_atomic, n_atomic_checked, n_poison_checked;
  protected bit  unknown [bit [AXI5_ADDR_W-1:0]];
  protected bit  ref_poison [longint unsigned];

  function new(string name, uvm_component parent);
    super.new(name, parent);
  endfunction

  function void build_phase(uvm_phase phase);
    super.build_phase(phase);
    imp = new("imp", this);
    imp_abort = new("imp_abort", this);
    ref_mem = new();
  endfunction

  function void start_of_simulation_phase(uvm_phase phase);
    if (cfg != null) ref_mem.init_mode = cfg.mem_init;
  endfunction

  function void write_abort(axi5_item t);
    if (t.write) for (int i = 0; i < t.beats(); i++) unknown[t.beat_addr(i) & ~AXI5_ADDR_W'(AXI5_STRB_W - 1)] = 1'b1;
  endfunction

  protected function bit word_unknown(bit [AXI5_ADDR_W-1:0] a, int unsigned n);
    for (int unsigned i = 0; i < n; i++) if (unknown.exists((a + i) & ~AXI5_ADDR_W'(AXI5_STRB_W - 1))) return 1;
    return 0;
  endfunction

  protected function void poison_ref(bit [AXI5_ADDR_W-1:0] ba, bit [AXI5_STRB_W-1:0] st, bit [AXI5_POISON_W-1:0] pz);
    if (cfg == null || !cfg.poison_en) return;
    for (int c = 0; c < AXI5_POISON_W; c++) begin
      bit any = 0, all = 1;
      for (int l = c * AXI5_CHUNK_B; l < (c + 1) * AXI5_CHUNK_B && l < AXI5_STRB_W; l++) begin any |= st[l]; all &= st[l]; end
      if (any && pz[c]) ref_poison[longint'(ba) + c * AXI5_CHUNK_B] = 1'b1;
      else if (any && all) ref_poison.delete(longint'(ba) + c * AXI5_CHUNK_B);
    end
  endfunction

  protected function void check_poison(bit [AXI5_ADDR_W-1:0] ba, bit [AXI5_POISON_W-1:0] got, string what);
    if (cfg == null || !cfg.poison_en) return;
    for (int c = 0; c < AXI5_POISON_W; c++) begin
      bit e = ref_poison.exists(longint'(ba) + c * AXI5_CHUNK_B);
      n_poison_checked++;
      if (got[c] !== e) begin
        n_mismatch++;
        `vip_error("AXI5_SB_POISON", $sformatf("%s addr 0x%0h chunk %0d: RPOISON=%b, expected %b", what, ba, c, got[c], e))
      end
    end
  endfunction

  // atomic: the bytes of the window from the W beats, the operation on the reference memory, the returned original value
  protected function void atomic(axi5_item t);
    axi5_atop_kind_e k = t.atop_kind();
    int unsigned total = t.total_bytes();
    int unsigned n     = (k == AXI5_ATOP_COMPARE) ? total / 2 : total;
    longint unsigned a = longint'(t.addr), w0 = a - (a % total), sw = (a == w0) ? w0 + n : w0;
    byte unsigned wb [longint unsigned];
    byte unsigned orig[$], opnd[$], swp[$], res[$];
    bit err = t.bresp[1];
    bit pz = 0;
    n_atomic++;
    foreach (t.aresp[i]) if (t.aresp[i][1]) err = 1;
    if (err) begin
      n_err_seen++;
      if (cfg != null && cfg.atomics_en && !cfg.error_possible(t.addr))
        `vip_error("AXI5_SB_ERR", $sformatf("unexpected error response to an atomic: %s", t.convert2string()))
      return;
    end
    if (cfg != null && !cfg.atomics_en) `vip_error("AXI5_SB_ERR", {"atomic answered OKAY although the subordinate has no atomics: ", t.convert2string()})
    // write data bytes: single transfer = the whole window on its lanes, longer = full-width beats of the burst
    for (int i = 0; i < t.beats(); i++) begin
      longint unsigned bb = (t.beats() == 1) ? (w0 - (w0 % AXI5_STRB_W)) : (longint'(t.beat_addr(i)) - (longint'(t.beat_addr(i)) % AXI5_STRB_W));
      for (int l = 0; l < AXI5_STRB_W; l++)
        if (t.strb[i][l] && bb + l >= w0 && bb + l < w0 + total) wb[bb + l] = t.data[i][8*l +: 8];
      if (t.poison[i] != 0) pz = 1;
    end
    if (word_unknown(t.addr, n)) begin                       // the original value is not known: the result is not either
      for (int i = 0; i < n; i++) unknown[(t.addr + i) & ~AXI5_ADDR_W'(AXI5_STRB_W - 1)] = 1'b1;
      n_skipped++;
      return;
    end
    for (int i = 0; i < n; i++) begin
      orig.push_back(ref_mem.read_byte(a + i));
      opnd.push_back(wb.exists(a + i) ? wb[a + i] : 8'h00);
      if (k == AXI5_ATOP_COMPARE) swp.push_back(wb.exists(sw + i) ? wb[sw + i] : 8'h00);
    end
    // returned original value on the lanes of the operand
    if (axi5_atop_has_rdata(t.atop)) begin
      int unsigned rb = axi5_atop_rbeats(t.atop, t.size, t.len);
      bit [2:0] rsz = axi5_atop_rsize(t.atop, t.size, t.len);
      if (t.adata.size() != rb) begin
        n_mismatch++;
        `vip_error("AXI5_SB_MISMATCH", $sformatf("atomic returned %0d read data beats, expected %0d: %s", t.adata.size(), rb, t.convert2string()))
      end
      for (int j = 0; j < rb && j < t.adata.size(); j++) begin
        longint unsigned ba = longint'(axi5_burst_addr(t.addr, rsz, AXI5_INCR, rb, j));
        bit [AXI5_STRB_W-1:0] ln = axi5_valid_lanes(t.addr, rsz, AXI5_INCR, rb, j);
        ba = ba - (ba % AXI5_STRB_W);
        for (int l = 0; l < AXI5_STRB_W; l++)
          if (ln[l] && ba + l >= a && ba + l < a + n && t.adata[j][8*l +: 8] !== orig[ba + l - a]) begin
            n_mismatch++;
            `vip_error("AXI5_SB_MISMATCH", $sformatf("atomic %s addr 0x%0h byte %0d: returned 0x%0h, original 0x%0h", k.name(), t.addr,
                       ba + l - a, t.adata[j][8*l +: 8], orig[ba + l - a]))
            break;
          end
        check_poison(AXI5_ADDR_W'(ba), t.apoison[j], "atomic read data");
      end
      n_atomic_checked++;
    end
    axi5_atomic_result(t.atop, orig, opnd, swp, res);
    foreach (res[i]) ref_mem.write_byte(a + i, res[i]);
    if (pz && cfg != null && cfg.poison_en) for (int i = 0; i < n; i += AXI5_CHUNK_B) ref_poison[(a + i) - ((a + i) % AXI5_CHUNK_B)] = 1'b1;
  endfunction

  function void write(axi5_item t);
    bit bad_resp = t.write ? t.bresp[1] : 1'b0;
    if (t.write && t.atop != 0) begin atomic(t); return; end
    if (t.write) begin
      if (bad_resp) begin
        n_err_seen++;
        if (cfg != null && !cfg.error_possible(t.addr) && !cfg.error_possible(t.beat_addr(t.beats() - 1)))
          `vip_error("AXI5_SB_ERR", $sformatf("unexpected error response: %s", t.convert2string()))
        return;
      end
      if (t.lock && t.bresp == AXI5_OKAY) begin n_excl_fail++; return; end          // exclusive write that did not happen
      if (t.lock) n_excl_ok++;
      for (int i = 0; i < t.beats(); i++) begin
        bit [AXI5_ADDR_W-1:0] ba = t.beat_addr(i) & ~AXI5_ADDR_W'(AXI5_STRB_W - 1);
        for (int l = 0; l < AXI5_STRB_W; l++) if (t.strb[i][l]) ref_mem.write_byte(longint'(ba) + l, t.data[i][8*l +: 8]);
        poison_ref(ba, t.strb[i], (i < t.poison.size()) ? t.poison[i] : '0);
        if (t.strb[i] == {AXI5_STRB_W{1'b1}}) unknown.delete(ba);
      end
      n_wr++;
    end else begin
      for (int i = 0; i < t.beats() && i < t.data.size(); i++) begin
        bit [AXI5_ADDR_W-1:0] ba = t.beat_addr(i) & ~AXI5_ADDR_W'(AXI5_STRB_W - 1);
        bit [AXI5_STRB_W-1:0] lanes = t.valid_lanes(i);
        if (t.rresp[i][1]) begin
          n_err_seen++;
          if (cfg != null && !cfg.error_possible(t.beat_addr(i)))
            `vip_error("AXI5_SB_ERR", $sformatf("unexpected error response on read beat %0d: %s", i, t.convert2string()))
          continue;
        end
        n_checked++;
        if (unknown.exists(ba)) begin n_skipped++; continue; end
        for (int l = 0; l < AXI5_STRB_W; l++)
          if (lanes[l] && ref_mem.read_byte(longint'(ba) + l) !== t.data[i][8*l +: 8]) begin
            n_mismatch++;
            `vip_error("AXI5_SB_MISMATCH", $sformatf("read id=%0h beat %0d addr 0x%0h lane %0d: got 0x%0h expected 0x%0h", t.id, i, t.beat_addr(i), l,
                       t.data[i][8*l +: 8], ref_mem.read_byte(longint'(ba) + l)))
            break;
          end
        if (i < t.rpoison.size()) check_poison(ba, t.rpoison[i], "read");
      end
    end
  endfunction

  function void report_phase(uvm_phase phase);
    `vip_info("AXI5_SB", $sformatf("write bursts=%0d read beats checked=%0d mismatches=%0d error responses=%0d exclusive ok/failed=%0d/%0d skipped=%0d",
              n_wr, n_checked, n_mismatch, n_err_seen, n_excl_ok, n_excl_fail, n_skipped), UVM_LOW)
    `vip_info("AXI5_SB", $sformatf("atomics=%0d (read data checked %0d) poison bits checked=%0d", n_atomic, n_atomic_checked, n_poison_checked), UVM_LOW)
  endfunction
endclass : axi5_scoreboard
