// SPDX-License-Identifier: CERN-OHL-S-2.0
/*

Copyright (c) 2018-2025 FPGA Ninja, LLC

Authors:
- Alex Forencich

*/

`resetall
`timescale 1ns / 1ps
`default_nettype none

/*
 * XGMII 10GBASE-R decoder
 */
module taxi_xgmii_baser_dec_64 #
(
    parameter DATA_W = 64,
    parameter CTRL_W = (DATA_W/8),
    parameter HDR_W = 2
)
(
    input  wire logic              clk,
    input  wire logic              rst,

    /*
     * 10GBASE-R encoded input
     */
    input  wire logic [DATA_W-1:0] encoded_rx_data,
    input  wire logic [HDR_W-1:0]  encoded_rx_hdr,

    /*
     * XGMII interface
     */
    output wire logic [DATA_W-1:0] xgmii_rxd,
    output wire logic [CTRL_W-1:0] xgmii_rxc,

    /*
     * Status
     */
    output wire logic              rx_bad_block,
    output wire logic              rx_sequence_error
);

// check configuration
if (DATA_W != 64)
    $fatal(0, "Error: Interface width must be 64");

if (CTRL_W * 8 != DATA_W)
    $fatal(0, "Error: Interface requires byte (8-bit) granularity");

if (HDR_W != 2)
    $fatal(0, "Error: HDR_W must be 2");

localparam [7:0]
    XGMII_IDLE   = 8'h07,
    XGMII_LPI    = 8'h06,
    XGMII_START  = 8'hfb,
    XGMII_TERM   = 8'hfd,
    XGMII_ERROR  = 8'hfe,
    XGMII_SEQ_OS = 8'h9c,
    XGMII_RES_0  = 8'h1c,
    XGMII_RES_1  = 8'h3c,
    XGMII_RES_2  = 8'h7c,
    XGMII_RES_3  = 8'hbc,
    XGMII_RES_4  = 8'hdc,
    XGMII_RES_5  = 8'hf7,
    XGMII_SIG_OS = 8'h5c;

localparam [6:0]
    CTRL_IDLE  = 7'h00,
    CTRL_LPI   = 7'h06,
    CTRL_ERROR = 7'h1e,
    CTRL_RES_0 = 7'h2d,
    CTRL_RES_1 = 7'h33,
    CTRL_RES_2 = 7'h4b,
    CTRL_RES_3 = 7'h55,
    CTRL_RES_4 = 7'h66,
    CTRL_RES_5 = 7'h78;

localparam [3:0]
    O_SEQ_OS = 4'h0,
    O_SIG_OS = 4'hf;

localparam [1:0]
    SYNC_DATA = 2'b10,
    SYNC_CTRL = 2'b01;

localparam [7:0]
    BLOCK_TYPE_CTRL     = 8'h1e, // C7 C6 C5 C4 C3 C2 C1 C0 BT
    BLOCK_TYPE_OS_4     = 8'h2d, // D7 D6 D5 O4 C3 C2 C1 C0 BT
    BLOCK_TYPE_START_4  = 8'h33, // D7 D6 D5    C3 C2 C1 C0 BT
    BLOCK_TYPE_OS_START = 8'h66, // D7 D6 D5    O0 D3 D2 D1 BT
    BLOCK_TYPE_OS_04    = 8'h55, // D7 D6 D5 O4 O0 D3 D2 D1 BT
    BLOCK_TYPE_START_0  = 8'h78, // D7 D6 D5 D4 D3 D2 D1    BT
    BLOCK_TYPE_OS_0     = 8'h4b, // C7 C6 C5 C4 O0 D3 D2 D1 BT
    BLOCK_TYPE_TERM_0   = 8'h87, // C7 C6 C5 C4 C3 C2 C1    BT
    BLOCK_TYPE_TERM_1   = 8'h99, // C7 C6 C5 C4 C3 C2    D0 BT
    BLOCK_TYPE_TERM_2   = 8'haa, // C7 C6 C5 C4 C3    D1 D0 BT
    BLOCK_TYPE_TERM_3   = 8'hb4, // C7 C6 C5 C4    D2 D1 D0 BT
    BLOCK_TYPE_TERM_4   = 8'hcc, // C7 C6 C5    D3 D2 D1 D0 BT
    BLOCK_TYPE_TERM_5   = 8'hd2, // C7 C6    D4 D3 D2 D1 D0 BT
    BLOCK_TYPE_TERM_6   = 8'he1, // C7    D5 D4 D3 D2 D1 D0 BT
    BLOCK_TYPE_TERM_7   = 8'hff; //    D6 D5 D4 D3 D2 D1 D0 BT

logic [DATA_W-1:0] decoded_ctrl;
logic [CTRL_W-1:0] decode_err;

logic [DATA_W-1:0] xgmii_rxd_reg = '0, xgmii_rxd_next;
logic [CTRL_W-1:0] xgmii_rxc_reg = '0, xgmii_rxc_next;

logic rx_bad_block_reg = 1'b0, rx_bad_block_next;
logic rx_sequence_error_reg = 1'b0, rx_sequence_error_next;
logic frame_reg = 1'b0, frame_next;

assign xgmii_rxd = xgmii_rxd_reg;
assign xgmii_rxc = xgmii_rxc_reg;

assign rx_bad_block = rx_bad_block_reg;
assign rx_sequence_error = rx_sequence_error_reg;

always_comb begin
    xgmii_rxd_next = {8{XGMII_ERROR}};
    xgmii_rxc_next = 8'hff;
    rx_bad_block_next = 1'b0;
    rx_sequence_error_next = 1'b0;
    frame_next = frame_reg;

    for (integer i = 0; i < CTRL_W; i = i + 1) begin
        case (encoded_rx_data[7*i+8 +: 7])
            CTRL_IDLE: begin
                decoded_ctrl[8*i +: 8] = XGMII_IDLE;
                decode_err[i] = 1'b0;
            end
            CTRL_LPI: begin
                decoded_ctrl[8*i +: 8] = XGMII_LPI;
                decode_err[i] = 1'b0;
            end
            CTRL_ERROR: begin
                decoded_ctrl[8*i +: 8] = XGMII_ERROR;
                decode_err[i] = 1'b0;
            end
            CTRL_RES_0: begin
                decoded_ctrl[8*i +: 8] = XGMII_RES_0;
                decode_err[i] = 1'b0;
            end
            CTRL_RES_1: begin
                decoded_ctrl[8*i +: 8] = XGMII_RES_1;
                decode_err[i] = 1'b0;
            end
            CTRL_RES_2: begin
                decoded_ctrl[8*i +: 8] = XGMII_RES_2;
                decode_err[i] = 1'b0;
            end
            CTRL_RES_3: begin
                decoded_ctrl[8*i +: 8] = XGMII_RES_3;
                decode_err[i] = 1'b0;
            end
            CTRL_RES_4: begin
                decoded_ctrl[8*i +: 8] = XGMII_RES_4;
                decode_err[i] = 1'b0;
            end
            CTRL_RES_5: begin
                decoded_ctrl[8*i +: 8] = XGMII_RES_5;
                decode_err[i] = 1'b0;
            end
            default: begin
                decoded_ctrl[8*i +: 8] = XGMII_ERROR;
                decode_err[i] = 1'b1;
            end
        endcase
    end

    // use only four bits of block type for reduced fanin
    if (encoded_rx_hdr[0] == 0) begin
        xgmii_rxd_next = encoded_rx_data;
        xgmii_rxc_next = 8'h00;
        rx_bad_block_next = 1'b0;
    end else begin
        case (encoded_rx_data[7:4])
            BLOCK_TYPE_CTRL[7:4]: begin
                // C7 C6 C5 C4 C3 C2 C1 C0 BT
                xgmii_rxd_next = decoded_ctrl;
                xgmii_rxc_next = 8'hff;
                rx_bad_block_next = decode_err != 0;
            end
            BLOCK_TYPE_OS_4[7:4]: begin
                // D7 D6 D5 O4 C3 C2 C1 C0 BT
                xgmii_rxd_next[31:0] = decoded_ctrl[31:0];
                xgmii_rxc_next[3:0] = 4'hf;
                xgmii_rxd_next[63:40] = encoded_rx_data[63:40];
                xgmii_rxc_next[7:4] = 4'h1;
                if (encoded_rx_data[39:36] == O_SEQ_OS) begin
                    xgmii_rxd_next[39:32] = XGMII_SEQ_OS;
                    rx_bad_block_next = decode_err[3:0] != 0;
                end else begin
                    xgmii_rxd_next[39:32] = XGMII_ERROR;
                    rx_bad_block_next = 1'b1;
                end
            end
            BLOCK_TYPE_START_4[7:4]: begin
                // D7 D6 D5    C3 C2 C1 C0 BT
                xgmii_rxd_next = {encoded_rx_data[63:40], XGMII_START, decoded_ctrl[31:0]};
                xgmii_rxc_next = 8'h1f;
                rx_bad_block_next = decode_err[3:0] != 0;
                rx_sequence_error_next = frame_reg;
                frame_next = 1'b1;
            end
            BLOCK_TYPE_OS_START[7:4]: begin
                // D7 D6 D5    O0 D3 D2 D1 BT
                xgmii_rxd_next[31:8] = encoded_rx_data[31:8];
                xgmii_rxc_next[3:0] = 4'hf;
                if (encoded_rx_data[35:32] == O_SEQ_OS) begin
                    xgmii_rxd_next[7:0] = XGMII_SEQ_OS;
                    rx_bad_block_next = 1'b0;
                end else begin
                    xgmii_rxd_next[7:0] = XGMII_ERROR;
                    rx_bad_block_next = 1'b1;
                end
                xgmii_rxd_next[63:32] = {encoded_rx_data[63:40], XGMII_START};
                xgmii_rxc_next[7:4] = 4'h1;
                rx_sequence_error_next = frame_reg;
                frame_next = 1'b1;
            end
            BLOCK_TYPE_OS_04[7:4]: begin
                // D7 D6 D5 O4 O0 D3 D2 D1 BT
                rx_bad_block_next = 1'b0;
                xgmii_rxd_next[31:8] = encoded_rx_data[31:8];
                xgmii_rxc_next[3:0] = 4'h1;
                if (encoded_rx_data[35:32] == O_SEQ_OS) begin
                    xgmii_rxd_next[7:0] = XGMII_SEQ_OS;
                end else begin
                    xgmii_rxd_next[7:0] = XGMII_ERROR;
                    rx_bad_block_next = 1'b1;
                end
                xgmii_rxd_next[63:40] = encoded_rx_data[63:40];
                xgmii_rxc_next[7:4] = 4'h1;
                if (encoded_rx_data[39:36] == O_SEQ_OS) begin
                    xgmii_rxd_next[39:32] = XGMII_SEQ_OS;
                end else begin
                    xgmii_rxd_next[39:32] = XGMII_ERROR;
                    rx_bad_block_next = 1'b1;
                end
            end
            BLOCK_TYPE_START_0[7:4]: begin
                // D7 D6 D5 D4 D3 D2 D1    BT
                xgmii_rxd_next = {encoded_rx_data[63:8], XGMII_START};
                xgmii_rxc_next = 8'h01;
                rx_bad_block_next = 1'b0;
                rx_sequence_error_next = frame_reg;
                frame_next = 1'b1;
            end
            BLOCK_TYPE_OS_0[7:4]: begin
                // C7 C6 C5 C4 O0 D3 D2 D1 BT
                xgmii_rxd_next[31:8] = encoded_rx_data[31:8];
                xgmii_rxc_next[3:0] = 4'h1;
                if (encoded_rx_data[35:32] == O_SEQ_OS) begin
                    xgmii_rxd_next[7:0] = XGMII_SEQ_OS;
                    rx_bad_block_next = decode_err[7:4] != 0;
                end else begin
                    xgmii_rxd_next[7:0] = XGMII_ERROR;
                    rx_bad_block_next = 1'b1;
                end
                xgmii_rxd_next[63:32] = decoded_ctrl[63:32];
                xgmii_rxc_next[7:4] = 4'hf;
            end
            BLOCK_TYPE_TERM_0[7:4]: begin
                // C7 C6 C5 C4 C3 C2 C1    BT
                xgmii_rxd_next = {decoded_ctrl[63:8], XGMII_TERM};
                xgmii_rxc_next = 8'hff;
                rx_bad_block_next = decode_err[7:1] != 0;
                rx_sequence_error_next = !frame_reg;
                frame_next = 1'b0;
            end
            BLOCK_TYPE_TERM_1[7:4]: begin
                // C7 C6 C5 C4 C3 C2    D0 BT
                xgmii_rxd_next = {decoded_ctrl[63:16], XGMII_TERM, encoded_rx_data[15:8]};
                xgmii_rxc_next = 8'hfe;
                rx_bad_block_next = decode_err[7:2] != 0;
                rx_sequence_error_next = !frame_reg;
                frame_next = 1'b0;
            end
            BLOCK_TYPE_TERM_2[7:4]: begin
                // C7 C6 C5 C4 C3    D1 D0 BT
                xgmii_rxd_next = {decoded_ctrl[63:24], XGMII_TERM, encoded_rx_data[23:8]};
                xgmii_rxc_next = 8'hfc;
                rx_bad_block_next = decode_err[7:3] != 0;
                rx_sequence_error_next = !frame_reg;
                frame_next = 1'b0;
            end
            BLOCK_TYPE_TERM_3[7:4]: begin
                // C7 C6 C5 C4    D2 D1 D0 BT
                xgmii_rxd_next = {decoded_ctrl[63:32], XGMII_TERM, encoded_rx_data[31:8]};
                xgmii_rxc_next = 8'hf8;
                rx_bad_block_next = decode_err[7:4] != 0;
                rx_sequence_error_next = !frame_reg;
                frame_next = 1'b0;
            end
            BLOCK_TYPE_TERM_4[7:4]: begin
                // C7 C6 C5    D3 D2 D1 D0 BT
                xgmii_rxd_next = {decoded_ctrl[63:40], XGMII_TERM, encoded_rx_data[39:8]};
                xgmii_rxc_next = 8'hf0;
                rx_bad_block_next = decode_err[7:5] != 0;
                rx_sequence_error_next = !frame_reg;
                frame_next = 1'b0;
            end
            BLOCK_TYPE_TERM_5[7:4]: begin
                // C7 C6    D4 D3 D2 D1 D0 BT
                xgmii_rxd_next = {decoded_ctrl[63:48], XGMII_TERM, encoded_rx_data[47:8]};
                xgmii_rxc_next = 8'he0;
                rx_bad_block_next = decode_err[7:6] != 0;
                rx_sequence_error_next = !frame_reg;
                frame_next = 1'b0;
            end
            BLOCK_TYPE_TERM_6[7:4]: begin
                // C7    D5 D4 D3 D2 D1 D0 BT
                xgmii_rxd_next = {decoded_ctrl[63:56], XGMII_TERM, encoded_rx_data[55:8]};
                xgmii_rxc_next = 8'hc0;
                rx_bad_block_next = decode_err[7] != 0;
                rx_sequence_error_next = !frame_reg;
                frame_next = 1'b0;
            end
            BLOCK_TYPE_TERM_7[7:4]: begin
                //    D6 D5 D4 D3 D2 D1 D0 BT
                xgmii_rxd_next = {XGMII_TERM, encoded_rx_data[63:8]};
                xgmii_rxc_next = 8'h80;
                rx_bad_block_next = 1'b0;
                rx_sequence_error_next = !frame_reg;
                frame_next = 1'b0;
            end
            default: begin
                // invalid block type
                xgmii_rxd_next = {8{XGMII_ERROR}};
                xgmii_rxc_next = 8'hff;
                rx_bad_block_next = 1'b1;
            end
        endcase
    end

    // check all block type bits to detect bad encodings
    if (encoded_rx_hdr == SYNC_DATA) begin
        // data - nothing encoded
    end else if (encoded_rx_hdr == SYNC_CTRL) begin
        // control - check for bad block types
        case (encoded_rx_data[7:0])
            BLOCK_TYPE_CTRL: begin end
            BLOCK_TYPE_OS_4: begin end
            BLOCK_TYPE_START_4: begin end
            BLOCK_TYPE_OS_START: begin end
            BLOCK_TYPE_OS_04: begin end
            BLOCK_TYPE_START_0: begin end
            BLOCK_TYPE_OS_0: begin end
            BLOCK_TYPE_TERM_0: begin end
            BLOCK_TYPE_TERM_1: begin end
            BLOCK_TYPE_TERM_2: begin end
            BLOCK_TYPE_TERM_3: begin end
            BLOCK_TYPE_TERM_4: begin end
            BLOCK_TYPE_TERM_5: begin end
            BLOCK_TYPE_TERM_6: begin end
            BLOCK_TYPE_TERM_7: begin end
            default: begin
                // invalid block type
                xgmii_rxd_next = {8{XGMII_ERROR}};
                xgmii_rxc_next = 8'hff;
                rx_bad_block_next = 1'b1;
            end
        endcase
    end else begin
        // invalid header
        xgmii_rxd_next = {8{XGMII_ERROR}};
        xgmii_rxc_next = 8'hff;
        rx_bad_block_next = 1'b1;
    end
end

always_ff @(posedge clk) begin
    xgmii_rxd_reg <= xgmii_rxd_next;
    xgmii_rxc_reg <= xgmii_rxc_next;

    rx_bad_block_reg <= rx_bad_block_next;
    rx_sequence_error_reg <= rx_sequence_error_next;
    frame_reg <= frame_next;

    if (rst) begin
        frame_reg <= 1'b0;
    end
end

endmodule

`resetall
