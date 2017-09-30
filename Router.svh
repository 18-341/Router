`ifndef ROUTER_H
  `define ROUTER_H

  `define NODES 6
  `define QUEUE_DEPTH 4

  `define MAX_DELAY 10
  `define NUM_STRESS 100
  `define NUM_FAIRNESS 1000
  `define NUM_PERFORMANCE 10000
  `define NULL_PKT {src: 4'd0, dest: 4'd0, data: 24'h00_00_00}
`endif
