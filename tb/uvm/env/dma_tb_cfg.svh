//-----------------------------------------------------------------------------
// dma_tb_cfg.svh - build configuration constants + register map of the TB.
// The register offsets / fields are written independently from the RTL
// (taken from the TRM) so that RTL decode errors are caught.
//-----------------------------------------------------------------------------
localparam int  TB_NCH    = `DMA_NUM_CH;
localparam int  TB_AW     = `DMA_AW;
localparam int  TB_DW     = `DMA_DW;
localparam int  TB_DWB    = TB_DW / 8;
localparam int  TB_CHIDW  = `DMA_CHID_W;
localparam int  TB_GPOW   = `DMA_GPO_W;
localparam int  TB_NTI    = `DMA_NTI;
localparam int  TB_NTO    = `DMA_NTO;
localparam bit  TB_M1     = `DMA_M1;
localparam bit  TB_SECEXT = `DMA_SECEXT;
localparam logic [7:0] TB_STREAM_MASK = `DMA_STREAM_MASK;
localparam logic [7:0] TB_EXT_MASK    = `DMA_EXT_MASK;
localparam logic [7:0] TB_GPO_MASK    = `DMA_GPO_MASK;
localparam int  TB_FIFO_DEPTH [4]     = '{`DMA_FIFO_D0, `DMA_FIFO_D1, `DMA_FIFO_D2, `DMA_FIFO_D3};

localparam int  TB_GW   = (TB_GPOW > 0) ? TB_GPOW : 1;
localparam int  TB_CHW  = (TB_CHIDW > 0) ? TB_CHIDW : 1;
localparam int  TB_NTIW = (TB_NTI > 0) ? TB_NTI : 1;
localparam int  TB_NTOW = (TB_NTO > 0) ? TB_NTO : 1;

typedef virtual dma_ctrl_if #(TB_NCH, TB_NTIW, TB_NTOW, TB_GW, TB_CHW, TB_AW) dma_ctrl_vif_t;

function automatic int tb_fifo_depth(int ch);
  return TB_FIFO_DEPTH[ch % 4];
endfunction

// address -> manager port (must match rtl/dma_addr_map.sv)
function automatic bit tb_port_of(longint unsigned a);
  return TB_M1 && ((a & 64'hFFFF_FFFF_8000_0000) == 64'h0000_0000_8000_0000);
endfunction

// ------------------------------------------------------------------ frames
localparam int R_SECCFG  = 'h000;
localparam int R_SECCTRL = 'h100;
localparam int R_NSCTRL  = 'h200;
localparam int R_INFO    = 'hF00;
function automatic int R_CH(int n); return 'h1000 + 'h100 * n; endfunction

// channel registers
localparam int CH_CMD          = 'h00;
localparam int CH_STATUS       = 'h04;
localparam int CH_INTREN       = 'h08;
localparam int CH_CTRL         = 'h0C;
localparam int CH_SRCADDR      = 'h10;
localparam int CH_SRCADDRHI    = 'h14;
localparam int CH_DESADDR      = 'h18;
localparam int CH_DESADDRHI    = 'h1C;
localparam int CH_XSIZE        = 'h20;
localparam int CH_XSIZEHI      = 'h24;
localparam int CH_SRCTRANSCFG  = 'h28;
localparam int CH_DESTRANSCFG  = 'h2C;
localparam int CH_XADDRINC     = 'h30;
localparam int CH_YADDRSTRIDE  = 'h34;
localparam int CH_FILLVAL      = 'h38;
localparam int CH_YSIZE        = 'h3C;
localparam int CH_TMPLTCFG     = 'h40;
localparam int CH_SRCTMPLT     = 'h44;
localparam int CH_DESTMPLT     = 'h48;
localparam int CH_SRCTRIGINCFG = 'h4C;
localparam int CH_DESTRIGINCFG = 'h50;
localparam int CH_TRIGOUTCFG   = 'h54;
localparam int CH_GPOEN0       = 'h58;
localparam int CH_GPOVAL0      = 'h60;
localparam int CH_STREAMINTCFG = 'h68;
localparam int CH_LINKATTR     = 'h70;
localparam int CH_AUTOCFG      = 'h74;
localparam int CH_LINKADDR     = 'h78;
localparam int CH_LINKADDRHI   = 'h7C;
localparam int CH_GPOREAD0     = 'h80;
localparam int CH_WRKREGPTR    = 'h88;
localparam int CH_WRKREGVAL    = 'h8C;
localparam int CH_ERRINFO      = 'h90;
localparam int CH_IIDR         = 'hC8;
localparam int CH_AIDR         = 'hCC;
localparam int CH_ISSUECAP     = 'hE8;
localparam int CH_BUILDCFG0    = 'hF8;
localparam int CH_BUILDCFG1    = 'hFC;

// unit frames
localparam int U_CHINTRSTATUS0 = 'h00;
localparam int U_STATUS        = 'h08;
localparam int U_CTRL          = 'h0C;
localparam int U_CHPTR         = 'h14;
localparam int U_CHCFG         = 'h18;
localparam int U_STATUSPTR     = 'hF0;
localparam int U_STATUSVAL     = 'hF4;
localparam int U_SIGNALPTR     = 'hF8;
localparam int U_SIGNALVAL     = 'hFC;
localparam int SCFG_CHSEC0      = 'h00;
localparam int SCFG_TRIGINSEC0  = 'h08;
localparam int SCFG_TRIGOUTSEC0 = 'h28;
localparam int SCFG_CTRL        = 'h40;
localparam int SCFG_INTRSTATUS  = 'h44;

// CH_STATUS bits
localparam int ST_DONE     = 16;
localparam int ST_ERR      = 17;
localparam int ST_DISABLED = 18;
localparam int ST_STOPPED  = 19;
localparam int ST_PAUSED   = 20;
localparam int ST_RESUMEWAIT = 21;
localparam int ST_SRCTRIGWAIT = 24;
localparam int ST_DESTRIGWAIT = 25;
localparam int ST_TRIGOUTWAIT = 26;

// encodings
localparam bit [2:0] T_DISABLE = 3'd0, T_CONTINUE = 3'd1, T_WRAP = 3'd2, T_FILL = 3'd3;
localparam bit [1:0] TT_SW = 2'b00, TT_HW = 2'b10, TT_INT = 2'b11;
localparam bit [1:0] TM_CMD = 2'b00, TM_DMAFC = 2'b10, TM_PERFC = 2'b11;
localparam bit [1:0] RQ_SINGLE = 2'b00, RQ_LSINGLE = 2'b01, RQ_BLOCK = 2'b10, RQ_LBLOCK = 2'b11;
localparam bit [1:0] AK_OKAY = 2'b00, AK_DENY = 2'b01, AK_LOKAY = 2'b10;
localparam bit [1:0] SM_INOUT = 2'b00, SM_OUT = 2'b01, SM_IN = 2'b10;

// APB PPROT helpers: [0] privileged, [1] non-secure
localparam bit [2:0] PROT_S_P  = 3'b001;
localparam bit [2:0] PROT_S_U  = 3'b000;
localparam bit [2:0] PROT_NS_P = 3'b011;
localparam bit [2:0] PROT_NS_U = 3'b010;
