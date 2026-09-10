//actualizing the distributed ram memory architecture for holdin aggregate resting size across every order currently at that price
//caveat: using distributed memory is alright for less memory and resource unconstrained design. using dense memory like bram uram becomes necessary when many items have to be stored
//low latency design with bram becomes tricky due to its read latency and limited port access 
//future scope: use bram and registered read for larger price range

module price_leaves_array #(
    parameter int NUM_INDICES=2000,
    parameter int WIDTH=32
) (
    input logic clk,rst_n, wr_en,
    input logic [$clog2(NUM_INDICES)-1:0] wr_indx;
    input logic wr_increment;
    input logic [WIDTH-1:0] change;
    output logic [WIDTH-1:0] mem_exposed [NUM_INDICES];
);

    logic [WIDTH-1:0] mem [NUM_INDICES];

    always_ff @( posedge clk ) begin
        if(!rst_n) begin
            for(int i=0;i<NUM_INDICES;i=i+1)
                mem[i]<=0;
        end else if(wr_en) begin //order book has to register a change because parser sent something 
            if(wr_increment)
                mem[wr_indx]<=mem[wr_indx]+change;
            else
                mem[wr_indx]<= (mem[wr_indx>change])?(mem[wr_indx]-change):0;
        end
    end
    assign mem_exposed=mem;
endmodule

`default_nettype wire