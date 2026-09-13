//wrapper integrating all orderbook components into one module 
`default_nettype none

module orderbook_wrapper 
    import itch_package::*;
#(
    parameter int NUM_INDICES=2000,
    parameter int PRICE_WIDTH=32,
    parameter int SIZE_WIDTH=32,
    parameter int ORDER_ID_WIDTH=64,
    parameter int P_MIN=9000,
    parameter int P_MAX=11000
) (
    input logic clk, rst_n, start,

    output logic busy, done,
    output [PRICE_WIDTH-1:0] best_bid, best_ask,
    output [SIZE_WIDTH-1:0] best_bid_size, best_ask_size,
    output logic best_ask_valid, best_bid_valid
);
    

    price_indx_mapper 
    #(
        .PRICE_WIDTH(PRICE_WIDTH),
        .P_MIN(),
        .P_MAX(),
        .TICK()
    ) mapper
    (
        .price_in(),
        .indx_out(),

        .indx_in(),
        .price_out(),

        .valid_out()
    );

    price_leaves_array
    #(
        .NUM_INDICES(NUM_INDICES),
        .SIZE_WIDTH(SIZE_WIDTH)
    ) ask_leaves
    (
        .clk(clk),
        .rst_n(rst_n),
        .wr_en(),
        .wr_indx(),
        .wr_increment(),
        .change(),

        .mem_exposed()
    );

    price_leaves_array
    #(
        .NUM_INDICES(NUM_INDICES),
        .SIZE_WIDTH(SIZE_WIDTH)
    ) bid_leaves
    (
        .clk(clk),
        .rst_n(rst_n),
        .wr_en(),
        .wr_indx(),
        .wr_increment(),
        .change(),

        .mem_exposed()
    );

    reduction_binary_tree
    #(
        .NUM_INDICES(NUM_INDICES),
        .SIZE_WIDTH(SIZE_WIDTH),
        .NEED_HIGH(1'b0)
    ) ask_tree
    (   
        .clk(clk),
        .rst_n(rst_n),
        .mem_in(), 

        .best_indx(),
        .best_valid()
    );

    reduction_binary_tree
    #(
        .NUM_INDICES(NUM_INDICES),
        .SIZE_WIDTH(SIZE_WIDTH),
        .NEED_HIGH(1'b1)
    ) bid_tree
    (
        .clk(clk),
        .rst_n(rst_n),
        .mem_in(), 

        .best_indx(),
        .best_valid()
    );

    order_id_lookup
    #(
        .ORDER_ID_WIDTH(ORDER_ID_WIDTH),
        .PRICE_WIDTH(PRICE_WIDTH),
        .SIZE_WIDTH(SIZE_WIDTH),
        .TABLE_DEPTH(),
        .MAX_PROBE()

    ) lookup
    (
        .clk(),
        .rst_n(),
        .wr_en(),
        .wr_order_id(),
        .wr_order_price(),
        .wr_order_size(),
        .wr_recorded(),
        .wr_collision_flag(),

        .rd_en(),
        .rd_order_id(),
        .rd_and_remove(),
        .rd_executed(),
        .rd_found(),
        .rd_price(),
        .rd_size()
    );

    add_order
    #(
        .NUM_INDICES(NUM_INDICES),
        .PRICE_WIDTH(PRICE_WIDTH),
        .SIZE_WIDTH(SIZE_WIDTH),
        .ORDER_ID_WIDTH(ORDER_ID_WIDTH)
    ) add_order
    (
        .clk(),
        .rst_n(),
        .start(),
        .order_id(),
        .price(),
        .size(),
        .busy(),
        .error(),
        .done(),

        .price_to_mapper(),
        .mapper_indx_out(),
        .mapper_valid_out(),

        .arbiter_req(),
        .arbiter_indx(),
        .arbiter_change(),
        .arbiter_increment(),
        .arbiter_grant(),

        .tab_wr_req(),
        .tab_wr_price(),
        .tab_wr_order_id(),
        .tab_wr_size(),
        .tab_wr_done(),
        .tab_wr_collision()
    );

    decrease_order
    #(
        .NUM_INDICES(NUM_INDICES),
        .PRICE_WIDTH(PRICE_WIDTH),
        .SIZE_WIDTH(SIZE_WIDTH),
        .ORDER_ID_WIDTH(ORDER_ID_WIDTH)

    ) decrease_order
    (
        .clk(clk),
        .rst_n(rst_n),
        .start(),
        .order_id(),
        .execute_size(),
        .wipe_out(),
        .busy(),
        .done(),
        .not_found(),

        .mapper_price_in(),
        .mapper_indx_out(),
        .mapper_valid_out(),
        
        .arbiter_req(),
        .arbiter_indx(),
        .arbiter_change(),
        .arbiter_increment(),
        .arbiter_grant(),

        .hash_mem_rd_req(),
        .hash_mem_rd_order_id(),
        .hash_mem_rd_invalidate(),
        .hash_mem_rd_done(),
        .hash_mem_rd_found(),
        .hash_mem_rd_price(),
        .hash_mem_rd_size(),

        .hash_mem_wr_req(),
        .hash_mem_wr_order_id(),
        .hash_mem_wr_price(),
        .hash_mem_wr_size(),
        .hash_mem_wr_done(),
        .hash_mem_wr_done(),
        .hash_mem_wr_collision()



    );

    mem_arbiter
    #(
        .NUM_INDICES(NUM_INDICES),
        .SIZE_WIDTH(SIZE_WIDTH)
    ) bid_arbiter
    (
        .clk(),
        .rst_n(),
        .add_req(),
        .add_req_indx(),
        .add_req_change(),
        .add_req_increment(),
        .add_req_grant(),

        .dec_req(),
        .dec_req_indx(),
        .dec_req_change(),
        .dec_req_increment(),
        .dec_req_grant(),

        .mem_wr_en(),
        .mem_wr_indx(),
        .mem_wr_increment(),
        .mem_wr_change()
    );

    mem_arbiter
    #(
        .NUM_INDICES(NUM_INDICES),
        .SIZE_WIDTH(SIZE_WIDTH)

    ) ask_arbiter
    (
        .clk(),
        .rst_n(),
        .add_req(),
        .add_req_indx(),
        .add_req_change(),
        .add_req_increment(),
        .add_req_grant(),

        .dec_req(),
        .dec_req_indx(),
        .dec_req_change(),
        .dec_req_increment(),
        .dec_req_grant(),

        .mem_wr_en(),
        .mem_wr_indx(),
        .mem_wr_increment(),
        .mem_wr_change()

    );


endmodule

`default_nettype wire