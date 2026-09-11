//forward compatible module
//the current implementation is quite sequential in the sense that only one itch message gets processed at a time i.e. that at a time, either a add/execute/cancel order accesses the memory and makes required change
//this single access is inherently safe and doesnt corrupt orderbook or introduce any need for arbitration mechanism since only one order is processed at a time
//right now there is only one requester asking to access the orderbook memory so there are no chances of collision (multiple simultaneous memory access)
//In some future version, there might be multiple independent requesters placing orders simultaneously which can lead to some of them requesting the same memory interface in the same cycle 
//Thus we will need an arbitration method to decide who gets the access
//This is a similar arbitration module which provides single point of control for price_leaves writes. Both add_order and decrease_Order need to update the leaf array and through this module we centralise that access instead of letting multiple independent modules access drive price_leaves_array directly  
//If in future multiple in flight book operations are introduced, only this module will have to be modified
//for this implementation im arbirarily choosing add_order over decrease order 
//future implementation can try round robin based (starvation free token based) to serve concurrent traffic

//reading about early ethernet protocols and their vision for future ethernet evolution thus their forward compatibility thinking has changed me in a way so that I think of stuff liek this lol

`default_nettype none

module mem_arbiter #(
    parameter int NUM_INDICES=2000,
    parameter int WIDTH=32
) (
    input logic clk, rst_n,
    //add_order in
    input logic add_req,
    input logic [$clog2(NUM_INDICES)-1:0] add_req_indx,
    input logic [WIDTH-1:0] add_req_change,
    input logic add_req_increment,
    output logic add_req_grant,

    //decrease_order in
    input logic dec_req,
    input logic [$clog2(NUM_INDICES)-1:0] dec_req_indx,
    input logic [WIDTH-1:0] dec_req_change,
    input logic dec_req_increment,
    output logic dec_req_grant,

    //direct to memory 
    output logic mem_wr_en,
    output logic [$clog2(NUM_INDICES)-1:0] mem_wr_indx,
    output logic mem_wr_increment, 
    output logic [WIDTH-1:0] mem_wr_change

);

    always_comb begin 
        add_req_grant=0;
        dec_req_grant=0;
        mem_wr_en=0;
        mem_wr_indx=0;
        mem_wr_increment=0;
        mem_wr_change=0;
        if(add_req)begin
            add_req_grant=1;
            mem_wr_en=1;
            mem_wr_indx=add_req_indx;
            mem_wr_increment=add_req_increment;
            mem_wr_change=add_req_change;
        end else if (dec_req) begin
            dec_req_grant=1;
            mem_wr_en=1;
            mem_wr_indx=dec_req_indx;
            mem_wr_increment=dec_req_increment;
            mem_wr_change=dec_req_change; 
        end
    end
    
endmodule
`default_nettype wire