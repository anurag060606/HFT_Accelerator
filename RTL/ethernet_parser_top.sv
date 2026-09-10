//integrating stripping, buffering and decoding
`default_nettype none

module ethernet_parser_top
    import itch_package::*;   
(
    input logic clk,
    input logic rst_n,
    input logic [7:0] s_tdata,
    input logic s_tvalid,
    input logic s_tlast,
    output logic s_tready,

    output itch_msg_t msg_out,
    output logic fifo_full_latched
);

    logic [7:0] stripped_data;
    logic stripped_tvalid, stripped_tready, stripped_tlast;

    ethernet_header_strip eth_strip(
        .clk(clk),
        .rst_n(rst_n),
        .s_tdata(s_tdata),
        .s_tvalid(s_tvalid),
        .s_tlast(s_tlast),
        .s_tready(s_tready),
        .m_tdata(stripped_data),
        .m_tvalid(stripped_tvalid),
        .m_tlast(stripped_tlast),
        .m_tready(stripped_tready)
    );

    //problem encountered during verification - m_tdata is expected to proivde the payload data to the fifo buffer byte by byte
    //for the same order there exists multiple bytes so how will the buffer differentiate between the bytes of one packet and the next packet
    //that why we need to have one indicator bit that indicates if a byte stored in fifo is from the same packet as above or a new packet altogether
    //so instead of just storing 8 bits each time in the fifo we store the byte+one indicator bit
    //the indicator bit is nothing but the tlast 
    //suppose the stripper produces 3 bytes
    // cycle 1:
    // strip_tdata  = AA
    // strip_tlast  = 0

    // cycle 2:
    // strip_tdata  = BB
    // strip_tlast  = 0

    // cycle 3:
    // strip_tdata  = CC
    // strip_tlast  = 1
    //so the fifo stores: 
    // ┌────────┬──────────┐
    // │ tlast  │   data   │
    // ├────────┼──────────┤
    // │   0    │    AA    │
    // │   0    │    BB    │
    // │   1    │    CC    │
    // └────────┴──────────┘


    assign stripped_tready=!fifo_full; //fifo can always accept data except when it is full


    logic [8:0] modified_fifo_wr_data, modified_fifo_rd_data;
    logic fifo_full, fifo_empty;

    assign modified_fifo_wr_data = {stripped_tlast,stripped_data};

    logic fifo_read_enable, decoder_tready;

    assign fifo_read_enable= (!fifo_empty) && (!fifo_read_valid || decoder_tready);//fifo should only read data when the decoder is not already decoding previous message and fifo is not empty


    ring_buffer  
    #(
        .WIDTH(9),
        .DEPTH(1024)
    )fifo_ring_buf
    (
        .clk(clk),
        .rst_n(rst_n),
        .wr_en(stripped_tvalid && stripped_tready),
        .wr_data(modified_fifo_wr_data),
        .rd_en(fifo_read_enable),
        .rd_data(modified_fifo_rd_data),
        .buffer_full(fifo_full),
        .buffer_empty(fifo_empty)
    );

    //debugging flag for fifo full
    always_ff @(posedge clk) begin
        if(!rst_n)
            fifo_full_latched<=1'b0;
        else if (fifo_full) fifo_full_latched<=1'b1;
    end

    //bram read latency adjustment
    logic fifo_read_valid;
    always_ff @( posedge clk ) begin
        if(!rst_n)
            fifo_read_valid<=0;
        else if(fifo_read_enable)
            fifo_read_valid<=1;    
        else if(decoder_tready)
            fifo_read_valid<=0; //decoder is asking but read is not enabled i.e. fifo is empty
    end
    
    itch_decoder decoder(
        .clk(clk),
        .rst_n(rst_n),
        .s_tdata(modified_fifo_rd_data[7:0]),
        .s_tvalid(fifo_read_valid),
        .s_tlast(modified_fifo_rd_data[8]),
        .s_tready(decoder_tready),
        .msg_out(msg_out)
    );
    
endmodule
`default_nettype wire