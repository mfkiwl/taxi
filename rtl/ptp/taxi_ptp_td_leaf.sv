// SPDX-License-Identifier: CERN-OHL-S-2.0
/*

Copyright (c) 2023-2025 FPGA Ninja, LLC

Authors:
- Alex Forencich

*/

`resetall
`timescale 1ns / 1fs
`default_nettype none

/*
 * PTP time distribution leaf
 */
module taxi_ptp_td_leaf #
(
    parameter logic TS_REL_EN = 1'b1,
    parameter logic TS_TOD_EN = 1'b1,
    parameter TS_FNS_W = 16,
    parameter TS_REL_NS_W = 48,
    parameter TS_TOD_S_W = 48,
    parameter TS_REL_W = TS_REL_NS_W + TS_FNS_W,
    parameter TS_TOD_W = TS_TOD_S_W + 32 + TS_FNS_W,
    parameter TD_SDI_PIPELINE = 2
)
(
    input  wire logic                 clk,
    input  wire logic                 rst,
    input  wire logic                 sample_clk,

    /*
     * PTP clock interface
     */
    input  wire logic                 ptp_clk,
    input  wire logic                 ptp_rst,
    input  wire logic                 ptp_td_sdi,

    /*
     * Timestamp output
     */
    output wire logic [TS_REL_W-1:0]  output_ts_rel,
    output wire logic                 output_ts_rel_step,
    output wire logic [TS_TOD_W-1:0]  output_ts_tod,
    output wire logic                 output_ts_tod_step,

    /*
     * PPS output (ToD format only)
     */
    output wire logic                 output_pps,
    output wire logic                 output_pps_str,

    /*
     * Status
     */
    output wire logic                 locked
);

localparam SYNC_DELAY = 32-2-TD_SDI_PIPELINE;

localparam TS_NS_W = TS_REL_NS_W < 9 ? 9 : TS_REL_NS_W;
localparam TS_TOD_NS_W = 30;
localparam PERIOD_NS_W = 8;

localparam FNS_W = 16;

localparam CMP_FNS_W = 4;
localparam SRC_FNS_W = CMP_FNS_W+8;

localparam LOG_RATE = 3;

localparam PHASE_CNT_W = LOG_RATE;
localparam PHASE_ACC_W = PHASE_CNT_W+16;
localparam LOAD_CNT_W = 8-LOG_RATE-1;

localparam LOG_SAMPLE_SYNC_RATE = 4;
localparam SAMPLE_ACC_W = LOG_SAMPLE_SYNC_RATE+2;

localparam LOG_PHASE_ERR_RATE = 3;
localparam PHASE_ERR_ACC_W = LOG_PHASE_ERR_RATE+2;

localparam DST_SYNC_LOCK_W = 5;
localparam FREQ_LOCK_W = 5;
localparam PTP_LOCK_W = 8;

localparam TIME_ERR_INT_W = PERIOD_NS_W+FNS_W;

localparam [30:0] NS_PER_S = 31'd1_000_000_000;

// pipeline to facilitate long input path
wire ptp_td_sdi_pipe[0:TD_SDI_PIPELINE];

assign ptp_td_sdi_pipe[0] = ptp_td_sdi;

for (genvar n = 0; n < TD_SDI_PIPELINE; n = n + 1) begin : pipe_stage

    (* shreg_extract = "no" *)
    reg ptp_td_sdi_reg = 0;

    assign ptp_td_sdi_pipe[n+1] = ptp_td_sdi_reg;

    always_ff @(posedge ptp_clk) begin
        ptp_td_sdi_reg <= ptp_td_sdi_pipe[n];
    end

end

// deserialize data
logic [15:0] td_shift_reg = '0;
logic [4:0] bit_cnt_reg = '0;
logic td_valid_reg = 1'b0;
logic [3:0] td_index_reg = '0;
logic [3:0] td_msg_reg = '0;

logic [15:0] td_tdata_reg = '0;
logic td_tvalid_reg = 1'b0;
logic td_tlast_reg = 1'b0;
logic [7:0] td_tid_reg = '0;
logic td_sync_reg = 1'b0;

always_ff @(posedge ptp_clk) begin
    td_shift_reg <= {ptp_td_sdi_pipe[TD_SDI_PIPELINE], td_shift_reg[15:1]};

    td_tvalid_reg <= 1'b0;

    if (bit_cnt_reg != 0) begin
        bit_cnt_reg <= bit_cnt_reg - 1;
    end else begin
        td_valid_reg <= 1'b0;
        if (td_valid_reg) begin
            td_tdata_reg <= td_shift_reg;
            td_tvalid_reg <= 1'b1;
            td_tlast_reg <= ptp_td_sdi_pipe[TD_SDI_PIPELINE];
            td_tid_reg <= {td_msg_reg, td_index_reg};
            if (td_index_reg == 0) begin
                td_msg_reg <= td_shift_reg[3:0];
                td_tid_reg[7:4] <= td_shift_reg[3:0];
            end
            td_index_reg <= td_index_reg + 1;
            td_sync_reg = !td_sync_reg;
        end
        if (ptp_td_sdi_pipe[TD_SDI_PIPELINE] == 0) begin
            bit_cnt_reg <= 16;
            td_valid_reg <= 1'b1;
        end else begin
            td_index_reg <= 0;
        end
    end

    if (ptp_rst) begin
        bit_cnt_reg <= 0;
        td_valid_reg <= 1'b0;

        td_tvalid_reg <= 1'b0;
    end
end

// sync TD data
logic [15:0] dst_td_tdata_reg = '0;
logic dst_td_tvalid_reg = 1'b0;
logic [7:0] dst_td_tid_reg = '0;

(* shreg_extract = "no" *)
logic td_sync_sync1_reg = 1'b0;
(* shreg_extract = "no" *)
logic td_sync_sync2_reg = 1'b0;
(* shreg_extract = "no" *)
logic td_sync_sync3_reg = 1'b0;

always_ff @(posedge clk) begin
    td_sync_sync1_reg <= td_sync_reg;
    td_sync_sync2_reg <= td_sync_sync1_reg;
    td_sync_sync3_reg <= td_sync_sync2_reg;
end

always_ff @(posedge clk) begin
    dst_td_tvalid_reg <= 1'b0;

    if (td_sync_sync3_reg ^ td_sync_sync2_reg) begin
        dst_td_tdata_reg <= td_tdata_reg;
        dst_td_tvalid_reg <= 1'b1;
        dst_td_tid_reg <= td_tid_reg;
    end

    if (rst) begin
        dst_td_tvalid_reg <= 1'b0;
    end
end

// source clock and sync generation
logic [5:0] src_sync_delay_reg = '0;
logic src_load_reg = 1'b0;

logic [PHASE_CNT_W-1:0] src_phase_reg = '0;
logic src_update_reg = 1'b0;
logic src_sync_reg = 1'b0;
logic src_marker_reg = 1'b0;

logic [PERIOD_NS_W+32-1:0] src_period_reg = '0;
logic [PERIOD_NS_W+32-1:0] src_period_shadow_reg = '0;

logic [9+SRC_FNS_W-1:0] src_ns_reg = '0;
logic [9+32-1:0] src_ns_shadow_reg = '0;

always_ff @(posedge ptp_clk) begin
    src_load_reg <= 1'b0;

    {src_update_reg, src_phase_reg} <= src_phase_reg+1;

    if (src_update_reg) begin
        src_ns_reg <= src_ns_reg + (9+SRC_FNS_W)'({src_period_reg, {PHASE_CNT_W{1'b0}}} >> (32-SRC_FNS_W));
        src_sync_reg <= !src_sync_reg;
    end

    // extract data
    if (td_tvalid_reg) begin
        if (td_tid_reg[3:0] == 4'd6) begin
            src_ns_shadow_reg[15:0] <= td_tdata_reg;
        end
        if (td_tid_reg[3:0] == 4'd7) begin
            src_ns_shadow_reg[31:16] <= td_tdata_reg;
        end
        if (td_tid_reg[3:0] == 4'd8) begin
            src_ns_shadow_reg[40:32] <= td_tdata_reg[8:0];
        end
        if (td_tid_reg[3:0] == 4'd11) begin
            src_period_shadow_reg[15:0] <= td_tdata_reg;
        end
        if (td_tid_reg[3:0] == 4'd12) begin
            src_period_shadow_reg[31:16] <= td_tdata_reg;
        end
        if (td_tid_reg[3:0] == 4'd13) begin
            src_period_shadow_reg[39:32] <= td_tdata_reg[7:0];
        end
    end

    if (src_load_reg) begin
        src_ns_reg <= (9+SRC_FNS_W)'(src_ns_shadow_reg >> (32-SRC_FNS_W));
        src_period_reg <= src_period_shadow_reg;
        src_sync_reg <= 1'b1;
        src_marker_reg <= !src_marker_reg;
    end

    if (src_sync_delay_reg == 1) begin
        src_load_reg <= 1'b1;
        src_phase_reg <= 0;
    end

    if (src_sync_delay_reg != 0) begin
        src_sync_delay_reg <= src_sync_delay_reg - 1;
    end

    if (td_tvalid_reg && td_tlast_reg) begin
        src_sync_delay_reg <= 6'(SYNC_DELAY);
    end
end

logic [PERIOD_NS_W+FNS_W-1:0] period_ns_reg = '0, period_ns_next;

logic [9+CMP_FNS_W-1:0] dst_ns_capt_reg = '0;
logic [9+CMP_FNS_W-1:0] src_ns_sync_reg = '0;

logic [FNS_W-1:0] ts_fns_lsb_reg = '0, ts_fns_lsb_next;
logic [FNS_W-1:0] ts_fns_reg = '0, ts_fns_next;

logic [8:0] ts_rel_ns_lsb_reg = '0, ts_rel_ns_lsb_next;
logic [TS_NS_W-1:0] ts_rel_ns_reg = '0, ts_rel_ns_next;
logic ts_rel_step_reg = 1'b0, ts_rel_step_next;

logic [TS_TOD_S_W-1:0] ts_tod_s_reg = '0, ts_tod_s_next;
logic [TS_TOD_NS_W-1:0] ts_tod_ns_reg = '0, ts_tod_ns_next;
logic [8:0] ts_tod_offset_ns_reg = '0, ts_tod_offset_ns_next;
logic ts_tod_step_reg = 1'b0, ts_tod_step_next;

logic pps_reg = 1'b0, pps_next;
logic pps_str_reg = 1'b0, pps_str_next;

logic [PHASE_ACC_W-1:0] dst_phase_reg = '0, dst_phase_next;
logic [PHASE_ACC_W-1:0] dst_phase_inc_reg = '0, dst_phase_inc_next;

logic dst_sync_reg = 1'b0;
logic dst_update_reg = 1'b0, dst_update_next;

(* shreg_extract = "no" *)
logic src_sync_sync1_reg = 1'b0;
(* shreg_extract = "no" *)
logic src_sync_sync2_reg = 1'b0;
(* shreg_extract = "no" *)
logic src_sync_sync3_reg = 1'b0;
(* shreg_extract = "no" *)
logic src_marker_sync1_reg = 1'b0;
(* shreg_extract = "no" *)
logic src_marker_sync2_reg = 1'b0;
(* shreg_extract = "no" *)
logic src_marker_sync3_reg = 1'b0;

(* shreg_extract = "no" *)
logic src_sync_sample_sync1_reg = 1'b0;
(* shreg_extract = "no" *)
logic src_sync_sample_sync2_reg = 1'b0;
(* shreg_extract = "no" *)
logic src_sync_sample_sync3_reg = 1'b0;
(* shreg_extract = "no" *)
logic dst_sync_sample_sync1_reg = 1'b0;
(* shreg_extract = "no" *)
logic dst_sync_sample_sync2_reg = 1'b0;
(* shreg_extract = "no" *)
logic dst_sync_sample_sync3_reg = 1'b0;

logic [SAMPLE_ACC_W-1:0] sample_acc_reg = '0;
logic [SAMPLE_ACC_W-1:0] sample_acc_out_reg = '0;
logic [LOG_SAMPLE_SYNC_RATE-1:0] sample_cnt_reg = '0;
logic sample_update_reg = 1'b0;
logic sample_update_sync1_reg = 1'b0;
logic sample_update_sync2_reg = 1'b0;
logic sample_update_sync3_reg = 1'b0;

// CDC logic
always_ff @(posedge clk) begin
    src_sync_sync1_reg <= src_sync_reg;
    src_sync_sync2_reg <= src_sync_sync1_reg;
    src_sync_sync3_reg <= src_sync_sync2_reg;
    src_marker_sync1_reg <= src_marker_reg;
    src_marker_sync2_reg <= src_marker_sync1_reg;
    src_marker_sync3_reg <= src_marker_sync2_reg;
end

always_ff @(posedge sample_clk) begin
    src_sync_sample_sync1_reg <= src_sync_reg;
    src_sync_sample_sync2_reg <= src_sync_sample_sync1_reg;
    src_sync_sample_sync3_reg <= src_sync_sample_sync2_reg;
    dst_sync_sample_sync1_reg <= dst_sync_reg;
    dst_sync_sample_sync2_reg <= dst_sync_sample_sync1_reg;
    dst_sync_sample_sync3_reg <= dst_sync_sample_sync2_reg;
end

logic edge_1_reg = 1'b0;
logic edge_2_reg = 1'b0;

logic [3:0] active_reg = '0;

always_ff @(posedge sample_clk) begin
    // phase and frequency detector
    if (dst_sync_sample_sync2_reg && !dst_sync_sample_sync3_reg) begin
        if (src_sync_sample_sync2_reg && !src_sync_sample_sync3_reg) begin
            edge_1_reg <= 1'b0;
            edge_2_reg <= 1'b0;
        end else begin
            edge_1_reg <= !edge_2_reg;
            edge_2_reg <= 1'b0;
        end
    end else if (src_sync_sample_sync2_reg && !src_sync_sample_sync3_reg) begin
        edge_1_reg <= 1'b0;
        edge_2_reg <= !edge_1_reg;
    end

    // accumulator
    sample_acc_reg <= $signed(sample_acc_reg) + SAMPLE_ACC_W'($signed({1'b0, edge_2_reg})) - SAMPLE_ACC_W'($signed({1'b0, edge_1_reg}));

    sample_cnt_reg <= sample_cnt_reg + 1;

    if (src_sync_sample_sync2_reg && !src_sync_sample_sync3_reg) begin
        active_reg[0] <= 1'b1;
    end

    if (sample_cnt_reg == 0) begin
        active_reg <= {active_reg[2:0], src_sync_sample_sync2_reg && !src_sync_sample_sync3_reg};
        sample_acc_reg <= SAMPLE_ACC_W'($signed({1'b0, edge_2_reg}) - $signed({1'b0, edge_1_reg}));
        sample_acc_out_reg <= sample_acc_reg;
        if (active_reg != 0) begin
            sample_update_reg <= !sample_update_reg;
        end
    end
end

always_ff @(posedge clk) begin
    sample_update_sync1_reg <= sample_update_reg;
    sample_update_sync2_reg <= sample_update_sync1_reg;
    sample_update_sync3_reg <= sample_update_sync2_reg;
end

logic [SAMPLE_ACC_W-1:0] sample_acc_sync_reg = '0;
logic sample_acc_sync_valid_reg = '0;

logic [PHASE_ACC_W-1:0] dst_err_int_reg = '0, dst_err_int_next;
logic [1:0] dst_ovf;

logic [DST_SYNC_LOCK_W-1:0] dst_sync_lock_count_reg = '0, dst_sync_lock_count_next;
logic dst_sync_locked_reg = 1'b0, dst_sync_locked_next;

logic dst_gain_sel_reg = '0, dst_gain_sel_next;

always_comb begin
    {dst_update_next, dst_phase_next} = dst_phase_reg + dst_phase_inc_reg;
    dst_phase_inc_next = dst_phase_inc_reg;

    dst_err_int_next = dst_err_int_reg;

    dst_sync_lock_count_next = dst_sync_lock_count_reg;
    dst_sync_locked_next = dst_sync_locked_reg;

    dst_gain_sel_next = dst_gain_sel_reg;

    if (sample_acc_sync_valid_reg) begin
        // updated sampled dst_phase error

        // gain scheduling
        casez (sample_acc_sync_reg[SAMPLE_ACC_W-4 +: 4])
            4'b01zz: dst_gain_sel_next = 1'b1;
            4'b001z: dst_gain_sel_next = 1'b1;
            4'b0001: dst_gain_sel_next = 1'b1;
            4'b0000: dst_gain_sel_next = 1'b0;
            4'b1111: dst_gain_sel_next = 1'b0;
            4'b1110: dst_gain_sel_next = 1'b1;
            4'b110z: dst_gain_sel_next = 1'b1;
            4'b10zz: dst_gain_sel_next = 1'b1;
            default: dst_gain_sel_next = 1'b0;
        endcase

        // time integral of error
        case (dst_gain_sel_reg)
            1'd0: {dst_ovf, dst_err_int_next} = $signed({1'b0, dst_err_int_reg}) + (PHASE_ACC_W+2)'($signed(sample_acc_sync_reg));
            1'd1: {dst_ovf, dst_err_int_next} = $signed({1'b0, dst_err_int_reg}) + (PHASE_ACC_W+2)'($signed(sample_acc_sync_reg) * 2**7);
        endcase

        // saturate
        if (dst_ovf[1]) begin
            // sign bit set indicating underflow across zero; saturate to zero
            dst_err_int_next = '0;
        end else if (dst_ovf[0]) begin
            // sign bit clear but carry bit set indicating overflow; saturate to all 1
            dst_err_int_next = '1;
        end

        // compute output
        case (dst_gain_sel_reg)
            1'd0: {dst_ovf, dst_phase_inc_next} = $signed({1'b0, dst_err_int_reg}) + ($signed(sample_acc_sync_reg) * 2**4);
            1'd1: {dst_ovf, dst_phase_inc_next} = $signed({1'b0, dst_err_int_reg}) + ($signed(sample_acc_sync_reg) * 2**11);
        endcase

        // saturate
        if (dst_ovf[1]) begin
            // sign bit set indicating underflow across zero; saturate to zero
            dst_phase_inc_next = '0;
        end else if (dst_ovf[0]) begin
            // sign bit clear but carry bit set indicating overflow; saturate to all 1
            dst_phase_inc_next = '1;
        end

        // locked status
        if (dst_gain_sel_reg == 1'd0) begin
            if (&dst_sync_lock_count_reg) begin
                dst_sync_locked_next = 1'b1;
            end else begin
                dst_sync_lock_count_next = dst_sync_lock_count_reg + 1;
            end
        end else begin
            if (|dst_sync_lock_count_reg) begin
                dst_sync_lock_count_next = dst_sync_lock_count_reg - 1;
            end else begin
                dst_sync_locked_next = 1'b0;
            end
        end
    end
end

logic [LOAD_CNT_W-1:0] dst_load_cnt_reg = '0;

logic [PHASE_ERR_ACC_W-1:0] phase_err_acc_reg = '0;
logic [PHASE_ERR_ACC_W-1:0] phase_err_out_reg = '0;
logic [LOG_PHASE_ERR_RATE-1:0] phase_err_cnt_reg = '0;
logic phase_err_out_valid_reg = '0;

logic phase_last_src_reg = 1'b0;
logic phase_last_dst_reg = 1'b0;
logic phase_edge_1_reg = 1'b0;
logic phase_edge_2_reg = 1'b0;

logic ts_sync_valid_reg = 1'b0;

always_ff @(posedge clk) begin
    dst_phase_reg <= dst_phase_next;
    dst_phase_inc_reg <= dst_phase_inc_next;
    dst_update_reg <= dst_update_next;

    sample_acc_sync_valid_reg <= 1'b0;
    if (sample_update_sync2_reg ^ sample_update_sync3_reg) begin
        // latch in synchronized counts from phase detector
        sample_acc_sync_reg <= sample_acc_out_reg;
        sample_acc_sync_valid_reg <= 1'b1;
    end

    if (dst_update_reg) begin
        // capture local TS
        dst_ns_capt_reg <= (9+CMP_FNS_W)'({ts_rel_ns_reg, ts_fns_reg} >> (FNS_W-CMP_FNS_W));

        dst_sync_reg <= !dst_sync_reg;

        if (dst_sync_reg) begin
            dst_load_cnt_reg <= dst_load_cnt_reg + 1;
        end
    end

    ts_sync_valid_reg <= 1'b0;

    if (src_sync_sync2_reg ^ src_sync_sync3_reg) begin
        // store captured source TS
        src_ns_sync_reg <= (9+CMP_FNS_W)'(src_ns_reg >> (SRC_FNS_W-CMP_FNS_W));

        ts_sync_valid_reg <= 1'b1;
    end

    if (src_marker_sync2_reg ^ src_marker_sync3_reg) begin
        dst_load_cnt_reg <= 0;
    end

    phase_err_out_valid_reg <= 1'b0;
    if (ts_sync_valid_reg) begin
        // coarse phase locking

        // phase and frequency detector
        phase_last_src_reg <= src_ns_sync_reg[8+CMP_FNS_W];
        phase_last_dst_reg <= dst_ns_capt_reg[8+CMP_FNS_W];
        if (dst_ns_capt_reg[8+CMP_FNS_W] && !phase_last_dst_reg) begin
            if (src_ns_sync_reg[8+CMP_FNS_W] && !phase_last_src_reg) begin
                phase_edge_1_reg <= 1'b0;
                phase_edge_2_reg <= 1'b0;
            end else begin
                phase_edge_1_reg <= !phase_edge_2_reg;
                phase_edge_2_reg <= 1'b0;
            end
        end else if (src_ns_sync_reg[8+CMP_FNS_W] && !phase_last_src_reg) begin
            phase_edge_1_reg <= 1'b0;
            phase_edge_2_reg <= !phase_edge_1_reg;
        end

        // accumulator
        phase_err_acc_reg <= $signed(phase_err_acc_reg) + PHASE_ERR_ACC_W'($signed({1'b0, phase_edge_2_reg})) - PHASE_ERR_ACC_W'($signed({1'b0, phase_edge_1_reg}));

        phase_err_cnt_reg <= phase_err_cnt_reg + 1;

        if (phase_err_cnt_reg == 0) begin
            phase_err_acc_reg <= PHASE_ERR_ACC_W'($signed({1'b0, phase_edge_2_reg}) - $signed({1'b0, phase_edge_1_reg}));
            phase_err_out_reg <= phase_err_acc_reg;
            phase_err_out_valid_reg <= 1'b1;
        end
    end

    dst_err_int_reg <= dst_err_int_next;

    dst_sync_lock_count_reg <= dst_sync_lock_count_next;
    dst_sync_locked_reg <= dst_sync_locked_next;

    dst_gain_sel_reg <= dst_gain_sel_next;

    if (rst) begin
        dst_phase_reg <= '0;
        dst_phase_inc_reg <= '0;
        dst_sync_reg <= 1'b0;
        dst_update_reg <= 1'b0;

        dst_err_int_reg <= 0;

        dst_sync_lock_count_reg <= 0;
        dst_sync_locked_reg <= 1'b0;

        ts_sync_valid_reg <= 1'b0;
    end
end

logic dst_rel_step_shadow_reg = 1'b0, dst_rel_step_shadow_next;
logic [47:0] dst_rel_ns_shadow_reg = '0, dst_rel_ns_shadow_next;
logic dst_rel_shadow_valid_reg = '0, dst_rel_shadow_valid_next;

logic dst_tod_step_shadow_reg = 1'b0, dst_tod_step_shadow_next;
logic [29:0] dst_tod_ns_shadow_reg = '0, dst_tod_ns_shadow_next;
logic [47:0] dst_tod_s_shadow_reg = '0, dst_tod_s_shadow_next;
logic dst_tod_shadow_valid_reg = '0, dst_tod_shadow_valid_next;

logic ts_rel_diff_reg = 1'b0, ts_rel_diff_next;
logic ts_rel_diff_valid_reg = 1'b0, ts_rel_diff_valid_next;
logic [1:0] ts_rel_mismatch_cnt_reg = '0, ts_rel_mismatch_cnt_next;
logic ts_rel_load_ts_reg = 1'b0, ts_rel_load_ts_next;

logic ts_tod_diff_reg = 1'b0, ts_tod_diff_next;
logic ts_tod_diff_valid_reg = 1'b0, ts_tod_diff_valid_next;
logic [1:0] ts_tod_mismatch_cnt_reg = '0, ts_tod_mismatch_cnt_next;
logic ts_tod_load_ts_reg = 1'b0, ts_tod_load_ts_next;

logic [9+CMP_FNS_W-1:0] ts_ns_diff_reg = '0, ts_ns_diff_next;
logic ts_ns_diff_valid_reg = 1'b0, ts_ns_diff_valid_next;

logic [TIME_ERR_INT_W-1:0] time_err_int_reg = '0, time_err_int_next;

logic [1:0] ptp_ovf;

logic [FREQ_LOCK_W-1:0] freq_lock_count_reg = '0, freq_lock_count_next;
logic freq_locked_reg = 1'b0, freq_locked_next;
logic [PTP_LOCK_W-1:0] ptp_lock_count_reg = '0, ptp_lock_count_next;
logic ptp_locked_reg = 1'b0, ptp_locked_next;

logic gain_sel_reg = 0, gain_sel_next;

if (TS_REL_EN) begin
    assign output_ts_rel = TS_REL_W'({ts_rel_ns_reg, ts_fns_reg, {TS_FNS_W{1'b0}}} >> FNS_W);
    assign output_ts_rel_step = ts_rel_step_reg;
end else begin
    assign output_ts_rel = '0;
    assign output_ts_rel_step = 1'b0;
end

if (TS_TOD_EN) begin
    assign output_ts_tod = TS_TOD_W'({ts_tod_s_reg, 2'b00, ts_tod_ns_reg, ts_fns_reg, {TS_FNS_W{1'b0}}} >> FNS_W);
    assign output_ts_tod_step = ts_tod_step_reg;

    assign output_pps = pps_reg;
    assign output_pps_str = pps_str_reg;
end else begin
    assign output_ts_tod = '0;
    assign output_ts_tod_step = 0;

    assign output_pps = 1'b0;
    assign output_pps_str = 1'b0;
end

assign locked = ptp_locked_reg && freq_locked_reg && dst_sync_locked_reg;

always_comb begin
    period_ns_next = period_ns_reg;

    ts_fns_lsb_next = ts_fns_lsb_reg;
    ts_fns_next = ts_fns_reg;

    ts_rel_ns_lsb_next = ts_rel_ns_lsb_reg;
    ts_rel_ns_next = ts_rel_ns_reg;
    ts_rel_step_next = 1'b0;

    ts_tod_s_next = ts_tod_s_reg;
    ts_tod_ns_next = ts_tod_ns_reg;
    ts_tod_offset_ns_next = ts_tod_offset_ns_reg;
    ts_tod_step_next = 1'b0;

    dst_rel_step_shadow_next = dst_rel_step_shadow_reg;
    dst_rel_ns_shadow_next = dst_rel_ns_shadow_reg;
    dst_rel_shadow_valid_next = dst_rel_shadow_valid_reg;

    dst_tod_step_shadow_next = dst_tod_step_shadow_reg;
    dst_tod_ns_shadow_next = dst_tod_ns_shadow_reg;
    dst_tod_s_shadow_next = dst_tod_s_shadow_reg;
    dst_tod_shadow_valid_next = dst_tod_shadow_valid_reg;

    ts_rel_diff_next = ts_rel_diff_reg;
    ts_rel_diff_valid_next = 1'b0;
    ts_rel_mismatch_cnt_next = ts_rel_mismatch_cnt_reg;
    ts_rel_load_ts_next = ts_rel_load_ts_reg;

    ts_tod_diff_next = ts_tod_diff_reg;
    ts_tod_diff_valid_next = 1'b0;
    ts_tod_mismatch_cnt_next = ts_tod_mismatch_cnt_reg;
    ts_tod_load_ts_next = ts_tod_load_ts_reg;

    ts_ns_diff_next = ts_ns_diff_reg;
    ts_ns_diff_valid_next = 1'b0;

    time_err_int_next = time_err_int_reg;

    freq_lock_count_next = freq_lock_count_reg;
    freq_locked_next = freq_locked_reg;
    ptp_lock_count_next = ptp_lock_count_reg;
    ptp_locked_next = ptp_locked_reg;

    gain_sel_next = gain_sel_reg;

    pps_next = 1'b0;
    pps_str_next = pps_str_reg;

    // extract data
    if (dst_td_tvalid_reg) begin
        if (TS_TOD_EN) begin
            if (dst_td_tid_reg[3:0] == 4'd1) begin
                // prevent stale data from being used in time sync
                dst_tod_shadow_valid_next = 1'b0;
            end
            if (dst_td_tid_reg == {4'd0, 4'd1}) begin
                dst_tod_ns_shadow_next[15:0] = dst_td_tdata_reg;
                dst_tod_shadow_valid_next = 1'b0;
            end
            if (dst_td_tid_reg == {4'd0, 4'd2}) begin
                dst_tod_ns_shadow_next[29:16] = dst_td_tdata_reg[13:0];
                dst_tod_step_shadow_next = dst_tod_step_shadow_reg | dst_td_tdata_reg[15];
                dst_tod_shadow_valid_next = 1'b0;
            end
            if (dst_td_tid_reg == {4'd0, 4'd3}) begin
                dst_tod_s_shadow_next[15:0] = dst_td_tdata_reg;
                dst_tod_shadow_valid_next = 1'b0;
            end
            if (dst_td_tid_reg == {4'd0, 4'd4}) begin
                dst_tod_s_shadow_next[31:16] = dst_td_tdata_reg;
                dst_tod_shadow_valid_next = 1'b0;
            end
            if (dst_td_tid_reg == {4'd0, 4'd5}) begin
                dst_tod_s_shadow_next[47:32] = dst_td_tdata_reg;
                dst_tod_shadow_valid_next = 1'b1;
            end
            if (dst_td_tid_reg == {4'd1, 4'd1}) begin
                ts_tod_offset_ns_next = dst_td_tdata_reg[8:0];
            end
        end
        if (TS_REL_EN) begin
            if (dst_td_tid_reg[3:0] == 4'd0) begin
                dst_rel_step_shadow_next = dst_rel_step_shadow_reg | dst_td_tdata_reg[8];
            end
            if (dst_td_tid_reg[3:0] == 4'd8) begin
                dst_rel_ns_shadow_next[15:0] = dst_td_tdata_reg;
                dst_rel_shadow_valid_next = 1'b0;
            end
            if (dst_td_tid_reg[3:0] == 4'd9) begin
                dst_rel_ns_shadow_next[31:16] = dst_td_tdata_reg;
                dst_rel_shadow_valid_next = 1'b0;
            end
            if (dst_td_tid_reg[3:0] == 4'd10) begin
                dst_rel_ns_shadow_next[47:32] = dst_td_tdata_reg;
                dst_rel_shadow_valid_next = 1'b1;
            end
        end
    end

    // PTP clock

    // shared fractional ns and relative timestamp least significant bits
    {ts_rel_ns_lsb_next, ts_fns_lsb_next} = ({ts_rel_ns_lsb_reg, ts_fns_lsb_reg} + period_ns_reg);
    ts_fns_next = ts_fns_lsb_reg;

    // relative timestamp
    ts_rel_ns_next[8:0] = ts_rel_ns_lsb_reg;

    if (TS_REL_EN) begin
        if (!ts_rel_ns_next[8] && ts_rel_ns_reg[8]) begin
            ts_rel_ns_next[TS_REL_NS_W-1:9] = ts_rel_ns_reg[TS_REL_NS_W-1:9] + 1;
        end

        if (dst_update_reg && !dst_sync_reg && dst_rel_shadow_valid_reg && (dst_load_cnt_reg == 0)) begin
            // check timestamp MSBs
            if (dst_rel_step_shadow_reg || ts_rel_load_ts_reg) begin
                // input stepped
                ts_rel_ns_next[TS_NS_W-1:9] = dst_rel_ns_shadow_reg[TS_NS_W-1:9];
                ts_rel_step_next = 1'b1;
            end
            ts_rel_diff_next = dst_rel_ns_shadow_reg[TS_NS_W-1:9] != ts_rel_ns_reg[TS_NS_W-1:9];

            ts_rel_load_ts_next = 1'b0;
            dst_rel_shadow_valid_next = 1'b0;
            dst_rel_step_shadow_next = 1'b0;
            ts_rel_diff_valid_next = 1'b1;
        end

        if (ts_rel_diff_valid_reg) begin
            if (ts_rel_diff_reg) begin
                if (&ts_rel_mismatch_cnt_reg) begin
                    ts_rel_load_ts_next = 1'b1;
                    ts_rel_mismatch_cnt_next = 0;
                end else begin
                    ts_rel_mismatch_cnt_next = ts_rel_mismatch_cnt_reg + 1;
                end
            end else begin
                ts_rel_mismatch_cnt_next = 0;
            end
        end
    end

    // absolute time-of-day timestamp
    if (TS_TOD_EN) begin
        ts_tod_ns_next[8:0] = ts_rel_ns_lsb_reg + ts_tod_offset_ns_reg;

        if (ts_tod_ns_reg[TS_TOD_NS_W-1]) begin
            pps_str_next = 1'b0;
        end

        if (!ts_tod_ns_next[8] && ts_tod_ns_reg[8]) begin
            if (ts_tod_ns_reg >> 9 == 30'(NS_PER_S-1) >> 9) begin
                ts_tod_ns_next[TS_TOD_NS_W-1:9] = 0;
                ts_tod_s_next = ts_tod_s_reg + 1;
                pps_next = 1'b1;
                pps_str_next = 1'b1;
            end else begin
                ts_tod_ns_next[TS_TOD_NS_W-1:9] = ts_tod_ns_reg[TS_TOD_NS_W-1:9] + 1;
            end
        end

        if (dst_update_reg && !dst_sync_reg && dst_tod_shadow_valid_reg && (dst_load_cnt_reg == 0)) begin
            // check timestamp MSBs
            if (dst_tod_step_shadow_reg || ts_tod_load_ts_reg) begin
                // input stepped
                ts_tod_s_next = dst_tod_s_shadow_reg;
                ts_tod_ns_next[TS_TOD_NS_W-1:9] = dst_tod_ns_shadow_reg[TS_TOD_NS_W-1:9];
                ts_tod_step_next = 1'b1;
            end
            ts_tod_diff_next = dst_tod_s_shadow_reg != ts_tod_s_reg || dst_tod_ns_shadow_reg[TS_TOD_NS_W-1:9] != ts_tod_ns_reg[TS_TOD_NS_W-1:9];

            ts_tod_load_ts_next = 1'b0;
            dst_tod_shadow_valid_next = 1'b0;
            dst_tod_step_shadow_next = 1'b0;
            ts_tod_diff_valid_next = 1'b1;
        end

        if (ts_tod_diff_valid_reg) begin
            if (ts_tod_diff_reg) begin
                if (&ts_tod_mismatch_cnt_reg) begin
                    ts_tod_load_ts_next = 1'b1;
                    ts_tod_mismatch_cnt_next = 0;
                end else begin
                    ts_tod_mismatch_cnt_next = ts_tod_mismatch_cnt_reg + 1;
                end
            end else begin
                ts_tod_mismatch_cnt_next = 0;
            end
        end
    end

    if (ts_sync_valid_reg) begin
        // compute difference
        ts_ns_diff_valid_next = freq_locked_reg;
        ts_ns_diff_next = src_ns_sync_reg - dst_ns_capt_reg;
    end

    if (phase_err_out_valid_reg) begin
        // coarse phase/frequency lock of PTP clock
        if ($signed(phase_err_out_reg) > 4 || $signed(phase_err_out_reg) < -4) begin
            if (freq_lock_count_reg != 0) begin
                freq_lock_count_next = freq_lock_count_reg - 1;
            end else begin
                freq_locked_next = 1'b0;
            end
        end else begin
            if (&freq_lock_count_reg) begin
                freq_locked_next = 1'b1;
            end else begin
                freq_lock_count_next = freq_lock_count_reg + 1;
            end
        end

        if (!freq_locked_reg) begin
            ts_ns_diff_next = $signed(phase_err_out_reg) * 16 * 2**CMP_FNS_W;
            ts_ns_diff_valid_next = 1'b1;
        end
    end

    if (ts_ns_diff_valid_reg) begin
        // PI control

        // gain scheduling
        casez (ts_ns_diff_reg[9+CMP_FNS_W-5 +: 5])
            5'b01zzz: gain_sel_next = 1'b1;
            5'b001zz: gain_sel_next = 1'b1;
            5'b0001z: gain_sel_next = 1'b1;
            5'b00001: gain_sel_next = 1'b1;
            5'b00000: gain_sel_next = 1'b0;
            5'b11111: gain_sel_next = 1'b0;
            5'b11110: gain_sel_next = 1'b1;
            5'b1110z: gain_sel_next = 1'b1;
            5'b110zz: gain_sel_next = 1'b1;
            5'b10zzz: gain_sel_next = 1'b1;
            default: gain_sel_next = 1'b0;
        endcase

        // time integral of error
        case (gain_sel_reg)
            1'b0: {ptp_ovf, time_err_int_next} = $signed({1'b0, time_err_int_reg}) + (TIME_ERR_INT_W+2)'($signed(ts_ns_diff_reg) / 2**4);
            1'b1: {ptp_ovf, time_err_int_next} = $signed({1'b0, time_err_int_reg}) + (TIME_ERR_INT_W+2)'($signed(ts_ns_diff_reg) * 2**2);
        endcase

        // saturate
        if (ptp_ovf[1]) begin
            // sign bit set indicating underflow across zero; saturate to zero
            time_err_int_next = '0;
        end else if (ptp_ovf[0]) begin
            // sign bit clear but carry bit set indicating overflow; saturate to all 1
            time_err_int_next = '1;
        end

        // compute output
        case (gain_sel_reg)
            1'b0: {ptp_ovf, period_ns_next} = $signed({1'b0, time_err_int_reg}) + ($signed(ts_ns_diff_reg) * 2**2);
            1'b1: {ptp_ovf, period_ns_next} = $signed({1'b0, time_err_int_reg}) + ($signed(ts_ns_diff_reg) * 2**6);
        endcase

        // saturate
        if (ptp_ovf[1]) begin
            // sign bit set indicating underflow across zero; saturate to zero
            period_ns_next = '0;
        end else if (ptp_ovf[0]) begin
            // sign bit clear but carry bit set indicating overflow; saturate to all 1
            period_ns_next = '1;
        end

        // adjust period if integrator is saturated
        if (time_err_int_reg == 0) begin
            period_ns_next = '0;
        end else if (~time_err_int_reg == 0) begin
            period_ns_next = '1;
        end

        // locked status
        if (!freq_locked_reg) begin
            ptp_lock_count_next = 0;
            ptp_locked_next = 1'b0;
        end else if (gain_sel_reg == 1'b0) begin
            if (&ptp_lock_count_reg) begin
                ptp_locked_next = 1'b1;
            end else begin
                ptp_lock_count_next = ptp_lock_count_reg + 1;
            end
        end else begin
            if (ptp_lock_count_reg != 0) begin
                ptp_lock_count_next = ptp_lock_count_reg - 1;
            end else begin
                ptp_locked_next = 1'b0;
            end
        end
    end
end

always_ff @(posedge clk) begin
    period_ns_reg <= period_ns_next;

    ts_fns_lsb_reg <= ts_fns_lsb_next;
    ts_fns_reg <= ts_fns_next;

    ts_rel_ns_lsb_reg <= ts_rel_ns_lsb_next;
    ts_rel_ns_reg <= ts_rel_ns_next;
    ts_rel_step_reg <= ts_rel_step_next;

    ts_tod_s_reg <= ts_tod_s_next;
    ts_tod_ns_reg <= ts_tod_ns_next;
    ts_tod_offset_ns_reg <= ts_tod_offset_ns_next;
    ts_tod_step_reg <= ts_tod_step_next;

    dst_rel_step_shadow_reg <= dst_rel_step_shadow_next;
    dst_rel_ns_shadow_reg <= dst_rel_ns_shadow_next;
    dst_rel_shadow_valid_reg <= dst_rel_shadow_valid_next;

    dst_tod_step_shadow_reg <= dst_tod_step_shadow_next;
    dst_tod_ns_shadow_reg <= dst_tod_ns_shadow_next;
    dst_tod_s_shadow_reg <= dst_tod_s_shadow_next;
    dst_tod_shadow_valid_reg <= dst_tod_shadow_valid_next;

    ts_rel_diff_reg <= ts_rel_diff_next;
    ts_rel_diff_valid_reg <= ts_rel_diff_valid_next;
    ts_rel_mismatch_cnt_reg <= ts_rel_mismatch_cnt_next;
    ts_rel_load_ts_reg <= ts_rel_load_ts_next;

    ts_tod_diff_reg <= ts_tod_diff_next;
    ts_tod_diff_valid_reg <= ts_tod_diff_valid_next;
    ts_tod_mismatch_cnt_reg <= ts_tod_mismatch_cnt_next;
    ts_tod_load_ts_reg <= ts_tod_load_ts_next;

    ts_ns_diff_reg <= ts_ns_diff_next;
    ts_ns_diff_valid_reg <= ts_ns_diff_valid_next;

    time_err_int_reg <= time_err_int_next;

    freq_lock_count_reg <= freq_lock_count_next;
    freq_locked_reg <= freq_locked_next;
    ptp_lock_count_reg <= ptp_lock_count_next;
    ptp_locked_reg <= ptp_locked_next;

    gain_sel_reg <= gain_sel_next;

    pps_reg <= pps_next;
    pps_str_reg <= pps_str_next;

    if (rst) begin
        period_ns_reg <= '0;
        ts_fns_lsb_reg <= '0;
        ts_fns_reg <= '0;
        ts_rel_ns_lsb_reg <= '0;
        ts_rel_ns_reg <= '0;
        ts_rel_step_reg <= 1'b0;
        ts_tod_s_reg <= '0;
        ts_tod_ns_reg <= '0;
        ts_tod_step_reg <= 1'b0;
        dst_rel_shadow_valid_reg <= 1'b0;
        pps_reg <= 1'b0;
        pps_str_reg <= 1'b0;

        ts_rel_diff_reg <= 1'b0;
        ts_rel_diff_valid_reg <= 1'b0;
        ts_rel_mismatch_cnt_reg <= '0;
        ts_rel_load_ts_reg <= '0;

        ts_tod_diff_reg <= 1'b0;
        ts_tod_diff_valid_reg <= 1'b0;
        ts_tod_mismatch_cnt_reg <= '0;
        ts_tod_load_ts_reg <= '0;

        ts_ns_diff_valid_reg <= 1'b0;

        time_err_int_reg <= '0;

        freq_lock_count_reg <= '0;
        freq_locked_reg <= 1'b0;
        ptp_lock_count_reg <= '0;
        ptp_locked_reg <= 1'b0;
    end
end

endmodule

`resetall
