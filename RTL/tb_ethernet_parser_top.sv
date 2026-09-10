//minimal testbench to check parser pipeline
`default_nettype none

module tb_ethernet_parser_top;
    import itch_package::*;

    logic clk, rst_n;
    logic [7:0] s_tdata;
    logic s_tvalid, s_tlast;
    logic s_tready;

    itch_msg_t msg_out;
    logic fifo_full_latched;

    ethernet_parser_top dut (
        .clk(clk), 
        .rst_n(rst_n),
        .s_tdata(s_tdata),
        .s_tvalid(s_tvalid),
        .s_tlast(s_tlast),
        .s_tready(s_tready),
        .msg_out(msg_out),
        .fifo_full_latched(fifo_full_latched)
    );

    initial begin
        clk = 0;
        forever #5 clk = ~clk;
    end

    task automatic send_byte(input logic [7:0] data, input logic last);
        @(posedge clk);
        s_tdata  <= data;
        s_tvalid <= 1'b1;
        s_tlast  <= last;
        while (!s_tready) @(posedge clk);
        @(posedge clk);
        s_tvalid <= 1'b0;
        s_tlast  <= 1'b0;
    endtask

    // ------------------------------------------------------------
    // Scoreboard: parallel queues, one entry per pending expected message.
    // push in send_itch_frame(), pop in the checker below.
    // ------------------------------------------------------------
    logic [1:0]  exp_type_q  [$];
    logic [63:0] exp_orderid_q [$];
    logic [15:0] exp_symbol_q [$];
    logic        exp_side_q  [$];
    logic [31:0] exp_price_q [$];
    logic [31:0] exp_size_q  [$];
    string       exp_name_q  [$];

    int pass_count;
    int fail_count;
    initial pass_count = 0;
    initial fail_count = 0;

    // ------------------------------------------------------------
    // Builds and sends one complete frame (42B header + 20B ITCH payload),
    // pushes the expected decode result onto the scoreboard queues.
    // ------------------------------------------------------------
    task automatic send_itch_frame(
        input logic [7:0]  wire_type_byte,
        input logic [1:0]  expected_type,
        input logic [63:0] order_id,
        input logic [15:0] symbol_id,
        input logic        side,
        input logic [31:0] price,
        input logic [31:0] size,
        input string       name
    );
        int i;

        // ---- Ethernet header (14B) ----
        send_byte(8'hAA, 0); send_byte(8'hBB, 0); send_byte(8'hCC, 0);
        send_byte(8'hDD, 0); send_byte(8'hEE, 0); send_byte(8'hFF, 0);
        send_byte(8'h11, 0); send_byte(8'h22, 0); send_byte(8'h33, 0);
        send_byte(8'h44, 0); send_byte(8'h55, 0); send_byte(8'h66, 0);
        send_byte(8'h08, 0); send_byte(8'h00, 0); // EtherType = IPv4

        // ---- IPv4 header (20B, IHL=5) ----
        send_byte(8'h45, 0); send_byte(8'h00, 0);
        send_byte(8'h00, 0); send_byte(8'h30, 0);
        send_byte(8'h00, 0); send_byte(8'h01, 0);
        send_byte(8'h00, 0); send_byte(8'h00, 0);
        send_byte(8'h40, 0); send_byte(8'h11, 0); // protocol = UDP
        send_byte(8'h00, 0); send_byte(8'h00, 0);
        send_byte(8'hC0, 0); send_byte(8'hA8, 0);
        send_byte(8'h01, 0); send_byte(8'h01, 0);
        send_byte(8'hC0, 0); send_byte(8'hA8, 0);
        send_byte(8'h01, 0); send_byte(8'h02, 0);

        // ---- UDP header (8B) ----
        send_byte(8'h12, 0); send_byte(8'h34, 0);
        send_byte(8'h56, 0); send_byte(8'h78, 0);
        send_byte(8'h00, 0); send_byte(8'h1C, 0);
        send_byte(8'h00, 0); send_byte(8'h00, 0);

        // ---- ITCH payload (20B) ----
        send_byte(wire_type_byte, 0);
        for (i = 7; i >= 0; i--) send_byte(order_id[i*8 +: 8], 0);
        send_byte(symbol_id[15:8], 0);
        send_byte(symbol_id[7:0], 0);
        send_byte({7'b0, side}, 0);
        send_byte(price[31:24], 0); send_byte(price[23:16], 0);
        send_byte(price[15:8], 0);  send_byte(price[7:0], 0);
        send_byte(size[31:24], 0);  send_byte(size[23:16], 0);
        send_byte(size[15:8], 0);   send_byte(size[7:0], 1); // tlast on final byte

        exp_type_q.push_back(expected_type);
        exp_orderid_q.push_back(order_id);
        exp_symbol_q.push_back(symbol_id);
        exp_side_q.push_back(side);
        exp_price_q.push_back(price);
        exp_size_q.push_back(size);
        exp_name_q.push_back(name);
    endtask

    // ------------------------------------------------------------
    // Scoreboard checker
    // ------------------------------------------------------------
    always @(posedge clk) begin
        logic [1:0]  exp_type;
        logic [63:0] exp_orderid;
        logic [15:0] exp_symbol;
        logic        exp_side;
        logic [31:0] exp_price;
        logic [31:0] exp_size;
        string       exp_name;
        logic        ok;

        if (rst_n && msg_out.valid) begin
            if (exp_type_q.size() == 0) begin
                $error("[%0t] Unexpected msg_out.valid with empty scoreboard", $time);
                fail_count = fail_count + 1;
            end else begin
                exp_type    = exp_type_q.pop_front();
                exp_orderid = exp_orderid_q.pop_front();
                exp_symbol  = exp_symbol_q.pop_front();
                exp_side    = exp_side_q.pop_front();
                exp_price   = exp_price_q.pop_front();
                exp_size    = exp_size_q.pop_front();
                exp_name    = exp_name_q.pop_front();
                ok = 1'b1;

                if (msg_out.msg_type !== exp_type) begin
                    $error("[%s] msg_type = %b, expected %b", exp_name, msg_out.msg_type, exp_type);
                    ok = 1'b0;
                end
                if (msg_out.order_id !== exp_orderid) begin
                    $error("[%s] order_id = %h, expected %h", exp_name, msg_out.order_id, exp_orderid);
                    ok = 1'b0;
                end
                if (msg_out.symbol_id !== exp_symbol) begin
                    $error("[%s] symbol_id = %h, expected %h", exp_name, msg_out.symbol_id, exp_symbol);
                    ok = 1'b0;
                end
                if (msg_out.side !== exp_side) begin
                    $error("[%s] side = %b, expected %b", exp_name, msg_out.side, exp_side);
                    ok = 1'b0;
                end
                if (msg_out.price !== exp_price) begin
                    $error("[%s] price = %0d, expected %0d", exp_name, msg_out.price, exp_price);
                    ok = 1'b0;
                end
                if (msg_out.size !== exp_size) begin
                    $error("[%s] size = %0d, expected %0d", exp_name, msg_out.size, exp_size);
                    ok = 1'b0;
                end

                if (ok) begin
                    $display("[%0t] PASS: %s decoded correctly", $time, exp_name);
                    pass_count = pass_count + 1;
                end else begin
                    fail_count = fail_count + 1;
                end
            end
        end
    end

    // ------------------------------------------------------------
    // Main test sequence
    // ------------------------------------------------------------
    initial begin
        rst_n    = 1'b0;
        s_tdata  = 8'h00;
        s_tvalid = 1'b0;
        s_tlast  = 1'b0;

        repeat (5) @(posedge clk);
        rst_n <= 1'b1;
        @(posedge clk);

        $display("========================================");
        $display("Starting Ethernet -> ITCH multi-frame test");
        $display("========================================");

        // Frame 1: Add
        send_itch_frame(8'h41, 2'b00, 64'h1122334455667788, 16'h1234, 1'b0,
                         32'h000186A0, 32'h000003E8, "Add");

        // Frame 2: Cancel, sent immediately after (back-to-back, no gap)
        send_itch_frame(8'h58, 2'b01, 64'hAABBCCDD11223344, 16'h5678, 1'b1,
                         32'h00002710, 32'h00000064, "Cancel");

        // Frame 3: Execute
        send_itch_frame(8'h45, 2'b10, 64'h0102030405060708, 16'h0001, 1'b0,
                         32'h0000FFFF, 32'h00000032, "Execute");

        // Let the pipeline fully drain before checking final counts
        repeat (50) @(posedge clk);

        $display("========================================");
        if (exp_type_q.size() != 0) begin
            $error("%0d expected message(s) never arrived", exp_type_q.size());
            fail_count = fail_count + exp_type_q.size();
        end

        if (fifo_full_latched)
            $display("NOTE: fifo_full_latched asserted at some point during the test.");

        if (fail_count == 0 && pass_count == 3)
            $display("ALL TESTS PASSED (%0d/%0d)", pass_count, pass_count);
        else
            $display("TEST FAILED: %0d passed, %0d failed", pass_count, fail_count);
        $display("========================================");

        $finish;
    end

    // Watchdog
    initial begin
        #100000;
        $error("TIMEOUT: simulation did not finish in time");
        $finish;
    end

    initial begin
        $dumpfile("sim_ethernet_parser_top.vcd");
        $dumpvars(0, tb_ethernet_parser_top);
    end

endmodule
`default_nettype wire