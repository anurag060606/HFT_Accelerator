//after extracting itch data from the ethernet frame
//this module decodes the payload and 

`default_nettype none

package itch_package;
    typedef struct packed {
        logic [1:0] msg_type;
        logic valid;
        logic [63:0] order_id;
        logic [15:0] symbol_id;
        logic side;
        logic [31:0] price;
        logic [31:0] size;
    } itch_msg_t;
endpackage


module itch_decoder (
    input logic clk,
    input logic rst_n,
    input logic [7:0] s_tdata,
    input logic s_tvalid,
    input logic s_tlast,
    output logic s_tready,

    output itch_package::itch_msg_t msg_out
);

    assign s_tready=1'b1;//backpressure handled by fifo
    logic [7:0] byte_indx;
    logic [7:0] type_byte;
    logic [63:0] order_id;
    logic [15:0] symbol;
    logic [31:0] price;
    logic [31:0] size;

    function automatic logic [1:0] decode_type(logic [7:0] byte_in);
        case(byte_in)
            8'h41:
            //code to add a new order
                decode_type=2'b00;//simplified internal mapping
            8'h58:
            //code to add a new order
                decode_type=2'b01;//simplified internal mapping
            8'h45:
            //code to add a new order
                decode_type=2'b10;//simplified internal mapping
            8'h44:
            //code to add a new order
                decode_type=2'b11;//simplified internal mapping
        endcase
    endfunction

    function automatic logic relevant_type(logic [7:0] byte_in);
        relevant_type=(byte_in==8'h41) || (byte_in==8'h58) || (byte_in==8'h45) || (byte_in==8'h44);
    endfunction

    always_ff @(posedge clk)begin
        if(!rst_n)begin
            byte_indx<='0;
            msg_out.valid<=0;
        end else begin
            msg_out.valid<=0;
        
            if(s_tvalid && s_tready)begin
                msg_out.valid<=0;
                if(byte_indx==0)begin
                    type_byte<=s_tdata;
                end
                case(byte_indx)
                    1,2,3,4,5,6,7,8: order_id<={order_id[55:0],s_tdata};//when we get new byte push the old already collected data to the left and concatenate the new input byte
                    9,10:symbol<={symbol[7:0],s_tdata};
                    11:; //side byte just a single byte so we can handle it separately 
                    12,13,14,15: price<={price[23:0],s_tdata};
                    16,17,18,19: size<={size[23:0], s_tdata};
                    default:;
                endcase

                if(byte_indx==19)begin
                    if(relevant_type(type_byte))begin
                        msg_out.msg_type<=decode_type(type_byte);
                        msg_out.valid<=1;
                        msg_out.order_id<=order_id;
                        msg_out.symbol_id<=symbol;
                        //msg_out.side handle separately
                        msg_out.price<=price;
                        msg_out.size<={size[23:0],s_tdata};//final byte taken in directly because otherwise we'd have to wait one clock cycle because of nonblocking assignment in case block
                    end
                end

                if(byte_indx==11)begin
                    msg_out.side<=s_tdata[0];
                end

                if(s_tlast)
                    byte_indx<=0;
                else 
                    byte_indx<=byte_indx+1;
            end
        end
    end
endmodule
`default_nettype wire