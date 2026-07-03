// =============================================================
// AudioGuard - Digital Signature Monitor (DSM)
// -----------------------------------------------------------
// Detects MOSQUITO-style acoustic covert channel activity by
// monitoring the Zero-Crossing Rate (ZCR) of the digital audio
// stream. Legitimate speech/music has bounded, low ZCR.
// Ultrasonic/near-Nyquist modulation used to exfiltrate data
// through speaker hardware produces abnormally high ZCR.
//
// This module counts sign transitions over a fixed sample
// window and flags an alert if the count exceeds a
// configurable threshold. Fully synthesizable, no floating
// point, no FFT.
// =============================================================

module dsm #(
    parameter SAMPLE_WIDTH = 16,           // audio sample bit width (signed)
    parameter WINDOW_BITS  = 8             // window = 2^WINDOW_BITS samples (default 256)
)(
    input  wire                          clk,
    input  wire                          rst_n,

    // Audio stream input
    input  wire                          sample_valid,
    input  wire signed [SAMPLE_WIDTH-1:0] audio_sample,

    // Configuration
    input  wire [WINDOW_BITS:0]          threshold,     // crossings/window that trigger alert

    // Status / alert outputs
    output reg                           alert_flag,     // sticky: high once tripped, cleared by rst or clear_alert
    input  wire                          clear_alert,
    output reg  [WINDOW_BITS:0]          crossing_count, // latched count from last completed window
    output reg                           window_done     // 1-cycle pulse when a window evaluation completes
);

    // ---------------------------------------------------------
    // FSM states
    // ---------------------------------------------------------
    localparam S_IDLE      = 2'd0;
    localparam S_MONITOR   = 2'd1;
    localparam S_EVALUATE  = 2'd2;
    localparam S_ALERT     = 2'd3;

    reg [1:0] state, next_state;
 
    // ---------------------------------------------------------
    // Internal counters
    // ---------------------------------------------------------
    reg signed [SAMPLE_WIDTH-1:0] prev_sample;
    reg                           prev_valid;
    reg [WINDOW_BITS:0]           sample_ctr;   // counts samples in current window
    reg [WINDOW_BITS:0]           cross_ctr;    // counts zero-crossings in current window

    wire window_full = (sample_ctr == ({1'b0,{WINDOW_BITS{1'b1}}})); // sample_ctr == (2^WINDOW_BITS - 1)

    wire sign_curr = audio_sample[SAMPLE_WIDTH-1];
    wire sign_prev = prev_sample[SAMPLE_WIDTH-1];
    wire crossing  = sample_valid & prev_valid & (sign_curr != sign_prev);

    // ---------------------------------------------------------
    // FSM: state register
    // ---------------------------------------------------------
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n)
            state <= S_IDLE;
        else
            state <= next_state;
    end

    // ---------------------------------------------------------
    // FSM: next-state logic
    // ---------------------------------------------------------
    always @(*) begin
        next_state = state;
        case (state)
            S_IDLE:     next_state = sample_valid ? S_MONITOR : S_IDLE;
            S_MONITOR:  next_state = window_full   ? S_EVALUATE : S_MONITOR;
            S_EVALUATE: next_state = (cross_ctr > threshold) ? S_ALERT : S_MONITOR;
            S_ALERT:    next_state = clear_alert ? S_MONITOR : S_ALERT;
            default:    next_state = S_IDLE;
        endcase
    end

    // ---------------------------------------------------------
    // Sample / crossing counters
    // ---------------------------------------------------------
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            sample_ctr  <= 0;
            cross_ctr   <= 0;
            prev_sample <= 0;
            prev_valid  <= 1'b0;
        end else begin
            case (state)
                S_IDLE: begin
                    sample_ctr  <= 0;
                    cross_ctr   <= 0;
                    prev_valid  <= 1'b0;
                end

                S_MONITOR: begin
                    if (sample_valid) begin
                        if (crossing)
                            cross_ctr <= cross_ctr + 1'b1;

                        sample_ctr  <= sample_ctr + 1'b1;
                        prev_sample <= audio_sample;
                        prev_valid  <= 1'b1;
                    end
                end

                S_EVALUATE: begin
                    // window consumed; reset counters for next window
                    // (alert state, if entered, freezes crossing_count via latch below)
                    sample_ctr <= 0;
                    cross_ctr  <= 0;
                end

                S_ALERT: begin
                    // hold state; monitoring resumes once cleared
                    sample_ctr <= 0;
                    cross_ctr  <= 0;
                    prev_valid <= 1'b0;
                end

                default: begin
                    sample_ctr <= 0;
                    cross_ctr  <= 0;
                end
            endcase
        end
    end

    // ---------------------------------------------------------
    // Alert flag (sticky) + latched debug outputs
    // ---------------------------------------------------------
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            alert_flag     <= 1'b0;
            crossing_count <= 0;
            window_done    <= 1'b0;
        end else begin
            window_done <= 1'b0; // default; pulsed below

            if (state == S_EVALUATE) begin
                crossing_count <= cross_ctr;
                window_done    <= 1'b1;
                if (cross_ctr > threshold)
                    alert_flag <= 1'b1;
            end else if (state == S_ALERT && clear_alert) begin
                alert_flag <= 1'b0;
            end
        end
    end

endmodule
