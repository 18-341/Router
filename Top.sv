`default_nettype none
`include "Router.svh"
`include "RouterPkg.pkg"

//////
////// Network on Chip (NoC) 18-341
////// Router topology module
////// (You should not need to modify this file)
//////
module Top;
  // Top-level wires
  logic clock, reset_n;

  default clocking cb_main @(posedge clock); endclocking

  // Node-testbench wires
  pkt_t pkt_in[6];
  logic pkt_in_avail[6];
  logic cQ_full[6];
  pkt_t pkt_out[6];
  logic pkt_out_avail[6];

  // Node signals
  logic [5:0] free_node_router, put_node_router;
  logic [5:0] free_router_node, put_router_node;
  logic [5:0][7:0] payload_router_node;
  logic [5:0][7:0] payload_node_router;

  // Router-router wires
  logic free_r0_r1, put_r0_r1;
  logic free_r1_r0, put_r1_r0;
  logic [7:0] payload_r1_r0;
  logic [7:0] payload_r0_r1;

  // Router signals
  logic [1:0][3:0] free_router_out, put_router_in;
  logic [1:0][3:0] free_router_in, put_router_out;
  logic [1:0][3:0][7:0] payload_router_out;
  logic [1:0][3:0][7:0] payload_router_in;

  // Connect node inputs to router outputs
  assign free_node_router[0] = free_router_out[0][0];
  assign free_node_router[1] = free_router_out[0][2];
  assign free_node_router[2] = free_router_out[0][3];
  assign free_node_router[3] = free_router_out[1][0];
  assign free_node_router[4] = free_router_out[1][1];
  assign free_node_router[5] = free_router_out[1][2];

  assign put_router_node[0] = put_router_out[0][0];
  assign put_router_node[1] = put_router_out[0][2];
  assign put_router_node[2] = put_router_out[0][3];
  assign put_router_node[3] = put_router_out[1][0];
  assign put_router_node[4] = put_router_out[1][1];
  assign put_router_node[5] = put_router_out[1][2];

  assign payload_router_node[0] = payload_router_out[0][0];
  assign payload_router_node[1] = payload_router_out[0][2];
  assign payload_router_node[2] = payload_router_out[0][3];
  assign payload_router_node[3] = payload_router_out[1][0];
  assign payload_router_node[4] = payload_router_out[1][1];
  assign payload_router_node[5] = payload_router_out[1][2];

  // Connect router0 to router1
  assign free_r0_r1 = free_router_out[0][1];
  assign put_r0_r1 = put_router_out[0][1];
  assign payload_r0_r1 = payload_router_out[0][1];

  assign free_r1_r0 = free_router_out[1][3];
  assign put_r1_r0 = put_router_out[1][3];
  assign payload_r1_r0 = payload_router_out[1][3];

  // Connect router inputs to node outputs
  assign free_router_in[0] = {free_router_node[2], free_router_node[1],
                              free_r1_r0, free_router_node[0]};

  assign put_router_in[0] =  {put_node_router[2], put_node_router[1],
                              put_r1_r0, put_node_router[0]};

  assign payload_router_in[0] = {payload_node_router[2], payload_node_router[1],
                                 payload_r1_r0, payload_node_router[0]};

  assign free_router_in[1] = {free_r0_r1, free_router_node[5],
                              free_router_node[4], free_router_node[3]};

  assign put_router_in[1] = {put_r0_r1, put_node_router[5],
                             put_node_router[4], put_node_router[3]};

  assign payload_router_in[1] = {payload_r0_r1, payload_node_router[5],
                                 payload_node_router[4],
                                 payload_node_router[3]};

  // Testbench provides stimulus to the DUT
  RouterTB tb_inst(.*);

  // Generate routers and nodes, assigning them port numbers
  genvar i;

  // Create routers
  generate
    for(i=0; i<2; i++) begin : gen_router
      Router #(i)
        router_inst(.clock, .reset_n,
                    .free_outbound(free_router_in[i]),
                    .put_outbound(put_router_out[i]),
                    .payload_outbound(payload_router_out[i]),
                    .free_inbound(free_router_out[i]),
                    .put_inbound(put_router_in[i]),
                    .payload_inbound(payload_router_in[i]));
    end : gen_router
  endgenerate

  // Create nodes
  generate
    for(i=0; i<6; i++) begin : gen_node
      Node #(i)
        node_inst(.clock, .reset_n,
                  .pkt_in(pkt_in[i]),
                  .pkt_in_avail(pkt_in_avail[i]),
                  .cQ_full(cQ_full[i]),
                  .pkt_out(pkt_out[i]),
                  .pkt_out_avail(pkt_out_avail[i]),
                  .free_inbound(free_router_node[i]),
                  .put_inbound(put_router_node[i]),
                  .payload_inbound(payload_router_node[i]),
                  .free_outbound(free_node_router[i]),
                  .put_outbound(put_node_router[i]),
                  .payload_outbound(payload_node_router[i]));
    end : gen_node
  endgenerate
endmodule : Top
