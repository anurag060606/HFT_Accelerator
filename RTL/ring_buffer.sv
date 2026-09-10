//it is possible that the ITCH messages come at a faster rate than we can process them i.e. accomodate them in the order book
//in this case there is a possibility of packet dropping and missing out on updates
//in case the order book is overwhelmed it is necessary to control flow and temporarily store the incoming packets
//we can use bram to store packets, dual port bram are not neccessary since at a time only one packet can be processed downstream so we use single port bram
`default_nettype none

    module ring_buffer #(
        parameter DEPTH = 1024,
        parameter WIDTH=8

    ) (
        input logic clk, rst_n,

        input logic [WIDTH-1:0] wr_data,
        input logic wr_en,

        output logic [WIDTH-1:0] rd_data,
        input logic rd_en,

        output logic buffer_full,
        output logic buffer_empty
    );

        localparam int pointer_width=$clog2(DEPTH);

        logic [WIDTH-1:0] memory [DEPTH];
        logic [pointer_width:0] write_pointer, read_pointer;//1 bit more than required used because otherwise, both full and empty buffer will show write pointer at indx0, that extra bit distinguieshed between empthy and full
        assign buffer_empty=(write_pointer==read_pointer);
        assign buffer_full=(write_pointer[pointer_width-1:0]==read_pointer[pointer_width-1:0]) && (write_pointer[pointer_width]!=read_pointer[pointer_width]);
        
        always_ff @( posedge clk ) begin
            if(wr_en && !buffer_full)
                memory[write_pointer[pointer_width-1:0]]<=wr_data;
        end

        always_ff @(posedge clk)begin
            if(!rst_n)begin
                write_pointer<=0;
                read_pointer<=0;
            end else begin
                if(wr_en && !buffer_full) write_pointer<=write_pointer+1;
                if(rd_en && !buffer_empty) read_pointer<=read_pointer+1;
            end
        end

        always_ff @(posedge clk)begin
            if(rd_en && !buffer_empty)
                rd_data<=memory[read_pointer[pointer_width-1:0]];
        end
    endmodule
`default_nettype wire