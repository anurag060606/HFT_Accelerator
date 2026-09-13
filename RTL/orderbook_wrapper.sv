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
    parameter int P_MAX=11000,
    parameter int TICK=0
) (
    input logic clk, rst_n, start,
    itch_msg_t msg_in,
    output logic busy, done,
    output [PRICE_WIDTH-1:0] best_bid, best_ask,
    output [SIZE_WIDTH-1:0] best_bid_size, best_ask_size,
    output logic best_ask_valid, best_bid_valid
);

    localparam int INDX_WIDTH=$clog2(NUM_INDICES);
    itch_msg_t captr_msg;

    //===============================================================================================================================================================
    //mapper
    //whenever a new order comes in to the orderbook the mapper should take in the price of the order and generate corresponding leaf array index 
    //the leaf array at a particular price position holds the number of shares of the symbol at that particular price
    
    logic [PRICE_WIDTH-1:0] mapper_price_in, mapper_price_out;
    logic [INDX_WIDTH-1:0] mapper_indx_out, mapper_indx_in;
    logic mapper_valid_out;
    //

    price_indx_mapper 
    #(
        .PRICE_WIDTH(PRICE_WIDTH),
        .P_MIN(P_MIN),
        .P_MAX(P_MAX),
        .TICK(TICK)
    ) mapper
    (
        .price_in(mapper_price_in),
        .indx_out(mapper_indx_out),

        .indx_in(mapper_indx_in),
        .price_out(mapper_price_out),

        .valid_out(mapper_valid_out)
    );
    //==============================================================================================================================================================

    //==============================================================================================================================================================
    //leaves array section
    //here we create a leaf array for storing the aggregate stocks at a particular price which is marked by the index of taht array
    //there are two sides of a trade book the bid side where buyers tell what price they are ready to give for what number of stocks and the ask sixe where the seller demands price for stock and number of stocks they are selling

    //--------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------
    //bid leaves
    logic [SIZE_WIDTH-1:0] bid_leaves [NUM_INDICES];
    logic bid_wr_en;
    logic [INDX_WIDTH-1:0] bid_wr_indx;
    logic bid_wr_increment;
    logic [SIZE_WIDTH-1:0] bid_change;


    price_leaves_array
    #(
        .NUM_INDICES(NUM_INDICES),
        .SIZE_WIDTH(SIZE_WIDTH)
    ) u_bid_leaves
    (
        .clk(clk),
        .rst_n(rst_n),
        .wr_en(bid_wr_en),
        .wr_indx(bid_wr_indx),
        .wr_increment(bid_wr_increment),
        .change(bid_change),

        .mem_exposed(bid_leaves)
    );

    //--------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------

    logic [SIZE_WIDTH-1:0] ask_leaves [NUM_INDICES];
    logic ask_wr_en;
    logic [INDX_WIDTH-1:0] ask_wr_indx;
    logic ask_wr_increment;
    logic [SIZE_WIDTH-1:0] ask_change;


    price_leaves_array
    #(
        .NUM_INDICES(NUM_INDICES),
        .SIZE_WIDTH(SIZE_WIDTH)
    ) u_ask_leaves
    (
        .clk(clk),
        .rst_n(rst_n),
        .wr_en(ask_wr_en),
        .wr_indx(ask_wr_indx),
        .wr_increment(ask_wr_increment),
        .change(ask_change),

        .mem_exposed(ask_leaves)
    );
    //--------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------
    //===========================================================================================================================================================================================

    //===========================================================================================================================================================================================
    //reduction trees 
    //here we create reduction trees which provide the best ask and best bid indx for both bid and ask sides of the orderbook
    //there's one reduction tree for the ask side and one for the bid side
    //the outputs of these reduction trees are directly used to compute the outputs of the entire orderbook module

    //--------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------
    //bid side
    logic [INDX_WIDTH-1:0] bid_best_indx;
    logic bid_best_valid;

    reduction_binary_tree
    #(
        .NUM_INDICES(NUM_INDICES),
        .SIZE_WIDTH(SIZE_WIDTH),
        .NEED_HIGH(1'b1)
    ) bid_tree
    (   
        .clk(clk),
        .rst_n(rst_n),
        .mem_in(bid_leaves), 

        .best_indx(bid_best_indx),
        .best_valid(bid_best_valid)
    );
    //--------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------
    //ask side

    logic [INDX_WIDTH-1:0] ask_best_indx;
    logic ask_best_valid;

    reduction_binary_tree
    #(
        .NUM_INDICES(NUM_INDICES),
        .SIZE_WIDTH(SIZE_WIDTH),
        .NEED_HIGH(1'b0)
    ) ask_tree
    (
        .clk(clk),
        .rst_n(rst_n),
        .mem_in(ask_leaves), 

        .best_indx(ask_best_indx),
        .best_valid(ask_best_valid)
    );
    //--------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------
    //computing the output of the entire orderbook module

    assign best_bid=P_MIN+bid_best_indx;
    assign best_bid_valid= bid_best_valid;
    assign best_bid_size=bid_leaves[bid_best_indx];

    assign best_ask=P_MIN+ask_best_indx;
    assign best_ask_valid= ask_best_valid;
    assign best_ask_size=ask_leaves[ask_best_indx];
    //--------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------
    //===========================================================================================================================================================================================
    



    //BIG DIRTY MAINTENANCE WORK 
    //-_-_-_-_-_-_-_-_-_-_-_-_-_-_-_-_-_-_-_-_-_-_-_-_-_-_-_-_-_-_-_-_-_-_-_-_-_-_-_-_-_-_-_-_-_-_-_-_-_-_-_-_-_-_-_-_-_-_-_-_-_-_-_-_-_-_-_-_-_-_-_-_-_-_-_-_-_-_-_-_-_-_-_-_-_-_-_-_-_-_-_-_-_-_-_
    
    
    //===========================================================================================================================================================================================
    //the lookup table
    //the lookup table keeps a record of all the orders that came in the system using a hashmap with linear probing datastructure
    //the lookup table gets its data from the add_order and decrease_order modules instantiated later

    //the write logic of lookup tables handles add orders because when adding orders you need to actually write new data to the lookup table internal hashmap
    logic lookup_wr_en, //can i write to the lookup table, comes from add_order module
    lookup_wr_recorded, //has the write operation in lookup table successfully completed
    lookup_wr_collision_flag;//has there been a collision while writing to the looktable because of which the data couldnt be written
    logic [ORDER_ID_WIDTH-1:0] lookup_wr_order_id;//the order id data from add_order or decrease_order comes from this wire and that tells it what to write to the lookup table
    logic [PRICE_WIDTH-1:0] lookup_wr_price;//the price data from add_order or decrease_order comes from this wire and that tells it what to write to the lookup table
    logic [SIZE_WIDTH-1:0] lookup_wr_order_size;//the order sixe data from add_order or decrease_order comes from this wire and that tells it what to write to the lookup table


    //the read logic of lookup table is used by execute and cancel orders
    //this is because when an execute order comes like execute ID=1234 sixe=20
    //then then the decrease module asks the lookup table if an order with ID 1234 exists in the orderbook
    //if found the lookup table then decreases the sixe of the order by 20
    //for a cancel or delete order, it finds the order id and invalidates it by setting the valid flag of the entry as false

    logic lookup_rd_en, //comes from decrease_order module
    lookup_rd_and_remove, //comes from decrease_order_module, used when a delete/cancel order is received, this singal simply invalidates the order after succesfully reading i.e. finding it
    lookup_rd_executed, //output from the lookup table sharing that the read was successfully done, goes to the decrease_order module
    lookup_rd_found; //again output from the lookup table sharing that the order was found, goes to decrease_order module

    logic [ORDER_ID_WIDTH-1:0] lookup_rd_order_id;//output from decrease_order and goes into the lookup table, this gives the order_id of the order we wanna find in the table
    logic [PRICE_WIDTH-1:0] lookup_rd_price;//output from lookup table to the decrease module
    logic [SIZE_WIDTH-1:0] lookup_rd_size;//output from lookup table to decrease module

    order_id_lookup
    #(
        .ORDER_ID_WIDTH(ORDER_ID_WIDTH),
        .PRICE_WIDTH(PRICE_WIDTH),
        .SIZE_WIDTH(SIZE_WIDTH),
        .TABLE_DEPTH(4096),
        .MAX_PROBE(4)

    ) lookup
    (
        .clk(clk),
        .rst_n(rst_n),
        .wr_en(lookup_wr_en),
        .wr_order_id(lookup_wr_order_id),
        .wr_order_price(lookup_wr_price),
        .wr_order_size(lookup_wr_order_size),
        .wr_recorded(lookup_wr_recorded),
        .wr_collision_flag(lookup_wr_collision_flag),

        .rd_en(lookup_rd_en),
        .rd_order_id(lookup_rd_order_id),
        .rd_and_remove(lookup_rd_and_remove),
        .rd_executed(lookup_rd_executed),
        .rd_found(lookup_rd_found),
        .rd_price(lookup_rd_price),
        .rd_size(lookup_rd_size)
    );
    //===========================================================================================================================================================================================


    //===========================================================================================================================================================================================
    logic add_start, //comes from the fsm in this module, whenever an add order is received this signal goes high
    add_busy, //output from add_order module that indicates that the add order module is busy right now
    add_error, //output from add_order module
    add_done;//output from add_order module

    logic [PRICE_WIDTH-1:0] add_mapper_price_in;//goes from add_order to mapper module to get an index for the entry to the price leaves array
    logic add_arbiter_req; //output from add_order and reqeusts arbiter to give it access to write to the price leaves array 
    logic [INDX_WIDTH-1:0] add_arbiter_indx;//comes from the mapper to add_order module and brings the index where the new order price is mapped
    logic [SIZE_WIDTH-1:0] add_arbiter_change;// goes from add_order to arbiter and tells how much change to the price index has to be done after a new order has come so that the index shows new aggregate sixe of the stocks at that level
    logic add_arbiter_increment,//goes from add_order to arbiter and tells if the leaf array index aggregate has to be increased or decreased
    add_arbiter_grant;//comes from arbiter to add_order tells if the arbiter request has been granted

    logic add_tab_wr_req;//goes from add_order to lookup table asks for perm to write to the lookup table
    logic [ORDER_ID_WIDTH-1:0] add_tab_order_id;//goes from add_order to lookup table and tells what is the order of the new order that has to be written
    logic [PRICE_WIDTH-1:0] add_tab_wr_price;//goes from add_order to lookup table telling what's the price of the new order
    logic [SIZE_WIDTH-1:0] add_tab_wr_size;//goes from add_order to lookup table telling what's the sixe of the new order

    add_order
    #(
        .NUM_INDICES(NUM_INDICES),
        .PRICE_WIDTH(PRICE_WIDTH),
        .SIZE_WIDTH(SIZE_WIDTH),
        .ORDER_ID_WIDTH(ORDER_ID_WIDTH)
    ) add_order
    (
        .clk(clk),
        .rst_n(rst_n),

        .start(add_start),
        .busy(add_busy),
        .error(add_error),
        .done(add_done),

        .order_id(captr_msg.order_id),
        .price(captr_msg.price),
        .size(captr_msg.size),
        

        .price_to_mapper(add_mapper_price_in),
        .mapper_indx_out(mapper_indx_out),
        .mapper_valid_out(mapper_valid_out),

        .arbiter_req(add_arbiter_req),
        .arbiter_indx(add_arbiter_indx),
        .arbiter_change(add_arbiter_change),
        .arbiter_increment(add_arbiter_increment),
        .arbiter_grant(add_arbiter_grant),

        .tab_wr_req(add_tab_wr_req),
        .tab_wr_price(add_tab_wr_price),
        .tab_wr_order_id(add_tab_order_id),
        .tab_wr_size(add_tab_wr_size),
        .tab_wr_done(lookup_wr_recorded),
        .tab_wr_collision(lookup_wr_collision_flag)
    );
    //===========================================================================================================================================================================================


    logic decrease_start, decrease_busy, decrease_done, decrease_not_found;
    logic [PRICE_WIDTH-1:0] decrease_mapper_price_in;
    logic decrease_arbiter_req, decrease_arbiter_increment ,decrease_arbiter_grant;
    logic [INDX_WIDTH-1:0] decrease_arbiter_indx;
    logic [SIZE_WIDTH-1:0] decrease_arbiter_change;

    logic decrease_hash_mem_wr_req;
    logic [ORDER_ID_WIDTH-1:0] decrease_hash_mem_wr_order_id;
    logic [PRICE_WIDTH-1:0] decrease_hash_mem_wr_price;
    logic [SIZE_WIDTH-1:0] decrease_hash_mem_wr_size;

    logic decrease_hash_mem_rd_req, decrease_hash_mem_rd_invalidate;
    logic [ORDER_ID_WIDTH-1:0] decrease_hash_mem_rd_order_id;
    logic [PRICE_WIDTH-1:0] decrease_hash_mem_rd_price;
    logic [SIZE_WIDTH-1:0] decrease_hash_mem_rd_size;
    logic decrease_hash_mem_rd_done, decrease_hash_mem_rd_found;

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
        .start(decrease_start),
        .order_id(captr_msg.order_id),
        .execute_size(captr_msg.size),
        .wipe_out(captr_msg.msg_type!=2'b10), //all messages other than execute are full remove -> delete or cancel
        .busy(decrease_busy),
        .done(decrease_done),
        .not_found(decrease_not_found),

        .mapper_price_in(decrease_mapper_price_in),
        .mapper_indx_out(mapper_indx_out),
        .mapper_valid_out(mapper_valid_out),
        
        .arbiter_req(decrease_arbiter_req),
        .arbiter_indx(decrease_arbiter_indx),
        .arbiter_change(decrease_arbiter_change),
        .arbiter_increment(decrease_arbiter_increment),
        .arbiter_grant(decrease_arbiter_grant),

        //verified below correct
        .hash_mem_rd_req(lookup_rd_en),
        .hash_mem_rd_order_id(lookup_rd_order_id),
        .hash_mem_rd_invalidate(lookup_rd_and_remove),
        .hash_mem_rd_done(lookup_rd_executed),
        .hash_mem_rd_found(lookup_rd_found),
        .hash_mem_rd_price(lookup_rd_price),
        .hash_mem_rd_size(lookup_rd_size),

        //verified below
        .hash_mem_wr_req(decrease_hash_mem_wr_req),
        .hash_mem_wr_order_id(decrease_hash_mem_wr_order_id),
        .hash_mem_wr_price(decrease_hash_mem_wr_price),
        .hash_mem_wr_size(decrease_hash_mem_wr_size),

        //verified below
        .hash_mem_wr_done(lookup_wr_recorded),
        .hash_mem_wr_collision(lookup_wr_collision_flag)
    );

    assign mapper_price_in=add_busy?add_mapper_price_in:decrease_mapper_price_in;
    
    assign lookup_wr_en=add_busy?add_tab_wr_req:decrease_hash_mem_wr_req;
    assign lookup_wr_order_id= add_busy? add_tab_order_id:decrease_hash_mem_wr_order_id;
    assign lookup_wr_price=add_busy?add_tab_wr_price:decrease_hash_mem_wr_price;
    assign lookup_wr_order_size= add_busy?add_tab_wr_size:decrease_hash_mem_wr_size;


    logic is_add_order_a_bid; //yes-> add_order is on the buy side else it is on the sell side
    logic is_dec_order_a_bid; //yes-> decrease order is on the buy side else it is on the sell side

    assign is_add_order_a_bid=(captr_msg.side==1'b0);
    assign is_dec_order_a_bid=(captr_msg.side==1'b0);

    logic bid_add_grant, bid_dec_grant;
    logic ask_add_grant, ask_dec_grant;



    mem_arbiter
    #(
        .NUM_INDICES(NUM_INDICES),
        .SIZE_WIDTH(SIZE_WIDTH)
    ) bid_arbiter
    (
        .clk(clk),
        .rst_n(rst_n),
        .add_req(add_arbiter_req && is_add_order_a_bid),
        .add_req_indx(add_arbiter_indx),
        .add_req_change(add_arbiter_change),
        .add_req_increment(add_arbiter_increment),
        .add_req_grant(bid_add_grant),

        .dec_req(decrease_arbiter_req && is_dec_order_a_bid),
        .dec_req_indx(decrease_arbiter_indx),
        .dec_req_change(decrease_arbiter_change),
        .dec_req_increment(decrease_arbiter_increment),
        .dec_req_grant(bid_dec_grant),

        .mem_wr_en(bid_wr_en),
        .mem_wr_indx(bid_wr_indx),
        .mem_wr_increment(bid_wr_increment),
        .mem_wr_change(bid_change)
    );

    mem_arbiter
    #(
        .NUM_INDICES(NUM_INDICES),
        .SIZE_WIDTH(SIZE_WIDTH)

    ) ask_arbiter
    (
        .clk(clk),
        .rst_n(rst_n),
        .add_req(!is_add_order_a_bid && add_arbiter_req),
        .add_req_indx(add_arbiter_indx),
        .add_req_change(add_arbiter_change),
        .add_req_increment(add_arbiter_increment),
        .add_req_grant(ask_add_grant),

        .dec_req(!is_dec_order_a_bid && decrease_arbiter_req),
        .dec_req_indx(decrease_arbiter_indx),
        .dec_req_change(decrease_arbiter_change),
        .dec_req_increment(decrease_arbiter_increment),
        .dec_req_grant(ask_dec_grant),

        .mem_wr_en(ask_wr_en),
        .mem_wr_indx(ask_wr_indx),
        .mem_wr_increment(ask_wr_increment),
        .mem_wr_change(ask_change)
    );

    assign add_arbiter_grant= is_add_order_a_bid? bid_add_grant:ask_add_grant;
    assign decrease_arbiter_grant= is_dec_order_a_bid? bid_dec_grant:ask_dec_grant;

    typedef enum [1:0] { IDLE, RUN, WAIT_DONE } states;
    states fsm_state;

    always_ff @(posedge clk)begin
        if(!rst_n)begin
            fsm_state<=IDLE;
            busy<=0;
            done<=0;
            add_start<=0;
            decrease_start<=0;
        end else begin
            done<=0;
            add_start<=0;
            decrease_start<=0;

            case (fsm_state)
                IDLE:begin
                    if(start && msg_in.valid)begin
                        busy<=1;
                        captr_msg<=msg_in;

                        if(msg_in.msg_type==2'b00)
                            add_start<=1;
                        else
                            decrease_start<=1;
                        fsm_state<=RUN;
                    end
                end

                RUN:begin
                    fsm_state<=WAIT_DONE;
                end

                WAIT_DONE:begin
                    if(add_done||decrease_done)begin
                        busy<=0;
                        done<=1;
                        fsm_state<=IDLE;
                    end
                end
                default:;
            endcase

        end
    end

endmodule

`default_nettype wire