`timescale 1ns/1ps

module dsm_tb;

    localparam SAMPLE_WIDTH = 16;
    localparam WINDOW_BITS  = 8;    // window = 256 samples
    localparam THRESHOLD    = 40;   // crossings/window that trip alert

    reg                            clk;
    reg                            rst_n;
    reg                            sample_valid;
    reg  signed [SAMPLE_WIDTH-1:0] audio_sample;
    reg  [WINDOW_BITS:0]           threshold;
    reg                            clear_alert;

    wire                           alert_flag;
    wire [WINDOW_BITS:0]           crossing_count;
    wire                           window_done;

    integer i;        // outer loop index (phase iteration count)
    integer j;        // internal period counter used only by feed_sample
    reg     sign_state;
    integer errors;

    
    // DUT- device under test
    
    dsm #(
        .SAMPLE_WIDTH(SAMPLE_WIDTH),
        .WINDOW_BITS(WINDOW_BITS)
    ) dut (
        .clk(clk),
        .rst_n(rst_n),
        .sample_valid(sample_valid),
        .audio_sample(audio_sample),
        .threshold(threshold),
        .alert_flag(alert_flag),
        .clear_alert(clear_alert),
        .crossing_count(crossing_count),
        .window_done(window_done)
    );

   
    // Clock: 100MHz simulation clock (audio sample_valid pulses are what matter)

    initial clk = 0;
    always #5 clk = ~clk;

    // Task: feed one sample, toggling sign every 'flip_period' calls
    
    task feed_sample(input integer period);
    begin
        @(negedge clk);
        sample_valid = 1'b1;
        audio_sample = sign_state ? -16'sd100 : 16'sd100;
        @(negedge clk);
        sample_valid = 1'b0;
        j = j + 1;
        if (j % period == 0)
            sign_state = ~sign_state;
    end
    endtask

    initial begin
        $dumpfile("dsm_wave.vcd");
        $dumpvars(0, dsm_tb);

        rst_n        = 0;
        sample_valid = 0;
        audio_sample = 0;
        threshold    = THRESHOLD;
        clear_alert  = 0;
        sign_state   = 0;
        errors       = 0;
        j            = 0;

        repeat (4) @(posedge clk);
        rst_n = 1;
        repeat (2) @(posedge clk);

        
        // Phase 1: "normal audio" - low ZCR
        // flip sign every 20 samples over one full window (256)
        // expected crossings ~= 256/20 ~= 12  (<< threshold 40)
        
        $display("[%0t] Phase 1: feeding NORMAL audio (low ZCR)", $time);
        i = 0;
        for (i = 0; i < 256; i = i + 1)
            feed_sample(20);

        // let evaluate happen
        @(posedge window_done);
        $display("[%0t] Window done. crossing_count=%0d alert_flag=%b (expect alert=0)",
                   $time, crossing_count, alert_flag);
        if (alert_flag !== 1'b0) begin
            errors = errors + 1;
            $display("  ERROR: expected no alert during normal audio phase");
        end

       
        // Phase 2: MOSQUITO-style attack - flip sign every sample
        // expected crossings ~= 255 (>> threshold 40) >  ALERT
        
        $display("[%0t] Phase 2: feeding ATTACK pattern (near-Nyquist toggling)", $time);
        i = 0;
        for (i = 0; i < 256; i = i + 1)
            feed_sample(1);

        // DSM should have latched into S_ALERT partway through this window,
        // freezing further sample counting until cleared -- so we check the
        // alert directly rather than waiting for a window_done that won't
        // come again while ALERT is held.
        repeat (5) @(posedge clk);
        $display("[%0t] crossing_count=%0d alert_flag=%b (expect alert=1)",
                   $time, crossing_count, alert_flag);
        if (alert_flag !== 1'b1) begin
            errors = errors + 1;
            $display("  ERROR: expected ALERT during attack phase");
        end

        
        // Phase 3: clear alert, confirm system resumes monitoring
        
        $display("[%0t] Phase 3: clearing alert", $time);
        @(posedge clk);
        clear_alert <= 1'b1;
        @(posedge clk);
        clear_alert <= 1'b0;

        repeat (5) @(posedge clk);
        if (alert_flag !== 1'b0) begin
            errors = errors + 1;
            $display("  ERROR: alert_flag did not clear");
        end else
            $display("[%0t] Alert cleared successfully, DSM back to monitoring", $time);

        repeat (10) @(posedge clk);

        if (errors == 0)
            $display("\n=== ALL TESTS PASSED ===");
        else
            $display("\n=== %0d TEST(S) FAILED ===", errors);

        $finish;
    end

    // safety timeout
    initial begin
        #360404;
        $display("ERROR: TIMEOUT");
        $finish;
    end

endmodule
