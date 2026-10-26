//-----------------------------------------------------------------------------
// dma_unit.sv
// DMA unit level control (TRM 5.9 / 5.10 / 5.11 / 6.5.2 - 6.5.5):
//   * register access decode with privilege / security protection
//     (RAZ/WI or PSLVERR on Secure violations, PDEBUG suppression)
//   * DMASECCFG, DMASECCTRL, DMANSECCTRL and DMAINFO frames
//   * channel security / privilege / CHID attributes
//   * all-channel stop / pause (SW bits and 4-phase HW handshakes)
//   * Cross Trigger Interface halt / restart
//   * unit level interrupts
// All asynchronous control inputs are synchronized here (dma_cdc_sync).
//-----------------------------------------------------------------------------
module dma_unit
  import dma_pkg::*;
#(
  parameter int NUM_CH  = 2,
  parameter int AW      = 32,
  parameter int DW      = 64,
  parameter int CHIDW   = 0,
  parameter int NTI     = 0,
  parameter int NTO     = 0,
  parameter bit SECEXT  = 1'b0,
  parameter bit GPOSEL  = 1'b0
) (
  input  logic                clk,
  input  logic                resetn,
  // ---- register access from the APB front-end
  input  logic                acc_wr,
  input  logic                acc_rd,
  input  logic [12:0]         acc_addr,
  input  logic [31:0]         acc_wdata,
  input  logic [2:0]          acc_prot,
  input  logic                acc_debug,
  output logic [31:0]         acc_rdata,
  output logic                acc_err,
  // ---- channel register ports
  output logic [NUM_CH-1:0]   ch_wr,
  output logic [NUM_CH-1:0]   ch_rd,
  output logic [7:0]          ch_off,
  output logic [31:0]         ch_wdata,
  input  logic [31:0]         ch_rdata [NUM_CH],
  // ---- channel attributes / control
  output logic [NUM_CH-1:0]   ch_nonsec,
  output logic [NUM_CH-1:0]   ch_priv,
  output logic [NUM_CH-1:0]   ch_attr_chg,
  output logic [15:0]         ch_chid [NUM_CH],
  output logic [NUM_CH-1:0]   ch_chidvld,
  output logic [NUM_CH-1:0]   ch_pause,
  output logic [NUM_CH-1:0]   ch_stop,
  // ---- channel status
  input  logic [NUM_CH-1:0]   st_enabled,
  input  logic [NUM_CH-1:0]   st_stopped,
  input  logic [NUM_CH-1:0]   st_paused,
  input  logic [NUM_CH-1:0]   st_irq,
  // ---- trigger matrix status / control
  input  logic [31:0]         tm_ti_req,
  input  logic [31:0]         tm_to_ack,
  input  logic [31:0]         tm_ti_sel,
  output logic [31:0]         tm_deny,
  output logic [31:0]         ti_nonsec,
  output logic [31:0]         to_nonsec,
  // ---- LPI
  input  logic                warm_rst_pause,
  output logic [1:0]          ns_dis_minpwr,
  output logic [1:0]          s_dis_minpwr,
  output logic                ns_idleret,
  output logic                s_idleret,
  // ---- external control (asynchronous)
  input  logic                allch_stop_req_nonsec,
  output logic                allch_stop_ack_nonsec,
  input  logic                allch_pause_req_nonsec,
  output logic                allch_pause_ack_nonsec,
  input  logic                allch_stop_req_sec,
  output logic                allch_stop_ack_sec,
  input  logic                allch_pause_req_sec,
  output logic                allch_pause_ack_sec,
  input  logic                halt_req,
  input  logic                restart_req,
  output logic                halted,
  // ---- interrupts
  output logic                irq_comb_nonsec,
  output logic                irq_comb_sec,
  output logic                irq_sec_viol_err
);

  localparam int DWB = DW / 8;
  localparam int CHW = (NUM_CH > 1) ? $clog2(NUM_CH) : 1;

  // ==========================================================================
  // Synchronizers for asynchronous control inputs
  // ==========================================================================
  logic s_stop_ns, s_pause_ns, s_stop_s, s_pause_s, s_halt, s_restart;

  dma_cdc_sync #(.WIDTH(6), .STAGES(2)) u_sync (
    .clk(clk), .resetn(resetn),
    .d_async({allch_stop_req_nonsec, allch_pause_req_nonsec, allch_stop_req_sec,
              allch_pause_req_sec, halt_req, restart_req}),
    .q_sync ({s_stop_ns, s_pause_ns, s_stop_s, s_pause_s, s_halt, s_restart})
  );

  // ==========================================================================
  // Registers
  // ==========================================================================
  logic [NUM_CH-1:0] chsec_ns;          // SCFG_CHSEC0 (1 = Non-secure)
  logic [31:0]       tisec, tosec;
  logic              cfg_lck, rsp_err, intren_vio, stat_vio;
  logic [NUM_CH-1:0] chpriv;
  logic [15:0]       chid [NUM_CH];
  logic [NUM_CH-1:0] chidvld;

  // per security domain control: index 0 = Non-secure, 1 = Secure
  logic [1:0]  dis_minpwr [2];
  logic [1:0]  idleret, allpause, allstop;
  logic [3:0]  intren [2];
  logic [1:0]  st_allpaused, st_allstopped, st_allidle;
  logic [5:0]  chptr [2];
  logic [3:0]  statusptr [2], signalptr [2];
  logic        dbghalten, dbghaltnsro;

  // effective channel security
  wire [NUM_CH-1:0] nsmask = SECEXT ? chsec_ns : {NUM_CH{1'b1}};
  wire [NUM_CH-1:0] smask  = SECEXT ? ~chsec_ns : {NUM_CH{1'b0}};
  wire [31:0] ti_ns = SECEXT ? tisec : 32'hFFFF_FFFF;
  wire [31:0] to_ns = SECEXT ? tosec : 32'hFFFF_FFFF;

  assign ch_nonsec = nsmask;
  assign ch_priv   = chpriv;
  assign ch_chidvld = (CHIDW > 0) ? chidvld : '0;
  assign ti_nonsec = ti_ns;
  assign to_nonsec = to_ns;
  assign ns_dis_minpwr = dis_minpwr[0];
  assign s_dis_minpwr  = SECEXT ? dis_minpwr[1] : 2'b00;
  assign ns_idleret    = idleret[0];
  assign s_idleret     = SECEXT ? idleret[1] : 1'b0;
  for (genvar c = 0; c < NUM_CH; c++) begin : g_chid
    assign ch_chid[c] = (CHIDW > 0) ? (chid[c] & 16'((32'h1 << CHIDW) - 1)) : 16'd0;
  end

  // ==========================================================================
  // Access decode
  // ==========================================================================
  wire a_priv = acc_prot[0];
  wire a_ns   = SECEXT ? acc_prot[1] : 1'b0;
  wire [3:0] frame_hi = acc_addr[12:9];
  wire [7:0] off      = acc_addr[7:0];

  wire is_chan  = acc_addr[12];
  wire [3:0] cidx = acc_addr[11:8];
  wire is_scfg  = (acc_addr[12:8] == 5'h00);
  wire is_sctl  = (acc_addr[12:8] == 5'h01);
  wire is_nsctl = (acc_addr[12:8] == 5'h02);
  wire is_info  = (acc_addr[12:8] == 5'h0F);
  wire chan_ok  = is_chan && (cidx < NUM_CH);

  logic acc_ok, viol, raz;
  always_comb begin
    acc_ok = 1'b0;
    viol   = 1'b0;
    if (is_info) acc_ok = 1'b1;
    else if (is_scfg || is_sctl) begin
      if (!SECEXT)      acc_ok = 1'b0;                 // RAZ/WI
      else if (a_ns)    viol   = 1'b1;
      else if (a_priv)  acc_ok = 1'b1;
    end else if (is_nsctl) begin
      acc_ok = a_priv;
    end else if (chan_ok) begin
      if (SECEXT && !chsec_ns[cidx] && a_ns) viol = 1'b1;
      else if (chpriv[cidx] && !a_priv)      acc_ok = 1'b0;
      else                                   acc_ok = 1'b1;
    end
  end

  wire do_wr = acc_wr && acc_ok;
  wire do_rd = acc_rd && acc_ok;
  wire report_vio = (acc_wr || acc_rd) && viol && !acc_debug;
  assign acc_err = report_vio && rsp_err;

  // channel ports
  always_comb begin
    for (int c = 0; c < NUM_CH; c++) begin
      ch_wr[c] = do_wr && chan_ok && (cidx == c);
      ch_rd[c] = do_rd && chan_ok && (cidx == c);
    end
  end
  assign ch_off   = off;
  assign ch_wdata = acc_wdata;

  // ==========================================================================
  // Status aggregation
  // ==========================================================================
  wire [NUM_CH-1:0] chan_quiet_or_paused = ~st_enabled | st_paused;
  wire ns_all_inactive = ((st_enabled & nsmask) == '0);
  wire s_all_inactive  = ((st_enabled & smask)  == '0);
  wire ns_all_paused   = ((~chan_quiet_or_paused & nsmask) == '0);
  wire s_all_paused    = ((~chan_quiet_or_paused & smask)  == '0);
  wire all_paused      = ns_all_paused & s_all_paused;

  // ==========================================================================
  // CTI halt / restart
  // ==========================================================================
  typedef enum logic [1:0] { H_RUN, H_HALTING, H_HALTED } hst_e;
  hst_e hst;
  logic halt_d, restart_d;
  wire  halt_rise    = s_halt & ~halt_d;
  wire  restart_rise = s_restart & ~restart_d;

  always_ff @(posedge clk or negedge resetn) begin
    if (!resetn) begin
      hst <= H_RUN; halt_d <= 1'b0; restart_d <= 1'b0; halted <= 1'b0;
    end else begin
      halt_d    <= s_halt;
      restart_d <= s_restart;
      halted    <= 1'b0;
      case (hst)
        H_RUN:     if (halt_rise && dbghalten) hst <= H_HALTING;
        H_HALTING: begin
                     if (!dbghalten)       hst <= H_RUN;
                     else if (all_paused) begin
                       halted <= 1'b1;
                       hst    <= H_HALTED;
                     end
                   end
        H_HALTED:  if (restart_rise || !dbghalten) hst <= H_RUN;
        default:   hst <= H_RUN;
      endcase
    end
  end
  wire cti_pause = (hst != H_RUN);

  // ==========================================================================
  // Pause / stop distribution
  // ==========================================================================
  wire ns_pause_any = allpause[0] | s_pause_ns | cti_pause | warm_rst_pause;
  wire s_pause_any  = allpause[1] | s_pause_s  | cti_pause | warm_rst_pause;
  wire ns_stop_any  = allstop[0]  | s_stop_ns;
  wire s_stop_any   = allstop[1]  | s_stop_s;

  always_comb begin
    for (int c = 0; c < NUM_CH; c++) begin
      ch_pause[c] = nsmask[c] ? ns_pause_any : s_pause_any;
      ch_stop[c]  = nsmask[c] ? ns_stop_any  : s_stop_any;
    end
  end

  // HW handshakes (registered acks)
  always_ff @(posedge clk or negedge resetn) begin
    if (!resetn) begin
      allch_stop_ack_nonsec  <= 1'b0; allch_pause_ack_nonsec <= 1'b0;
      allch_stop_ack_sec     <= 1'b0; allch_pause_ack_sec    <= 1'b0;
    end else begin
      allch_stop_ack_nonsec  <= s_stop_ns  & ns_all_inactive;
      allch_pause_ack_nonsec <= s_pause_ns & ns_all_paused;
      allch_stop_ack_sec     <= SECEXT & s_stop_s  & s_all_inactive;
      allch_pause_ack_sec    <= SECEXT & s_pause_s & s_all_paused;
    end
  end

  // ==========================================================================
  // Register writes
  // ==========================================================================
  logic [NUM_CH-1:0] was_act;   // [d] at least one channel ran since last idle
  logic [1:0]        any_was;

  // writes to channel attributes are only accepted for disabled channels
  always_ff @(posedge clk or negedge resetn) begin
    if (!resetn) begin
      chsec_ns <= '0; tisec <= '0; tosec <= '0;
      cfg_lck <= 1'b0; rsp_err <= 1'b0; intren_vio <= 1'b0; stat_vio <= 1'b0;
      chpriv <= '0; chidvld <= '0;
      for (int c = 0; c < NUM_CH; c++) chid[c] <= '0;
      for (int d = 0; d < 2; d++) begin
        dis_minpwr[d] <= '0; intren[d] <= '0; chptr[d] <= '0; statusptr[d] <= '0; signalptr[d] <= '0;
      end
      idleret <= '0; allpause <= '0; allstop <= '0;
      st_allpaused <= '0; st_allstopped <= '0; st_allidle <= '0; any_was <= '0;
      dbghalten <= 1'b0; dbghaltnsro <= 1'b0;
      ch_attr_chg <= '0;
      tm_deny <= '0;
    end else begin
      ch_attr_chg <= '0;
      tm_deny     <= '0;

      if (report_vio) stat_vio <= 1'b1;

      // ------------------------------------------------ status flags
      // all-channel paused / stopped (requests from the SW bits only).
      // Evaluated before the register writes so that a W1C of the flag (which
      // also withdraws the request) wins in the same cycle: one write clears.
      if (allpause[0] && ns_all_paused)   st_allpaused[0]  <= 1'b1;
      if (allpause[1] && s_all_paused)    st_allpaused[1]  <= SECEXT;
      if (allstop[0]  && ns_all_inactive) st_allstopped[0] <= 1'b1;
      if (allstop[1]  && s_all_inactive)  st_allstopped[1] <= SECEXT;

      // ------------------------------------------------ DMASECCFG
      if (do_wr && is_scfg) begin
        case (off)
          SCFG_CHSEC0: if (!cfg_lck) begin
            for (int c = 0; c < NUM_CH; c++)
              if (!st_enabled[c] && chsec_ns[c] != acc_wdata[c]) begin
                chsec_ns[c]    <= acc_wdata[c];
                ch_attr_chg[c] <= 1'b1;
              end
          end
          SCFG_TRIGINSEC0: if (!cfg_lck) begin
            for (int p = 0; p < 32; p++)
              if (p < NTI && !tm_ti_sel[p]) tisec[p] <= acc_wdata[p];
          end
          SCFG_TRIGOUTSEC0: if (!cfg_lck) begin
            for (int q = 0; q < 32; q++)
              if (q < NTO) tosec[q] <= acc_wdata[q];
          end
          SCFG_CTRL: if (!cfg_lck) begin
            cfg_lck    <= acc_wdata[31];
            rsp_err    <= acc_wdata[1];
            intren_vio <= acc_wdata[0];
          end
          SCFG_INTRSTATUS: if (acc_wdata[16]) stat_vio <= 1'b0;
          default: ;
        endcase
      end

      // ------------------------------------------------ SEC / NSEC control
      for (int d = 0; d < 2; d++) begin
        logic hit;
        hit = do_wr && ((d == 0) ? is_nsctl : is_sctl);
        if (hit) begin
          case (off)
            U_STATUS: begin
              if (acc_wdata[19]) begin st_allpaused[d]  <= 1'b0; allpause[d] <= 1'b0; end
              if (acc_wdata[18]) begin st_allstopped[d] <= 1'b0; allstop[d]  <= 1'b0; end
              if (acc_wdata[17]) st_allidle[d] <= 1'b0;
            end
            U_CTRL: begin
              dis_minpwr[d] <= acc_wdata[31:30];
              idleret[d]    <= acc_wdata[29];
              if (d == 1)                    dbghalten <= acc_wdata[28];
              else if (!dbghaltnsro)         dbghalten <= acc_wdata[28];
              if (d == 1)                    dbghaltnsro <= acc_wdata[27];
              if (acc_wdata[9]) allpause[d] <= 1'b1;
              if (acc_wdata[8]) allstop[d]  <= 1'b1;
              intren[d] <= acc_wdata[3:0];
            end
            U_CHPTR:     chptr[d] <= acc_wdata[5:0];
            U_CHCFG: begin
              if (chptr[d] < NUM_CH) begin
                logic [CHW-1:0] ci;
                ci = CHW'(chptr[d]);
                // Non-secure frame can only configure Non-secure channels
                if (!st_enabled[ci] && (d == 1 || nsmask[ci])) begin
                  if (chpriv[ci] != acc_wdata[17]) ch_attr_chg[ci] <= 1'b1;
                  chpriv[ci]  <= acc_wdata[17];
                  chidvld[ci] <= acc_wdata[16];
                  chid[ci]    <= acc_wdata[15:0];
                end
              end
            end
            U_STATUSPTR: statusptr[d] <= acc_wdata[3:0];
            U_SIGNALPTR: signalptr[d] <= acc_wdata[3:0];
            U_SIGNALVAL: begin
              if (signalptr[d] == 4'd0) begin
                for (int p = 0; p < 32; p++)
                  if (p < NTI && acc_wdata[p] && !tm_ti_sel[p] &&
                      ((d == 0) ? ti_ns[p] : !ti_ns[p]))
                    tm_deny[p] <= 1'b1;
              end
            end
            default: ;
          endcase
        end
      end

      // all-channel idle after activity
      if (|(st_enabled & nsmask)) any_was[0] <= 1'b1;
      else if (any_was[0]) begin any_was[0] <= 1'b0; st_allidle[0] <= 1'b1; end
      if (|(st_enabled & smask))  any_was[1] <= 1'b1;
      else if (any_was[1]) begin any_was[1] <= 1'b0; st_allidle[1] <= SECEXT; end
    end
  end

  // ==========================================================================
  // Interrupts
  // ==========================================================================
  logic [3:0] intr [2];
  always_comb begin
    intr[0][0] = intren[0][0] & |(st_irq & nsmask);
    intr[0][1] = intren[0][1] & st_allidle[0];
    intr[0][2] = intren[0][2] & st_allstopped[0];
    intr[0][3] = intren[0][3] & st_allpaused[0];
    intr[1][0] = SECEXT & intren[1][0] & |(st_irq & smask);
    intr[1][1] = SECEXT & intren[1][1] & st_allidle[1];
    intr[1][2] = SECEXT & intren[1][2] & st_allstopped[1];
    intr[1][3] = SECEXT & intren[1][3] & st_allpaused[1];
  end

  always_ff @(posedge clk or negedge resetn) begin
    if (!resetn) begin
      irq_comb_nonsec  <= 1'b0;
      irq_comb_sec     <= 1'b0;
      irq_sec_viol_err <= 1'b0;
    end else begin
      irq_comb_nonsec  <= |intr[0];
      irq_comb_sec     <= |intr[1];
      irq_sec_viol_err <= SECEXT & intren_vio & stat_vio;
    end
  end

  // ==========================================================================
  // Read mux
  // ==========================================================================
  localparam logic [31:0] BUILDCFG0 = {7'd0, 5'(CHIDW), 1'b0, 3'($clog2(DWB)), 6'(AW-1),
                                       6'(NUM_CH-1), 1'b0, 3'b000};
  localparam logic [31:0] BUILDCFG1 = {7'd0, 1'b0, 7'd0, 1'b1, 7'(NTO), 9'(NTI)};
  localparam logic [31:0] BUILDCFG2 = {22'd0, 1'b1, SECEXT, GPOSEL, 7'd0};
  localparam logic [3:0]  PID_SIZE  = (NUM_CH > 16) ? 4'd1 : 4'd0;

  function automatic logic [31:0] statusval(input logic [3:0] ptr, input logic [NUM_CH-1:0] m);
    logic [31:0] v;
    v = '0;
    case (ptr)
      4'd0: v = 32'(st_enabled & m);
      4'd2: v = 32'(st_stopped & m);
      4'd4: v = 32'(st_paused  & m);
      default: v = '0;
    endcase
    return v;
  endfunction

  function automatic logic [31:0] signalval(input logic [3:0] ptr, input logic [31:0] tim, input logic [31:0] tom);
    logic [31:0] v;
    v = '0;
    case (ptr)
      4'd0: v = tm_ti_req & tim;
      4'd8: v = tm_to_ack & tom;
      default: v = '0;
    endcase
    return v;
  endfunction

  logic [31:0] rd_unit;
  always_comb begin
    rd_unit = '0;
    if (is_scfg) begin
      case (off)
        SCFG_CHSEC0:      rd_unit = 32'(chsec_ns);
        SCFG_TRIGINSEC0:  rd_unit = tisec;
        SCFG_TRIGOUTSEC0: rd_unit = tosec;
        SCFG_CTRL:        rd_unit = {cfg_lck, 29'd0, rsp_err, intren_vio};
        SCFG_INTRSTATUS:  rd_unit = {15'd0, stat_vio, 15'd0, intren_vio & stat_vio};
        default: ;
      endcase
    end else if (is_sctl || is_nsctl) begin
      int d;
      logic [NUM_CH-1:0] m;
      logic [31:0] tim, tom;
      d   = is_sctl ? 1 : 0;
      m   = is_sctl ? smask : nsmask;
      tim = is_sctl ? ~ti_ns : ti_ns;
      tom = is_sctl ? ~to_ns : to_ns;
      case (off)
        U_CHINTRSTATUS0: rd_unit = 32'(st_irq & m);
        U_STATUS:        rd_unit = {12'd0, st_allpaused[d], st_allstopped[d], st_allidle[d],
                                    13'd0, intr[d]};
        U_CTRL:          rd_unit = {dis_minpwr[d], idleret[d], dbghalten, dbghaltnsro, 17'd0,
                                    allpause[d], allstop[d], 4'd0, intren[d]};
        U_CHPTR:         rd_unit = {26'd0, chptr[d]};
        U_CHCFG: begin
          if (chptr[d] < NUM_CH && (d == 1 || nsmask[CHW'(chptr[d])]))
            rd_unit = {14'd0, chpriv[CHW'(chptr[d])],
                       (CHIDW > 0) ? chidvld[CHW'(chptr[d])] : 1'b0,
                       ch_chid[CHW'(chptr[d])]};
        end
        U_STATUSPTR:     rd_unit = {28'd0, statusptr[d]};
        U_STATUSVAL:     rd_unit = statusval(statusptr[d], m);
        U_SIGNALPTR:     rd_unit = {28'd0, signalptr[d]};
        U_SIGNALVAL:     rd_unit = signalval(signalptr[d], tim, tom);
        default: ;
      endcase
    end else if (is_info) begin
      case (off)
        I_BUILDCFG0: rd_unit = BUILDCFG0;
        I_BUILDCFG1: rd_unit = BUILDCFG1;
        I_BUILDCFG2: rd_unit = BUILDCFG2;
        I_IIDR:      rd_unit = IIDR_VAL;
        I_AIDR:      rd_unit = AIDR_VAL;
        I_PIDR4:     rd_unit = {24'd0, PID_SIZE, 4'h4};
        I_PIDR0:     rd_unit = 32'h0000_00A0;
        I_PIDR1:     rd_unit = 32'h0000_00B3;
        I_PIDR2:     rd_unit = 32'h0000_000B;
        I_PIDR3:     rd_unit = 32'h0000_0000;
        I_CIDR0:     rd_unit = 32'h0000_000D;
        I_CIDR1:     rd_unit = 32'h0000_00F0;
        I_CIDR2:     rd_unit = 32'h0000_0005;
        I_CIDR3:     rd_unit = 32'h0000_00B1;
        default: ;
      endcase
    end
  end

  always_comb begin
    acc_rdata = '0;
    if (do_rd) begin
      if (chan_ok) acc_rdata = ch_rdata[CHW'(cidx)];
      else         acc_rdata = rd_unit;
    end
  end

  wire unused = |{frame_hi, was_act};

endmodule : dma_unit
