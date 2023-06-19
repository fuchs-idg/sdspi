////////////////////////////////////////////////////////////////////////////////
//
// Filename: 	sdio.v
// {{{
// Project:	SDIO SD-Card controller, using a shared SPI interface
//
// Purpose:	
//
// Creator:	Dan Gisselquist, Ph.D.
//		Gisselquist Technology, LLC
//
////////////////////////////////////////////////////////////////////////////////
// }}}
// Copyright (C) 2018-2023, Gisselquist Technology, LLC
// {{{
// This program is free software (firmware): you can redistribute it and/or
// modify it under the terms of  the GNU General Public License as published
// by the Free Software Foundation, either version 3 of the License, or (at
// your option) any later version.
//
// This program is distributed in the hope that it will be useful, but WITHOUT
// ANY WARRANTY; without even the implied warranty of MERCHANTIBILITY or
// FITNESS FOR A PARTICULAR PURPOSE.  See the GNU General Public License
// for more details.
//
// You should have received a copy of the GNU General Public License along
// with this program.  (It's in the $(ROOT)/doc directory.  Run make with no
// target there if the PDF file isn't present.)  If not, see
// <http://www.gnu.org/licenses/> for a copy.
// }}}
// License:	GPL, v3, as defined and found on www.gnu.org,
// {{{
//		http://www.gnu.org/licenses/gpl.html
//
////////////////////////////////////////////////////////////////////////////////
//
`default_nettype	none
// }}}
module	sdio #(
		// {{{
		parameter	LGFIFO = 15,//	= log_2(FIFO size in bytes)
				NUMIO=4,
		parameter	MW = 32,
		// parameter [0:0]	OPT_LITTLE_ENDIAN = 1'b0,
		// The DMA isn't (yet) implemented
		// localparam [0:0]	OPT_DMA = 1'b0,
		// To support more than one bit of IO per clock, we need
		//  serdes support.  Setting OPT_SERDES to zero will disable
		//  that support, effectively limiting our operation to 50MHz
		//  from a 100MHz clock.
		localparam [0:0]	OPT_SERDES = 1'b0,
		parameter	LGTIMEOUT = 6
		// }}}
	) (
		// {{{
		input	wire			i_clk, i_reset,
		// Control (Wishbone) interface
		// {{{
		input	wire		i_wb_cyc, i_wb_stb, i_wb_we,
		input	wire	[2:0]	i_wb_addr,
		input	wire [MW-1:0]	i_wb_data,
		input	wire [MW/8-1:0]	i_wb_sel,
		//
		output	wire		o_wb_stall, o_wb_ack,
		output	wire [MW-1:0]	o_wb_data,
		// }}}
		// Interface to PHY
		// {{{
		// Not these wires--those will be the connections handled by
		// the PHY
		// inout	wire		io_cmd,
		// inout	wire		io_ds,
		// inout wire [NUMIO-1:0]	io_dat,
		// But these ones ...
		output	wire		o_cfg_ddr,
		output	wire	[4:0]	o_cfg_sample_shift,
		output	wire	[7:0]	o_sdclk,
		//
		output	wire		o_cmd_en, o_pp_cmd,
		output	wire	[1:0]	o_cmd_data,
		//
		output	wire		o_data_en, o_pp_data,
		output	wire	[31:0]	o_tx_data,
		output	wire		o_afifo_reset_n,
		//
		input	wire	[1:0]	i_cmd_strb, i_cmd_data,
		input	wire		i_cmd_busy,
		input	wire	[1:0]	i_rx_strb,
		input	wire	[15:0]	i_rx_data,
		//
		input	wire		S_AC_VALID,
		input	wire	[1:0]	S_AC_DATA,
		input	wire		S_AD_VALID,
		input	wire	[31:0]	S_AD_DATA
		// }}}
		// (Future / optional) DMA interface
		// {{{
		/*
		output	wire		o_dma_cyc, o_dma_stb, o_dma_we,
		output	wire	[2:0]	o_dma_addr,
		output	wire [MW-1:0]	o_dma_data,
		output	wire [MW/8-1:0]	o_dma_sel,
		//
		input	wire		i_dma_stall, i_dma_ack,
		input	wire [MW-1:0]	i_dma_data,
		input	wire		i_dma_err
		*/
		// }}}
		// }}}
	);

	// Local declarations
	// {{{
	wire		cfg_clk90, cfg_clk_shutdown, cfg_ds;
	wire	[7:0]	cfg_ckspeed;
	wire	[1:0]	cfg_width;

	wire		clk_stb;

	wire			cmd_request, cmd_err, cmd_busy, cmd_done;
	wire	[1:0]		cmd_type, cmd_ercode;
	wire			rsp_stb;
	wire	[5:0]		cmd_id, rsp_id;
	wire	[31:0]		cmd_arg, rsp_arg;
	wire			cmd_mem_valid;
	wire	[MW/8-1:0]	cmd_mem_strb;
	wire	[LGFIFO-$clog2(MW/8)-1:0]	cmd_mem_addr;
	wire	[MW-1:0]	cmd_mem_data;

	wire			tx_en, tx_mem_valid, tx_mem_ready, tx_mem_last;
	wire	[31:0]		tx_mem_data;

	wire			rx_en, crc_en;
	wire	[LGFIFO:0]	rx_length;
	wire			rx_mem_valid;
	wire	[LGFIFO-$clog2(MW/8)-1:0]	rx_mem_addr;
	wire	[MW/8-1:0]	rx_mem_strb;
	wire	[MW-1:0]	rx_mem_data;
	wire			rx_done, rx_err;
	// }}}

	sdwb #(
		// {{{
		.LGFIFO(LGFIFO), .NUMIO(NUMIO),
		.OPT_SERDES(OPT_SERDES),
		// .OPT_LITTLE_ENDIAN(OPT_LITTLE_ENDIAN)
		// .OPT_DMA(OPT_DMA)
		.MW(MW)
		// }}}
	) u_control (
		// {{{
		.i_clk(i_clk), .i_reset(i_reset),
		// Wishbone slave
		// {{{
		.i_wb_cyc(i_wb_cyc), .i_wb_stb(i_wb_stb),
		.i_wb_we(i_wb_we), .i_wb_addr(i_wb_addr),
		.i_wb_data(i_wb_data), .i_wb_sel(i_wb_sel),
		//
		.o_wb_stall(o_wb_stall), .o_wb_ack(o_wb_ack),
			.o_wb_data(o_wb_data),
		// }}}
		// Configuration options
		// {{{
		.o_cfg_clk90(cfg_clk90), .o_cfg_ckspeed(cfg_ckspeed),
		.o_cfg_shutdown(cfg_clk_shutdown),
		.o_cfg_width(cfg_width), .o_cfg_ds(cfg_ds),
			.o_cfg_ddr(o_cfg_ddr),
		.o_pp_cmd(o_pp_cmd), .o_pp_data(o_pp_data),
		.o_cfg_sample_shift(o_cfg_sample_shift),
		// }}}
		// CMD control interface
		// {{{
		.o_cmd_request(cmd_request), .o_cmd_type(cmd_type),
		.o_cmd_id(cmd_id), .o_arg(cmd_arg),
		//
		.i_cmd_busy(cmd_busy), .i_cmd_done(cmd_done),
			.i_cmd_err(cmd_err), .i_cmd_ercode(cmd_ercode),
		//
		.i_cmd_response(rsp_stb), .i_resp(rsp_id),
			.i_arg(rsp_arg),
		//
		.i_cmd_mem_valid(cmd_mem_valid), .i_cmd_mem_strb(cmd_mem_strb),
			.i_cmd_mem_addr(cmd_mem_addr),
			.i_cmd_mem_data(cmd_mem_data),
		// }}}
		// TX interface
		// {{{
		.o_tx_en(tx_en),
		//
		.o_tx_mem_valid(tx_mem_valid),
			.i_tx_mem_ready(tx_mem_ready && tx_en),
		.o_tx_mem_data(tx_mem_data), .o_tx_mem_last(tx_mem_last),
		// }}}
		// RX interface
		// {{{
		.o_rx_en(rx_en), .o_crc_en(crc_en), .o_length(rx_length),
		//
		.i_rx_mem_valid(rx_mem_valid), .i_rx_mem_strb(rx_mem_strb),
			.i_rx_mem_addr(rx_mem_addr),.i_rx_mem_data(rx_mem_data),
		//
		.i_rx_done(rx_done), .i_rx_err(rx_err)
		// }}}
		// }}}
	);

	sdckgen
	u_clkgen (
		// {{{
		.i_clk(i_clk), .i_reset(i_reset),
		//
		.i_cfg_clk90(cfg_clk90), .i_cfg_ckspd(cfg_ckspeed),
		.i_cfg_shutdown(cfg_clk_shutdown),
	
		.o_ckstb(clk_stb),
		.o_ckwide(o_sdclk)
		// }}}
	);

	sdcmd #(
		.MW(MW),
		.LGLEN(LGFIFO-$clog2(MW/8))
	) u_sdcmd (
		// {{{
		.i_clk(i_clk), .i_reset(i_reset),
		//
		.i_cfg_ds(cfg_ds), .i_cfg_dbl(cfg_ds && cfg_ckspeed == 0),
		.i_ckstb(clk_stb),
		//
		.i_cmd_request(cmd_request), .i_cmd_type(cmd_type),
		.i_cmd(cmd_id), .i_arg(cmd_arg),
		//
		.o_busy(cmd_busy), .o_done(cmd_done), .o_err(cmd_err),
			.o_ercode(cmd_ercode),
		//
		.o_cmd_en(o_cmd_en), .o_cmd_data(o_cmd_data),
		.i_cmd_strb(i_cmd_strb), .i_cmd_data(i_cmd_data),
			.i_dat_busy(i_cmd_busy),
		.S_ASYNC_VALID(S_AC_VALID), .S_ASYNC_DATA(S_AC_DATA),
		//
		.o_cmd_response(rsp_stb), .o_resp(rsp_id),
			.o_arg(rsp_arg),
		//
		.o_mem_valid(cmd_mem_valid), .o_mem_strb(cmd_mem_strb),
			.o_mem_addr(cmd_mem_addr), .o_mem_data(cmd_mem_data)
		// }}}
	);

	sdtxframe #(
		.OPT_SERDES(OPT_SERDES)
		// .MW(MW)
	) u_txframe (
		// {{{
		.i_clk(i_clk), .i_reset(i_reset),
		//
		.i_cfg_spd(cfg_ckspeed),
		.i_cfg_width(cfg_width),
		.i_cfg_ddr(o_cfg_ddr),
		//
		.i_en(tx_en), .i_ckstb(clk_stb),
		//
		.S_VALID(tx_en && tx_mem_valid), .S_READY(tx_mem_ready),
		.S_DATA(tx_mem_data), .S_LAST(tx_mem_last),
		//
		.tx_valid(o_data_en), .tx_ready(1'b1),
		.tx_data(o_tx_data)
		// }}}
	);

	sdrxframe #(
		.LGLEN(LGFIFO),
		.MW(MW),
		.LGTIMEOUT(LGTIMEOUT)
	) u_rxframe (
		// {{{
		.i_clk(i_clk), .i_reset(i_reset),
		//
		.i_cfg_ds(cfg_ds), .i_cfg_width(cfg_width),
		.i_rx_en(rx_en), .i_crc_en(crc_en), .i_length(rx_length),
		//
		.i_rx_strb(i_rx_strb), .i_rx_data(i_rx_data),
		.S_ASYNC_VALID(S_AD_VALID), .S_ASYNC_DATA(S_AD_DATA),
		//
		.o_mem_valid(rx_mem_valid), .o_mem_strb(rx_mem_strb),
			.o_mem_addr(rx_mem_addr), .o_mem_data(rx_mem_data),
		//
		.o_done(rx_done), .o_err(rx_err)
		// }}}
	);

	assign	o_afifo_reset_n = cfg_ds && rx_en;

	//
	// Make verilator happy
	// verilator lint_off UNUSED
	// wire	unused;
	// assign	unused = i_wb_cyc;
	// verilator lint_on  UNUSED
endmodule
