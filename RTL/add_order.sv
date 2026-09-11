//handles add order request
//find address of write through mapper module->send write request to mem_arbiter-> write to hash table as well

//one major atomicity issue here
//there can be a case where mapping succeeds but putting that in hashmap doesnt
//in this module the entire operation is divided into different state and consistency wont be maintained in the case mentioend because price leaves update but hashmap doesnt need to fix this for a consistent thing


`default_nettype none
module add_order #(
    parameter int NUM_INDICES=2000,
    parameter int PRICE_WIDTH=32,
    parameter int SIZE_WIDTH=32,
    parameter int ORDER_ID_WIDTH=64
) (
    input logic clk, rst_n, start,
    input logic [ORDER_ID_WIDTH-1:0] order_id,
    input logic [PRICE_WIDTH-1:0] price,
    input logic [SIZE_WIDTH-1:0] size,
    output logic busy,done, error,

    output logic [PRICE_WIDTH-1:0] price_to_mapper,
    input logic [$clog2(NUM_INDICES)-1:0] mapper_indx_out,
    input logic mapper_valid_out,

    output logic arbiter_req,
    output logic [$clog2(NUM_INDICES)-1:0] arbiter_indx,
    output logic [SIZE_WIDTH-1:0] arbiter_change,
    output logic arbiter_increment, 
    input logic arbiter_grant,

    output logic tab_wr_req,
    output logic [PRICE_WIDTH-1:0] tab_wr_price,
    output logic [ORDER_ID_WIDTH-1:0] tab_wr_order_id,
    output logic [SIZE_WIDTH-1:0] tab_wr_size,
    input logic tab_wr_done,
    input logic lut_wr_collision
);

    typedef enum logic [2:0] {IDLE, MAPPING, ARB, TAB, FINISH } states;
    states fsm_state;
    logic [$clog2(NUM_INDICES)-1:0] cptr_leaf_indx;

    always_ff @( posedge clk ) begin
        if(!rst_n)begin
            busy<=0;
            done<=0;
            error<=0;
            arbiter_req<=0;
            tab_wr_req<=0;
            fsm_state<=IDLE;
        end else begin 
            done<=0;
            arbiter_req<=0;
            tab_wr_req<=0;
            case (fsm_state)    
                IDLE:begin
                    if(start)begin
                        busy<=1;
                        error<=0; ///not necessary
                        fsm_state<=MAPPING;
                    end
                end
                MAPPING: begin
                    if(!mapper_valid_out) begin
                        error<=1;//mapping failed for some reason
                        fsm_state<=FINISH;
                    end else begin
                        cptr_leaf_indx<=mapper_indx_out;
                        fsm_state<=ARB;
                    end
                end

                ARB: begin
                    arbiter_req<=1;
                    arbiter_indx<=cptr_leaf_indx;
                    arbiter_change<=size;
                    arbiter_increment<=1;
                    if(arbiter_grant)
                        fsm_state<=TAB;
                    
                end 

                TAB: begin
                    tab_wr_req<=1;
                    tab_wr_order_id<=order_id;
                    tab_wr_price<=price;
                    tab_wr_size<=size;
                    if(tab_wr_done)begin
                        error<=lut_wr_collision;
                        fsm_state<=FINISH;
                    end
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