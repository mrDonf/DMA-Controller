//-----------------------------------------------------------------------------
// dma_pkg.sv
// Common types, constants and helper functions for the AXI DMA controller.
// Register map / field encodings follow the CoreLink DMA-350 TRM (102482_0000_04).
//-----------------------------------------------------------------------------
package dma_pkg;

  //---------------------------------------------------------------------------
  // Fixed architectural limits
  //---------------------------------------------------------------------------
  localparam int MAX_CH        = 8;    // max number of channels
  localparam int MAX_TRIG      = 32;   // max trigger in / out ports
  localparam int MAX_BURST_BTS = 16;   // MAXBURSTLEN+1 upper bound (beats)

  //---------------------------------------------------------------------------
  // Register frame bases (13-bit APB address)
  //---------------------------------------------------------------------------
  localparam logic [12:0] FRM_SECCFG  = 13'h0000;
  localparam logic [12:0] FRM_SECCTRL = 13'h0100;
  localparam logic [12:0] FRM_NSCTRL  = 13'h0200;
  localparam logic [12:0] FRM_INFO    = 13'h0F00;
  localparam logic [12:0] FRM_CH0     = 13'h1000;

  //---------------------------------------------------------------------------
  // Channel register offsets
  //---------------------------------------------------------------------------
  localparam logic [7:0] CH_CMD          = 8'h00;
  localparam logic [7:0] CH_STATUS       = 8'h04;
  localparam logic [7:0] CH_INTREN       = 8'h08;
  localparam logic [7:0] CH_CTRL         = 8'h0C;
  localparam logic [7:0] CH_SRCADDR      = 8'h10;
  localparam logic [7:0] CH_SRCADDRHI    = 8'h14;
  localparam logic [7:0] CH_DESADDR      = 8'h18;
  localparam logic [7:0] CH_DESADDRHI    = 8'h1C;
  localparam logic [7:0] CH_XSIZE        = 8'h20;
  localparam logic [7:0] CH_XSIZEHI      = 8'h24;
  localparam logic [7:0] CH_SRCTRANSCFG  = 8'h28;
  localparam logic [7:0] CH_DESTRANSCFG  = 8'h2C;
  localparam logic [7:0] CH_XADDRINC     = 8'h30;
  localparam logic [7:0] CH_YADDRSTRIDE  = 8'h34;
  localparam logic [7:0] CH_FILLVAL      = 8'h38;
  localparam logic [7:0] CH_YSIZE        = 8'h3C;
  localparam logic [7:0] CH_TMPLTCFG     = 8'h40;
  localparam logic [7:0] CH_SRCTMPLT     = 8'h44;
  localparam logic [7:0] CH_DESTMPLT     = 8'h48;
  localparam logic [7:0] CH_SRCTRIGINCFG = 8'h4C;
  localparam logic [7:0] CH_DESTRIGINCFG = 8'h50;
  localparam logic [7:0] CH_TRIGOUTCFG   = 8'h54;
  localparam logic [7:0] CH_GPOEN0       = 8'h58;
  localparam logic [7:0] CH_GPOVAL0      = 8'h60;
  localparam logic [7:0] CH_STREAMINTCFG = 8'h68;
  localparam logic [7:0] CH_LINKATTR     = 8'h70;
  localparam logic [7:0] CH_AUTOCFG      = 8'h74;
  localparam logic [7:0] CH_LINKADDR     = 8'h78;
  localparam logic [7:0] CH_LINKADDRHI   = 8'h7C;
  localparam logic [7:0] CH_GPOREAD0     = 8'h80;
  localparam logic [7:0] CH_WRKREGPTR    = 8'h88;
  localparam logic [7:0] CH_WRKREGVAL    = 8'h8C;
  localparam logic [7:0] CH_ERRINFO      = 8'h90;
  localparam logic [7:0] CH_IIDR         = 8'hC8;
  localparam logic [7:0] CH_AIDR         = 8'hCC;
  localparam logic [7:0] CH_ISSUECAP     = 8'hE8;
  localparam logic [7:0] CH_BUILDCFG0    = 8'hF8;
  localparam logic [7:0] CH_BUILDCFG1    = 8'hFC;

  // Unit frame offsets
  localparam logic [7:0] U_CHINTRSTATUS0 = 8'h00;
  localparam logic [7:0] U_STATUS        = 8'h08;
  localparam logic [7:0] U_CTRL          = 8'h0C;
  localparam logic [7:0] U_CHPTR         = 8'h14;
  localparam logic [7:0] U_CHCFG         = 8'h18;
  localparam logic [7:0] U_STATUSPTR     = 8'hF0;
  localparam logic [7:0] U_STATUSVAL     = 8'hF4;
  localparam logic [7:0] U_SIGNALPTR     = 8'hF8;
  localparam logic [7:0] U_SIGNALVAL     = 8'hFC;

  localparam logic [7:0] SCFG_CHSEC0      = 8'h00;
  localparam logic [7:0] SCFG_TRIGINSEC0  = 8'h08;
  localparam logic [7:0] SCFG_TRIGOUTSEC0 = 8'h28;
  localparam logic [7:0] SCFG_CTRL        = 8'h40;
  localparam logic [7:0] SCFG_INTRSTATUS  = 8'h44;

  localparam logic [7:0] I_BUILDCFG0 = 8'hB0;
  localparam logic [7:0] I_BUILDCFG1 = 8'hB4;
  localparam logic [7:0] I_BUILDCFG2 = 8'hB8;
  localparam logic [7:0] I_IIDR      = 8'hC8;
  localparam logic [7:0] I_AIDR      = 8'hCC;
  localparam logic [7:0] I_PIDR4     = 8'hD0;
  localparam logic [7:0] I_PIDR0     = 8'hE0;
  localparam logic [7:0] I_PIDR1     = 8'hE4;
  localparam logic [7:0] I_PIDR2     = 8'hE8;
  localparam logic [7:0] I_PIDR3     = 8'hEC;
  localparam logic [7:0] I_CIDR0     = 8'hF0;
  localparam logic [7:0] I_CIDR1     = 8'hF4;
  localparam logic [7:0] I_CIDR2     = 8'hF8;
  localparam logic [7:0] I_CIDR3     = 8'hFC;

  //---------------------------------------------------------------------------
  // Field encodings
  //---------------------------------------------------------------------------
  localparam logic [2:0] XT_DISABLE  = 3'b000;
  localparam logic [2:0] XT_CONTINUE = 3'b001;
  localparam logic [2:0] XT_WRAP     = 3'b010;
  localparam logic [2:0] XT_FILL     = 3'b011;

  localparam logic [1:0] TRIGTYPE_SW  = 2'b00;
  localparam logic [1:0] TRIGTYPE_HW  = 2'b10;
  localparam logic [1:0] TRIGTYPE_INT = 2'b11;

  localparam logic [1:0] TRIGMODE_CMD   = 2'b00;
  localparam logic [1:0] TRIGMODE_DMAFC = 2'b10;
  localparam logic [1:0] TRIGMODE_PERFC = 2'b11;

  localparam logic [1:0] REQ_SINGLE      = 2'b00;
  localparam logic [1:0] REQ_LAST_SINGLE = 2'b01;
  localparam logic [1:0] REQ_BLOCK       = 2'b10;
  localparam logic [1:0] REQ_LAST_BLOCK  = 2'b11;

  localparam logic [1:0] ACK_OKAY      = 2'b00;
  localparam logic [1:0] ACK_DENY      = 2'b01;
  localparam logic [1:0] ACK_LAST_OKAY = 2'b10;

  localparam logic [1:0] STRT_INOUT  = 2'b00;
  localparam logic [1:0] STRT_OUT    = 2'b01;
  localparam logic [1:0] STRT_IN     = 2'b10;

  localparam logic [1:0] AXI_FIXED = 2'b00;
  localparam logic [1:0] AXI_INCR  = 2'b01;

  // LPI power states (Arm standard P-Channel encoding)
  localparam logic [3:0] PS_OFF      = 4'd0;
  localparam logic [3:0] PS_FULL_RET = 4'd5;
  localparam logic [3:0] PS_ON       = 4'd8;
  localparam logic [3:0] PS_WARM_RST = 4'd9;

  // Identification values (product id kept as the TRM values for SW compatibility)
  localparam logic [31:0] IIDR_VAL = 32'h3A00_043B;
  localparam logic [31:0] AIDR_VAL = 32'h0000_0000;

  //---------------------------------------------------------------------------
  // Helper functions
  //---------------------------------------------------------------------------
  function automatic int clog2_min1(input int v);
    int r;
    r = (v <= 1) ? 1 : $clog2(v);
    return r;
  endfunction

  function automatic int max2(input int a, input int b);
    return (a > b) ? a : b;
  endfunction

  // Memory attribute (MAIR-like) -> AxCACHE mapping.
  //   attr_hi = outer (system) attribute, attr_lo = inner attribute.
  //   is_wr selects the AWCACHE allocate encoding.
  function automatic logic [3:0] memattr_to_cache(input logic [3:0] attr_hi,
                                                  input logic [3:0] attr_lo,
                                                  input logic       is_wr);
    logic [3:0] c;
    logic       ra, wa;
    if (attr_hi == 4'b0000) begin
      // Device memory: only nGnRnE is non-bufferable
      c = (attr_lo[3:2] == 2'b00) ? 4'b0000 : 4'b0001;
    end else if (attr_hi == 4'b0100) begin
      c = 4'b0011; // Normal non-cacheable bufferable
    end else begin
      ra = attr_hi[1];
      wa = attr_hi[0];
      if (attr_hi[2] == 1'b0) begin
        // Write-through
        c = is_wr ? {wa, 1'b1, 1'b1, 1'b0} : {1'b1, ra, 1'b1, 1'b0};
      end else begin
        // Write-back
        c = is_wr ? {wa, 1'b1, 1'b1, 1'b1} : {1'b1, ra, 1'b1, 1'b1};
      end
    end
    return c;
  endfunction

  // Inner attribute in the same AxCACHE style encoding (driven on axinner)
  function automatic logic [3:0] memattr_to_inner(input logic [3:0] attr_hi,
                                                  input logic [3:0] attr_lo,
                                                  input logic       is_wr);
    logic [3:0] c;
    if (attr_hi == 4'b0000) c = memattr_to_cache(4'b0000, attr_lo, is_wr);
    else if (attr_lo == 4'b0000) c = 4'b0011; // reserved -> treat as non-cacheable
    else c = memattr_to_cache(attr_lo, 4'b0000, is_wr);
    return c;
  endfunction

  // Shareability -> AxDOMAIN (ACE5-Lite). Device / fully non-cacheable -> System.
  function automatic logic [1:0] share_to_domain(input logic [3:0] attr_hi,
                                                 input logic [3:0] attr_lo,
                                                 input logic [1:0] share);
    logic [1:0] d;
    if (attr_hi == 4'b0000 || (attr_hi == 4'b0100 && attr_lo == 4'b0100)) d = 2'b11;
    else begin
      case (share)
        2'b00:   d = 2'b00; // non-shareable
        2'b10:   d = 2'b10; // outer shareable
        2'b11:   d = 2'b01; // inner shareable
        default: d = 2'b00;
      endcase
    end
    return d;
  endfunction

  function automatic logic [5:0] popcount32(input logic [31:0] v);
    logic [5:0] c;
    c = '0;
    for (int i = 0; i < 32; i++) c = c + v[i];
    return c;
  endfunction

endpackage : dma_pkg
