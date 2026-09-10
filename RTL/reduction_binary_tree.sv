//reduction binary tree sits on the top of the price leaf array
//the tree retrieves the best occupied price in the array 
//the prices are compared through a binary reduction tree
//each tree level selects ht better of two price indices from the level below it 
//this gradual reduction by a factor of 2 at each step eventually produces the best price index at the root 

//the tree can be fully combinational or pipeline registres can be inserted between two levels of the tree 
//adding pipelining register adds logN latency
//but pipelining becomes important when the depth of the tree increases, 
//the latency cost is a small price to pay for meeting timing violation

//if the number of leaves is not power of two we can pad the end of array with 0 

`default_nettype none

module reduction_binary_tree #(
    parameter int NUM_INDICES = 2000,
    parameter int WIDTH=32,
    parameter bit NEED_HIGH=1
) (

    input logic clk, rst_n,
    input logic [WIDTH-1:0] mem_in [NUM_INDICES],

    output logic [$clog2(NUM_INDICES)-1:0] best_indx,
    output logic best_valid
);
    function automatic int padder(int n);
        int p=1;
        while(p<n) 
            p=p<<1;
        return p;
    endfunction

    localparam int padded_length = padder(NUM_INDICES);
    localparam int indx_width=$clog2(padded_length);
    localparam tree_depth=$clog2(padded_length);

    typedef struct packed {
        logic [indx_width-1:0] indx;
        logic status_occupied;
    } tree_node;

    tree_node nodes [tree_depth+1][padded_length];//2d array to build the tree

    always_comb begin
        for(int i=0;i<padded_length;i++)begin
            if(i<NUM_INDICES)begin
                nodes[0][i].indx=indx_width'(i);
                nodes[0][i].status_occupied=(mem_in[i]!=0);
            end else begin
                nodes[0][i].indx=indx_width'(i);
                nodes[0][i].status_occupied=1'b0;
            end
        end
    end

    genvar depth_iterator, width_iterator;
    generate
        for(depth_iterator=1;depth_iterator<=tree_depth;depth_iterator++)begin: depth_iteration
            localparam width_at_curr_depth = padded_length>>depth_iterator;
            for(width_iterator=0;width_iterator<width_at_curr_depth;width_iterator++)begin: width_iteration
                tree_node left, right, winner;
                assign left=nodes[depth_iterator-1][2*width_iterator];
                assign right=nodes[depth_iterator-1][2*width_iterator+1];

                always_comb begin
                    if(NEED_HIGH)
                        winner=right.status_occupied ? right:left;
                    else
                        winner=left.status_occupied?left:right;
                end
                always_ff @( posedge clk ) begin
                    if(!rst_n) begin
                        nodes[depth_iterator][width_iterator].indx <= '0;
                        nodes[depth_iterator][width_iterator].status_occupied <= 1'b0;
                    end
                    else begin
                        nodes[depth_iterator][width_iterator].indx <= winner.indx;
                        nodes[depth_iterator][width_iterator].status_occupied <= winner.status_occupied;
                    end
                end
            end
        end
    endgenerate

    assign best_indx=indx_width'(nodes[tree_depth][0].indx);
    assign best_valid=nodes[tree_depth][0].status_occupied;
    
endmodule
`default_nettype wire