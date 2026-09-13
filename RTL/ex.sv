// order_book_wrapper.sv
//
// Top-level per-symbol order book: one instance of everything in the tree
// design report, for a single symbol. Owns two sides (bid, ask), each with
// its own price_leaves + reduction_tree (same price range/mapper shared
// between sides, since a stock's bid and ask both live in the same price
// space), and one shared order_id_lookup (order IDs are unique per symbol
// regardless of side).
//
// Interface to the caller (top-level multi-symbol dispatch, itself fed by
// the ITCH decoder): ready/busy handshake in, continuously-valid
// best_bid/best_ask outputs -- these are NOT gated by the handshake, since
// the signal engine needs to read current book state every cycle
// regardless of whether an update happens to be in flight.

`default_nettype none

module order_book_wrapper
    import itch_pkg::*;
#(
    parameter int NUM_LEVELS     = 2000,
    parameter int PRICE_WIDTH    = 32,
    parameter int SIZE_WIDTH     = 32,
    parameter int ORDER_ID_WIDTH = 64,
    parameter int P_MIN          = 9000,
    parameter int P_MAX          = 11000
) (
    input  logic clk,
    input  logic rst_n,

    input  logic       start,      // apply msg_in this cycle
    input  itch_msg_t  msg_in,
    output logic       busy,
    output logic       done,

    output logic [PRICE_WIDTH-1:0] best_bid,
    output logic                   best_bid_valid,
    output logic [SIZE_WIDTH-1:0]  best_bid_size,
    output logic [PRICE_WIDTH-1:0] best_ask,
    output logic                   best_ask_valid,
    output logic [SIZE_WIDTH-1:0]  best_ask_size
);

    localparam int IDX_WIDTH = $clog2(NUM_LEVELS);

    // ============================================================
    // Snapshot the incoming message at the start of a transaction.
    //
    // add_order/decrease_order read order_id/price/size/side as plain,
    // continuous inputs for their *entire* multi-cycle operation, not just
    // on the start pulse. Wiring them directly to msg_in would only work by
    // accident of timing -- itch_decoder happens to hold msg_out steady for
    // ~20 cycles between messages, comfortably longer than a book
    // operation takes today, but that's an unstated assumption, not a
    // guarantee, and would silently break if the pipeline is ever changed
    // to decode messages back-to-back faster than a book op completes.
    // Latching a local copy here removes that dependency entirely: this
    // module is self-contained once `start` fires, regardless of what
    // happens on msg_in afterward.
    // ============================================================
    itch_msg_t msg_reg;

    // ============================================================
    // Shared price mapper (one instance, used by whichever FSM/side
    // is currently active -- only one operation is ever in flight
    // per symbol, so no contention).
    // ============================================================
    logic [PRICE_WIDTH-1:0] mapper_price_in;
    logic [IDX_WIDTH-1:0]   mapper_index_out;
    logic                   mapper_valid_out;
    logic [IDX_WIDTH-1:0]   mapper_index_in_unused;
    logic [PRICE_WIDTH-1:0] mapper_price_out_unused;

    price_mapper #(
        .PRICE_WIDTH(PRICE_WIDTH), .P_MIN(P_MIN), .P_MAX(P_MAX), .TICK_SHIFT(0)
    ) u_mapper (
        .price_in(mapper_price_in), .index_out(mapper_index_out), .valid_out(mapper_valid_out),
        .index_in(mapper_index_in_unused), .price_out(mapper_price_out_unused)
    );

    // ============================================================
    // Per-side leaf arrays + reduction trees
    // ============================================================
    logic [SIZE_WIDTH-1:0] bid_leaves [NUM_LEVELS];
    logic [SIZE_WIDTH-1:0] ask_leaves [NUM_LEVELS];

    logic                  bid_wr_en, ask_wr_en;
    logic [IDX_WIDTH-1:0]  bid_wr_index, ask_wr_index;
    logic                  bid_wr_incr, ask_wr_incr;
    logic [SIZE_WIDTH-1:0] bid_wr_delta, ask_wr_delta;

    price_leaves #(.NUM_LEVELS(NUM_LEVELS), .SIZE_WIDTH(SIZE_WIDTH)) u_bid_leaves (
        .clk(clk), .rst_n(rst_n),
        .wr_en(bid_wr_en), .wr_index(bid_wr_index), .wr_increment(bid_wr_incr), .wr_delta(bid_wr_delta),
        .leaves_out(bid_leaves)
    );
    price_leaves #(.NUM_LEVELS(NUM_LEVELS), .SIZE_WIDTH(SIZE_WIDTH)) u_ask_leaves (
        .clk(clk), .rst_n(rst_n),
        .wr_en(ask_wr_en), .wr_index(ask_wr_index), .wr_increment(ask_wr_incr), .wr_delta(ask_wr_delta),
        .leaves_out(ask_leaves)
    );

    logic [IDX_WIDTH-1:0] bid_best_idx, ask_best_idx;
    logic                 bid_best_valid_tree, ask_best_valid_tree;

    reduction_tree #(.NUM_LEVELS(NUM_LEVELS), .SIZE_WIDTH(SIZE_WIDTH), .PREFER_HIGHER(1'b1)) u_bid_tree (
        .clk(clk), .rst_n(rst_n), .leaves_in(bid_leaves),
        .best_index(bid_best_idx), .best_valid(bid_best_valid_tree)
    );
    reduction_tree #(.NUM_LEVELS(NUM_LEVELS), .SIZE_WIDTH(SIZE_WIDTH), .PREFER_HIGHER(1'b0)) u_ask_tree (
        .clk(clk), .rst_n(rst_n), .leaves_in(ask_leaves),
        .best_index(ask_best_idx), .best_valid(ask_best_valid_tree)
    );

    assign best_bid       = P_MIN + bid_best_idx;
    assign best_bid_valid = bid_best_valid_tree;
    assign best_bid_size  = bid_leaves[bid_best_idx];
    assign best_ask       = P_MIN + ask_best_idx;
    assign best_ask_valid = ask_best_valid_tree;
    assign best_ask_size  = ask_leaves[ask_best_idx];

    // ============================================================
    // Shared order_id_lookup (both sides, one order-ID namespace)
    // ============================================================
    logic lut_wr_req, lut_wr_done, lut_wr_collision;
    logic [ORDER_ID_WIDTH-1:0] lut_wr_order_id;
    logic [PRICE_WIDTH-1:0]    lut_wr_price;
    logic [SIZE_WIDTH-1:0]     lut_wr_size;

    logic lut_rd_req, lut_rd_invalidate, lut_rd_done, lut_rd_found;
    logic [ORDER_ID_WIDTH-1:0] lut_rd_order_id;
    logic [PRICE_WIDTH-1:0]    lut_rd_price;
    logic [SIZE_WIDTH-1:0]     lut_rd_size;

    order_id_lookup #(
        .ORDER_ID_WIDTH(ORDER_ID_WIDTH), .PRICE_WIDTH(PRICE_WIDTH), .SIZE_WIDTH(SIZE_WIDTH),
        .TABLE_DEPTH(4096), .MAX_PROBE(4)
    ) u_lookup (
        .clk(clk), .rst_n(rst_n),
        .wr_req(lut_wr_req), .wr_order_id(lut_wr_order_id), .wr_price(lut_wr_price), .wr_size(lut_wr_size),
        .wr_done(lut_wr_done), .wr_collision(lut_wr_collision),
        .rd_req(lut_rd_req), .rd_order_id(lut_rd_order_id), .rd_invalidate(lut_rd_invalidate),
        .rd_done(lut_rd_done), .rd_found(lut_rd_found), .rd_price(lut_rd_price), .rd_size(lut_rd_size)
    );

    // ============================================================
    // add_order / decrease_order FSMs
    // ============================================================
    logic add_start, add_busy, add_done, add_error;
    logic [IDX_WIDTH-1:0]  add_arb_index;
    logic [SIZE_WIDTH-1:0] add_arb_delta;
    logic add_arb_req, add_arb_incr, add_arb_grant;

    add_order #(
        .NUM_LEVELS(NUM_LEVELS), .PRICE_WIDTH(PRICE_WIDTH), .SIZE_WIDTH(SIZE_WIDTH), .ORDER_ID_WIDTH(ORDER_ID_WIDTH)
    ) u_add (
        .clk(clk), .rst_n(rst_n),
        .start(add_start), .order_id(msg_reg.order_id), .price(msg_reg.price), .size(msg_reg.size),
        .busy(add_busy), .done(add_done), .error(add_error),
        .mapper_price_in(add_mapper_price_in), .mapper_index_out(mapper_index_out), .mapper_valid_out(mapper_valid_out),
        .arb_req(add_arb_req), .arb_index(add_arb_index), .arb_delta(add_arb_delta), .arb_increment(add_arb_incr),
        .arb_grant(add_arb_grant),
        .lut_wr_req(add_lut_wr_req), 
        .lut_wr_order_id(add_lut_wr_order_id),
        .lut_wr_price(add_lut_wr_price), 
        .lut_wr_size(add_lut_wr_size),
        .lut_wr_done(lut_wr_done), 
        .lut_wr_collision(lut_wr_collision)
    );

    logic dec_start, dec_busy, dec_done, dec_not_found;
    logic [IDX_WIDTH-1:0]  dec_arb_index;
    logic [SIZE_WIDTH-1:0] dec_arb_delta;
    logic dec_arb_req, dec_arb_incr, dec_arb_grant;

    decrease_order #(
        .NUM_LEVELS(NUM_LEVELS), .PRICE_WIDTH(PRICE_WIDTH), .SIZE_WIDTH(SIZE_WIDTH), .ORDER_ID_WIDTH(ORDER_ID_WIDTH)
    ) u_dec (
        .clk(clk), 
        .rst_n(rst_n),
        .start(dec_start), 
        .order_id(msg_reg.order_id), 
        .exec_size(msg_reg.size),
        .full_delete(msg_reg.msg_type != 2'b10), // anything other than Execute is a full removal
        .busy(dec_busy), .done(dec_done), 
        .not_found(dec_not_found),

        .mapper_price_in(dec_mapper_price_in), 
        .mapper_index_out(mapper_index_out), 
        .mapper_valid_out(mapper_valid_out),
        
        .arb_req(dec_arb_req), 
        .arb_index(dec_arb_index), 
        .arb_delta(dec_arb_delta), 
        .arb_increment(dec_arb_incr),
        .arb_grant(dec_arb_grant),

        .lut_rd_req(lut_rd_req), 
        .lut_rd_order_id(lut_rd_order_id), 
        .lut_rd_invalidate(lut_rd_invalidate),
        .lut_rd_done(lut_rd_done), 
        .lut_rd_found(lut_rd_found), 
        .lut_rd_price(lut_rd_price), 
        .lut_rd_size(lut_rd_size),

        .lut_wr_req(dec_lut_wr_req), 
        .lut_wr_order_id(dec_lut_wr_order_id),
        .lut_wr_price(dec_lut_wr_price), 
        .lut_wr_size(dec_lut_wr_size),
        .lut_wr_done(lut_wr_done), 
        .lut_wr_collision(lut_wr_collision)
    );

    // price_mapper input mux, AND order_id_lookup write-port mux: only one
    // of add/decrease is ever active for a given symbol at a time (see top
    // FSM below), so a plain busy-gated mux is sufficient for both -- no
    // real arbitration needed since there's never genuine contention, only
    // ever one live driver at a time. add_order writes on every Add (an
    // insert); decrease_order now also writes on a partial Execute that
    // doesn't fully consume the order (a write-back of the reduced size --
    // see decrease_order.sv's UPDATE_SIZE state). lut_wr_done/collision are
    // broadcast back to both FSMs' inputs; only whichever one is actually
    // mid-write cares about them.
    logic [PRICE_WIDTH-1:0] add_mapper_price_in, dec_mapper_price_in;
    assign mapper_price_in = add_busy ? add_mapper_price_in : dec_mapper_price_in;

    logic add_lut_wr_req, dec_lut_wr_req;
    logic [ORDER_ID_WIDTH-1:0] add_lut_wr_order_id, dec_lut_wr_order_id;
    logic [PRICE_WIDTH-1:0]    add_lut_wr_price, dec_lut_wr_price;
    logic [SIZE_WIDTH-1:0]     add_lut_wr_size, dec_lut_wr_size;

    assign lut_wr_req      = add_busy ? add_lut_wr_req      : dec_lut_wr_req;
    assign lut_wr_order_id = add_busy ? add_lut_wr_order_id : dec_lut_wr_order_id;
    assign lut_wr_price    = add_busy ? add_lut_wr_price    : dec_lut_wr_price;
    assign lut_wr_size     = add_busy ? add_lut_wr_size     : dec_lut_wr_size;

    // ============================================================
    // Per-side arbiters: route whichever FSM is active (and its
    // known order side) to the matching leaf array. Since add/decrease
    // are mutually exclusive per symbol, only one arbiter ever sees a
    // live request on a given cycle -- see book_memory_arbiter.sv for
    // why this is still the correct place to put this seam.
    // ============================================================
    logic bid_a_grant, bid_b_grant, ask_a_grant, ask_b_grant;

    logic add_is_bid, dec_is_bid;
    assign add_is_bid = (msg_reg.side == 1'b0); // 0 = buy
    assign dec_is_bid = (msg_reg.side == 1'b0);

    book_memory_arbiter #(.NUM_LEVELS(NUM_LEVELS), .SIZE_WIDTH(SIZE_WIDTH)) u_bid_arb (
        .clk(clk), 
        .rst_n(rst_n),

        .a_req(add_arb_req && add_is_bid), 
        .a_index(add_arb_index), 
        .a_delta(add_arb_delta), 
        .a_increment(add_arb_incr),
        .a_grant(bid_a_grant),

        .b_req(dec_arb_req && dec_is_bid), 
        .b_index(dec_arb_index), 
        .b_delta(dec_arb_delta), 
        .b_increment(dec_arb_incr),
        .b_grant(bid_b_grant),
        
        .mem_wr_en(bid_wr_en), 
        .mem_wr_index(bid_wr_index), 
        .mem_wr_increment(bid_wr_incr), 
        .mem_wr_delta(bid_wr_delta)
    );

    book_memory_arbiter #(.NUM_LEVELS(NUM_LEVELS), .SIZE_WIDTH(SIZE_WIDTH)) u_ask_arb (
        .clk(clk), 
        .rst_n(rst_n),
        .a_req(add_arb_req && !add_is_bid), 
        .a_index(add_arb_index), 
        .a_delta(add_arb_delta), 
        .a_increment(add_arb_incr),
        .a_grant(ask_a_grant),

        .b_req(dec_arb_req && !dec_is_bid), 
        .b_index(dec_arb_index), 
        .b_delta(dec_arb_delta), 
        .b_increment(dec_arb_incr),
        .b_grant(ask_b_grant),

        .mem_wr_en(ask_wr_en), 
        .mem_wr_index(ask_wr_index), 
        .mem_wr_increment(ask_wr_incr), 
        .mem_wr_delta(ask_wr_delta)
    );

    assign add_arb_grant = add_is_bid ? bid_a_grant : ask_a_grant;
    assign dec_arb_grant = dec_is_bid ? bid_b_grant : ask_b_grant;

    // ============================================================
    // Top dispatch: which FSM to run for the current message
    // ============================================================
    typedef enum logic [1:0] {IDLE, RUN, WAIT_DONE} state_t;
    state_t state;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state     <= IDLE;
            busy      <= 1'b0;
            done      <= 1'b0;
            add_start <= 1'b0;
            dec_start <= 1'b0;
        end else begin
            done      <= 1'b0;
            add_start <= 1'b0;
            dec_start <= 1'b0;

            case (state)
                IDLE: begin
                    if (start && msg_in.valid) begin
                        busy    <= 1'b1;
                        msg_reg <= msg_in; // snapshot -- see comment above
                        if (msg_in.msg_type == 2'b00) add_start <= 1'b1;
                        else                          dec_start <= 1'b1;
                        state <= RUN;
                    end
                end
                RUN: state <= WAIT_DONE; // let the start pulse register into busy on the sub-FSM
                WAIT_DONE: begin
                    if (add_done || dec_done) begin
                        busy  <= 1'b0;
                        done  <= 1'b1;
                        state <= IDLE;
                    end
                end
            endcase
        end
    end

endmodule
`default_nettype wire