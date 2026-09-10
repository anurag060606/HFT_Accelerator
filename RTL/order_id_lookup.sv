//the orderbook architecture we're following stores prices in a flat array indexed by price
//the element at a particular index tells us the orders at that price 

//but execute and cancel orders that come from exchange use order id to identify orders to be executed or cancelled 
//so this module maps order id to the array index of the order using a hash table and linear probing
//hash tables can occasionally encounter collision and the only way to mitigate it using even bigger hash tables
//this makes the latency of this module non deterministic, a characteristic that is usually avoided 
`default_nettype none

module order_id_lookup #(
    parameter int ORDER_ID_WIDTH=64,
    parameter int PRICE_WIDTH=32,
    parameter int SIZE_WIDTH     = 32,
    parameter int TABLE_DEPTH    = 4096,
    parameter int MAX_PROBE      = 4
) (
    input logic clk, rst_n,

    //ports to add an order

    input logic wr_en,
    input logic [ORDER_ID_WIDTH-1:0] wr_order_id, //the order id of the order you wanna add to the hashtable
    input logic [PRICE_WIDTH-1:0] wr_order_price, //the price of the order that is to be added to the table
    input logic [SIZE_WIDTH-1:0] wr_order_size, //the sis of the order that is to be added to the table
    output logic wr_recorded, //high when the order details are written into the map. this is necessary because when i was verifying the pipeline the linear probing caused the write process to take more than one cycles so lesson learned it is possible that a single write take more than one clock cycles
    output logic wr_collision_flag, //flag to signal that because of all probe slots being filled the insertion could not be possible, added after verification failed

    //ports to cancel execute an order
    input logic rd_en,//signals that a read has to be performed on the table
    input logic [ORDER_ID_WIDTH-1:0] rd_order_id,//order id of the order being retrieved
    input logic rd_and_remove,//does the order have to be removed from the hashtable after its been read
    output logic rd_executed, //has the order execution completed
    output logic rd_found, //was the order found
    output logic [PRICE_WIDTH-1:0] rd_price,//read the price of the order being executed
    output logic [SIZE_WIDTH-1:0] rd_size//read the sise of that order being executed

);

    localparam ADDR_WIDTH=$clog2(TABLE_DEPTH);
    typedef struct packed {
        logic valid;
        logic [ORDER_ID_WIDTH-1:0] order_id;
        logic [PRICE_WIDTH-1:0] price;
        logic [SIZE_WIDTH-1:0] size;
    } table_entry;

    table_entry hash_mem [TABLE_DEPTH];

    function automatic logic [ADDR_WIDTH-1:0] hash(logic [ORDER_ID_WIDTH-1:0] id);
        //now hash function can have a variety of implementations checkout data structs and algo course for that
        //to reduce collisions and clustering complex hash functions using xor can be made but here for simplification and quick prototyping purpose im using a simple modulus function where ADDR_WIDTH bits of the order ID will serve as the hash value for the order
        hash =id[ADDR_WIDTH-1:0];
    endfunction

    //what must be remembered during processing
    //i cannot guarantee that the upstream modules will keep the inputs to this module constant throughout the mutlicycle processing that it does so i should capture the inputs which will be needed in the procesing in this module
    logic [ORDER_ID_WIDTH-1:0] cptr_order_id ;
    logic [PRICE_WIDTH-1:0] cptr_price;
    logic [SIZE_WIDTH-1:0] cptr_size;
    logic cptr_rd_and_remove;
    logic [ADDR_WIDTH-1:0] probe_addr;
    int probe_count;

    typedef enum logic[1:0] {IDLE, WRITE, READ} states;
    states fsm_state;

    always_ff @(posedge clk)begin
        if(!rst_n)begin
            fsm_state<=IDLE;
            wr_recorded<=0;
            wr_collision_flag<=0;
            rd_executed<=0;
            rd_price<=0;
            rd_size<=0;
            rd_found<=0;
            probe_count<=0;
            probe_addr<=0;
            for(int i=0;i<TABLE_DEPTH;i++)
                //hash_mem[i].valid<=0;
                // the verilator doesnt sypport delayed assignment to array inside for loops, only non delayed are allowed so a verilator limitation i hate compiler limiatations
                hash_mem[i].valid=0; //workaround for the limitation; fix in vivado 

        end else begin
            wr_recorded<=0;
            rd_executed<=0;
            case (fsm_state)
                IDLE:begin
                    if(wr_en) begin
                        cptr_order_id<=wr_order_id;
                        cptr_price<=wr_order_price;
                        cptr_size<=wr_order_size;
                        probe_addr<=hash(wr_order_id);
                        probe_count<=0;
                    
                        fsm_state<=WRITE;
                    end else if(rd_en)begin
                        cptr_order_id<=rd_order_id;
                        cptr_rd_and_remove<=rd_and_remove;
                        probe_addr<=hash(rd_order_id);
                        fsm_state<=READ;
                    end
                end

                WRITE:begin
                    //write state starts by trying to write into the hashed address but if that is not possible i.e. if that place is occupied, just make it go to the next address i.e. linear probing and do this until you find an unoccupied slot or the memory ends i.e. the order coudn't be inserted
                    if(!hash_mem[probe_addr].valid || hash_mem[probe_addr].order_id == cptr_order_id) begin
                        hash_mem[probe_addr]<='{
                            valid:1'b1,
                            order_id:cptr_order_id,
                            price:cptr_price,
                            size:cptr_size
                        };
                        wr_recorded<=1;
                        wr_collision_flag<=0;
                        fsm_state<=IDLE;
                    end else if(probe_count == MAX_PROBE-1) begin
                        //if the maximum number of probes allowed for a given addr is exhausted, we reject the insert and notify the system that collision has taken place;
                        wr_recorded<=1;
                        wr_collision_flag<=1;
                        fsm_state<=IDLE;
                    end else begin
                        probe_addr<=probe_addr+1;
                        probe_count<=probe_count+1;
                    end
                end
                READ:begin
                    //try finding the order on the hashed address or the permissible range i.e. hashed address+ maxprobe count;
                    if(hash_mem[probe_addr].valid && hash_mem[probe_addr].order_id==cptr_order_id)begin
                        rd_found<=1;
                        rd_price<=hash_mem[probe_addr].price;
                        rd_size<=hash_mem[probe_addr].size;
                        if(cptr_rd_and_remove)
                            hash_mem[probe_addr].valid<=0;
                        rd_executed<=1;
                        fsm_state<=IDLE;
                    end else if(probe_count==MAX_PROBE)begin
                        rd_found<=0;
                        rd_executed<=1;
                        fsm_state<=IDLE;
                    end else begin
                        probe_addr<=probe_addr+1;
                        probe_count<=probe_count+1;
                    end
                end
                default:;
            endcase
        end
    end


    
    
endmodule
`default_nettype wire