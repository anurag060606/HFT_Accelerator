//for orderbook im using a simple distributed ram implementation
//using dense memory like bram uram could be an alternative but due to read latency and port limitation of bram it is much more easier and straightforward to work with distributed ram if you're not resource constrained
//we will be using price indexed array to store the number of stocks to buy/sell 
//for quick retrieval we map the order price to a leaf index in the price indexed array 
//since the price of a stock only changes by a few dollars (3-15%) in a trading session, the minimum and maximum price of a stock for a trading session can be assumed to be between P_max and P_min
//any order with price out of this range would be explicitly rejected instead of getting clipped wrapped or corrupting the existing orderbook 
//tick size is the smallest price increment that an order can have on an exchange
//a defined tick size discretizes the continuous price range into fixed price levels making it possible to map prices to integer indices in a digital system like ours
//tick size in our implementation is defined as power of 2 which is not true for real exchanges where tick size is usually 1 cent or 5 cents i.e. decimal values, but using tick sise as power of 2 makes it easier to implement in hardware because a divider circuit is too expensive to implement in hardware and a power of 2 tick size can be implemented using a simple right shift operation


`default_nettype none

module price_indx_mapper #(
    parameter  int WIDTH  = 32,
    parameter int P_MIN= 32'd9000,//$90 default min
    parameter int P_MAX=32'd11000,//$110 deafult max
    parameter int TICK=32'd1//1 cent default tick size 
) (
    input logic [WIDTH-1:0] price_in,
    
    output logic valid_out,
    output logic [$clog2((P_MAX-P_MIN)>>TICK):0]  indx_out,


    output logic [$clog2((P_MAX-P_MIN)>>TICK):0]  indx_in,
    output logic [WIDTH-1:0] price_out
);
    localparam int num_possible_indices = (P_MAX-P_MIN)>>TICK;
    //11000-9000=2000 cents difference
    //if tick =1, there will be 2000 levels of prices
    //if tick = 2 there will be 1000 levels of prices
    //if tick =4 there will be 500 levels of prices

    always_comb begin
        if(price_in<P_MIN || price_in >= P_MAX) begin
            valid_out=0;
        end else begin
            valid_out=1;
            indx_out=(price_in-P_MIN)>>TICK;
        end
    end

    assign price_out = P_MIN+(indx_in << TICK);

endmodule
`default_nettype wire