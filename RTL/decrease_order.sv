//same utility as add_order.sv
//will handle execute delete and cancel all in the same module because all three deal with subtracting from the number of stocks available
//for execute delete cancel you get an order ID so this module looks up oder's current price and resting size in the hash table computes how much to rmeove and requests the leaf array element decrement through the mem_arbiter module

//cancel delete -> fully remove the order by setting the resting size to 0 and invaidate the hash table entry so some other order can go in that place instead
//execute -> for execute orders we decrease the resting size by min of execute size and resting_size

//in case an order with given order Id is not found we assert the not_found flag

`default_nettype none

module decrease_order #(
    parameter int NUM_INDICES=2000,
    parameter int PRICE_WIDTH = 32,
    parameter int SIZE_WIDTH= 32,
    parameter int ORDER_ID_WIDTH=64
) (
    input logic clk, rst_n, start,
    input logic [ORDER_ID_WIDTH-1:0] order_id,
    input logic [SIZE_WIDTH-1:0] execute_size,
    input logic wipe_out, 
    output logic busy,done, not_found,

    //for price mapper 
    output logic [PRICE_WIDTH-1:0] mapper_price_in,
    input logic [$clog2(NUM_INDICES)-1:0] mapper_indx_out, 
    input logic mapper_valid_out,

    //for mem_arbiter
    output arbiter_req,
    output logic [$clog2(NUM_INDICES)-1:0] arbiter_indx,
    output logic [SIZE_WIDTH-1:0] arbiter_change,
    output logic arbiter_increment,
    input logic arbiter_grant,

    //for hash_mem or order_id_lookup
    output logic hash_mem_rd_req, 
    output logic [ORDER_ID_WIDTH-1:0] hash_mem_rd_order_id,
    output logic hash_mem_rd_invalidate, 
    input logic hash_mem_rd_done,
    input logic hash_mem_rd_found,
    input logic [PRICE_WIDTH-1:0] hash_mem_rd_price,
    input logic [SIZE_WIDTH-1:0] hash_mem_rd_size,

    //for hashmem or order_id_Lookup to write changes for a partial execute that doesnt fully consime the order

    output logic hash_mem_wr_req,
    output logic [ORDER_ID_WIDTH-1:0] hash_mem_wr_order_id,
    output logic [PRICE_WIDTH-1:0] hash_mem_wr_price,
    output logic [SIZE_WIDTH-1:0] hash_mem_wr_size,
    input logic hash_mem_wr_done,
    input logic hash_mem_wr_collision

);

    typedef enum logic [2:0] { IDLE, LOOKUP, MAP, ARB_REQ, INVALIDATE, UPDATE_SIZE, FINISH } states;
    //idle- 
    //lookup- get the price and resting size of an order from its order id 
    //map- convert price to price leaf array index 
    //arb_req request decrement from price_leaves_array through the arbiter
    //invalidate- rmove order from hash table if fully consumed 
    //finish  

    states fsm_state;
    logic  [ORDER_ID_WIDTH-1:0 ] captr_order_id ;
    logic [SIZE_WIDTH-1:0] captr_execute_size;
    logic captr_full_delete;

    logic [$clog2(NUM_INDICES)-1:0] leaf_index_reg;//map from hashmem to price leaf array
    logic [SIZE_WIDTH-1:0] dec_amount_reg;//amount to decrease from the price leaf  array 
    logic[SIZE_WIDTH-1:0] resting_size_reg;//original resting sixe before execute order
    logic resting_price_valid;
    logic [PRICE_WIDTH-1:0] resting_price_reg;
    logic should_invalidate;


    assign mapper_price_in = resting_price_reg;
    always_ff @(posedge clk)begin
        if(!rst_n)begin
            busy<=0;
            done<=0;
            not_found<=0;
            arbiter_req<=0;
            hash_mem_rd_req<=0;
            hash_mem_wr_req<=0;
            fsm_state<=IDLE;
        end else begin
            done<=0;
            hash_mem_rd_req<=0;
            arbiter_req<=0;
            hash_mem_wr_req<=0;

            case (fsm_state)
                IDLE:begin
                    if(start)begin
                        busy<=1;
                        not_found<=0;
                        fsm_state<=LOOKUP;
                        captr_order_id<=order_id;
                        captr_execute_size<=execute_size;
                        captr_full_delete<=wipe_out;
                    end
                end 

                LOOKUP:begin
                    hash_mem_rd_req<=1;
                    hash_mem_rd_order_id<=captr_order_id;
                    hash_mem_rd_invalidate<=captr_full_delete; //if it is a cancel delete order invalidate it now, if it is execute order we may or maynot have to invalidate it based on what is the resting sixe of the stock
                    if(hash_mem_rd_done)begin
                        if(!hash_mem_rd_found)begin
                            not_found<=1;
                            fsm_state<=FINISH;
                        end else begin
                            //if found the order to be executed/deleted, go and update the hashmem and the price leaf array because now that some order that was earlier recorded in these two are no more; for execute order update the  hashmem and price leaf array 
                            resting_price_reg<=hash_mem_rd_price;
                            resting_size_reg<=hash_mem_rd_size;
                            dec_amount_reg<=captr_full_delete? hash_mem_rd_size:(captr_execute_size < hash_mem_rd_size ? captr_execute_size: hash_mem_rd_size);
                            should_invalidate<= captr_full_delete || (captr_execute_size>=hash_mem_rd_size);
                            fsm_state<=MAPPING;
                        end
                    end
                end

                MAP:begin
                    if(!mapper_valid_out)begin
                        not_found<=1;
                        fsm_state<=FINISH;
                    end else begin
                        leaf_index_reg<=mapper_indx_out;
                        fsm_state<=ARB_REQ;
                    end
                end

                ARB_REQ: begin
                    arbiter_req<=1;
                    arbiter_indx<=leaf_index_reg;
                    arbiter_change<=dec_amount_reg;
                    arbiter_increment<=0;
                    if(arbiter_grant)begin
                        if(!captr_full_delete && should_invalidate)begin
                            //case where it's not a cancel/delete order but an execute one which fully consumes the resting sixe
                            fsm_state<=INVALIDATE;
                        end else if(!captr_full_delete) begin
                            //should_invalidate is false meaning it is a partial execute order
                            fsm_state<=UPDATE_SIZE; 
                        end else begin
                            fsm_state<=FINISH;//full delete branch; already invalidated in the lookup state
                        end
                    end
                end

                INVALIDATE: begin
                    hash_mem_rd_req<=1'b1;
                    hash_mem_rd_order_id<=captr_order_id;
                    hash_mem_rd_invalidate<=1;
                    if(hash_mem_rd_done)
                        fsm_state<=FINISH;
                end
                
                UPDATE_SIZE:begin
                    hash_mem_wr_req<=1;
                    hash_mem_wr_order_id<=captr_order_id;
                    hash_mem_wr_price<=resting_price_reg;
                    hash_mem_wr_size<=resting_size_reg-dec_amount_reg;
                    if(hash_mem_wr_done) fsm_state<=FINISH;
                end

                FINISH: begin
                    busy<=0;
                    done<=1;
                    fsm_state<=IDLE;
                end
                default:;
            endcase
        end
    end    
endmodule

`default_nettype wire