`default_nettype none

module ethernet_header_strip (
    input clk,
    input rst_n,

    //receiving end= slave
    input logic [7:0] s_tdata,
    input logic s_tvalid,
    input logic s_tlast,
    output logic s_tready,

    //transmitting end= master
    output logic [7:0] m_tdata,
    output logic m_tvalid,
    output logic m_tlast,
    input logic m_tready
);


//on the conception of an ethernet frame, we must strip the encapsulation layers and extract actual financial data to feed to the pipeline ahead

//ETHERNET FRAME FORMAT:
//Ethernet frame
    // ethernet header
    //     destination mac 6byte
    //     source mac 6byte
    //     ethertype 2byte = total 14 ethernet byte
    // ipv4 packet
    //     ipv4 header
    //         version
    //         ihl
    //         ....
    //         protocol
    //         ....
    //     udp packet
    //         udp header
    //             source port 2byte
    //             destination port 2byte
    //             length 2byte
    //             checksum 2byte
    //         itchdata

//IPv4 header format
//   0       4       8              16                    31
//   ┌───────┬───────┬───────────────┬─────────────────────┐
//   │Version│  IHL  │   DSCP/ECN    │    Total Length     │
//   ├───────┴───────┼───────────────┼─────────────────────┤
//   │ Identification│ Flags         │ Fragment Offset     │
//   ├───────────────┴───────────────┼─────────────────────┤
//   │    TTL        │   Protocol    │   Header Checksum   │
//   ├─────────────────────────────────────────────────────┤
//   │                 Source IP Address                   │
//   ├─────────────────────────────────────────────────────┤
//   │              Destination IP Address                 │
//   ├─────────────────────────────────────────────────────┤
//   │                  Options (optional)                 │
//   └─────────────────────────────────────────────────────┘

//bytes to remove = 14(Ethernet header)+ 20(IPv4 header) + 8 (UDP header)
    localparam int eth_frame_end = 13;
    localparam int eth_type=12; //12,13 make up the eth type (ipv4 0x0800, ipv6 0x86DD or arp 0x0806)
    localparam int ip_start=14;
    localparam int ihl_byte=14;//version + IHL byte
    localparam int protocol_byte=23;//10th byte from start of ipv4 header 13+10=23
    localparam int ip_end=33;//20 bytes of ipvv4 header (no optional fields considered) 13+20=33 field start of udp histogram
    localparam int udp_end=41;//8 bytes of header of udp 33+8=41

    typedef enum logic [1:0] { IDLE, HEADER, PAYLOAD, DROP } state;
    state fsm_state;
    logic [7:0] byte_indx;
    logic [7:0] ether_type;
    logic is_ipv4, is_udp;

    logic transfer_valid;
    assign transfer_valid= s_tvalid && s_tready;//transfer only happens when the data from upstream is valid and the module can take data in 

    assign s_tready= (fsm_state==PAYLOAD)?m_tready:1'b1;
    assign m_tdata=s_tdata;
    assign m_tlast=s_tlast;
    assign m_tvalid = s_tvalid && (fsm_state == PAYLOAD);

    always_ff @(posedge clk) begin
        if(!rst_n)begin
            fsm_state<=IDLE;
            byte_indx<='0;
            is_ipv4<=1'b0;
            is_udp<=1'b0;
            ether_type='0;
        end else if(transfer_valid) begin
            if(s_tlast && fsm_state !=PAYLOAD)begin
                fsm_state<=IDLE;
                byte_indx<=0;
            end else begin
                case (fsm_state)
                    IDLE: begin
                        byte_indx<=1;
                        fsm_state<=HEADER;
                        if(s_tlast) begin
                            fsm_state<=IDLE;
                        end
                    end
                    HEADER:begin
                        if(byte_indx==eth_type)
                            ether_type=s_tdata;
                        if(byte_indx==eth_type+1)begin
                            is_ipv4 <= (ether_type==8'h08) && (s_tdata == 8'h00);
                        end
                        //check if the header is 20 bytes and thus has no addiitonal optional fields
                        //if optional fields then drop the shit because tis aint made for it
                        if(byte_indx==ihl_byte && s_tdata[3:0] !=4'h5)
                            fsm_state<=DROP; //if not 20 byte length stop the parsing drop the frame
                        if(byte_indx==protocol_byte)
                            is_udp<=(s_tdata==8'h11);

                        if(byte_indx==udp_end)
                            fsm_state<=(is_ipv4 && is_udp)? PAYLOAD: DROP;
                        byte_indx<=byte_indx+1;
                    end
                    
                    PAYLOAD:begin
                        if(s_tlast)begin
                            fsm_state<=IDLE;
                            byte_indx<='0;
                        end
                    end
                    
                    DROP:begin
                        if(s_tlast)begin
                            fsm_state<=IDLE;
                            byte_indx<='0;
                        end
                    end
                endcase
            end
        end
    end
endmodule
`default_nettype wire