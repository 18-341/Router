`default_nettype none
`include "RouterPkg.pkg"

// Top module
module top();

  // top-level wires
  logic clock, reset_n;

  // node-testbench wires
  pkt_t node_in;
  bit node_in_avail;
  bit cQ_full;
  pkt_t node_out;
  bit node_out_avail;

  // node-router wires
  bit free_node_router, put_node_router;
  bit free_router_node, put_router_node;
  bit [7:0] payload_router_node;
  bit [7:0] payload_node_router;

  Node #(0) node_inst(.clock, .reset_n,
                      .pkt_in(node_in),
                      .pkt_in_avail(node_in_avail),
                      .cQ_full,
                      .pkt_out(node_out),
                      .pkt_out_avail(node_out_avail),
                      .free_inbound(free_router_node),
                      .put_inbound(put_router_node),
                      .payload_inbound(payload_router_node),
                      .free_outbound(free_node_router),
                      .put_outbound(put_node_router),
                      .payload_outbound(payload_node_router));

  tb tb_inst(.*);

endmodule

// Node testbench
module tb(
    output logic clock, reset_n,
    output pkt_t node_in,
    output bit node_in_avail,
    input  bit cQ_full,
    input  pkt_t node_out,
    input  bit node_out_avail,
    input  bit free_router_node, put_node_router,
    output bit free_node_router, put_router_node,
    output bit [7:0] payload_router_node,
    input  bit [7:0] payload_node_router
  );

`protect

  // router receive logic
  pkt_t router_in;

  // error count
  int errors = 0;

  // testbench queues
  logic [31:0] expect_node[$], expect_router[$], expected;

  // testbench clock
  initial begin
    clock = 1;
    forever #5 clock = ~clock;
  end

  // helpful testbench tasks
  task reset_dut();
    $display("Resetting dut...");
    node_in_avail = 0;
    free_node_router = 0;
    put_router_node = 0;
    reset_n = 0;
    #5;
    reset_n = 1;
    $display("Reset complete");
  endtask

  task send_node(input pkt_t pkt);
    $display("Placing a packet in the queue...");
    assert (cQ_full === 1'b0)
    else begin $error("Trying to send a packet but cQ_full is %b!", cQ_full); errors++; end
    node_in <= pkt;
    node_in_avail <= 1;
    @(posedge clock);
    node_in_avail <= 0;
    expect_router.push_back(pkt);
  endtask

  task send_router(input pkt_t pkt);
    $display("Transfering data from router to node...");
    assert (free_router_node === 1'b1)
    else begin $error("Trying to send a packet but free_router_node is %b!", free_router_node); errors++; end
    put_router_node <= 1;
    payload_router_node <= {pkt.src, pkt.dest};
    @(posedge clock);
    payload_router_node <= pkt.data[23:16];
    @(posedge clock);
    payload_router_node <= pkt.data[15:8];
    @(posedge clock);
    payload_router_node <= pkt.data[7:0];
    @(posedge clock);
    put_router_node <= 0;
    expect_node.push_back(pkt);
  endtask

  task recv_router();
    free_node_router <= 1;
    while (put_node_router !== 1'b1)
      @(posedge clock);
    free_node_router <= 0;
    {router_in.src, router_in.dest} = payload_node_router;
    @(posedge clock);
    router_in.data[23:16] = payload_node_router;
    @(posedge clock);
    router_in.data[15:8] = payload_node_router;
    @(posedge clock);
    router_in.data[7:0] = payload_node_router;
    assert (!expect_router.empty())
    else begin $error("Didn't expect packet on router interface, got %x", router_in); errors++; end
    expected = expect_router.pop_front();
    assert (expected == router_in)
    else begin $error("Expected %x on router interface, got %x", expected, router_in); errors++; end
    @(posedge clock);
  endtask

  task recv_router_timeout(int timeout);
    fork

      recv_router();

      begin
        repeat (timeout) @(posedge clock);
        $error("Timeout waiting for packet"); errors++;
      end

    join_any
    disable fork;
    free_node_router <= 0;
  endtask

  task wait_for_quiescence(int timeout);
    fork

      while (!expect_router.empty() || !expect_node.empty()) @(posedge clock);

      forever recv_router();

      begin
        repeat (timeout)
          @(posedge clock);
        $error("Timeout waiting for packets"); errors++;
      end

    join_any
    disable fork;
    free_node_router <= 0;
  endtask

  // node monitor
  always @(posedge clock) begin
    if (node_out_avail === 1'b1) begin
      expected = expect_node.pop_front();
      assert (expected == node_out)
      else begin $error("Expected %x from node interface, got %x", expected, node_out); errors++; end
    end
  end

  // testbench input generation
  initial begin
    $display("*****************************************");
    $display("*** PLEASE NOTE                       ***");
    $display("*** This testbench is not exhaustive, ***");
    $display("*** you should do your own testing as ***");
    $display("*** well. You may find more node      ***");
    $display("*** problems after hooking it up to   ***");
    $display("*** your router design later.         ***");
    $display("*****************************************");

    reset_dut();

    $display("Checking cQ_full status after reset");
    assert (cQ_full === 1'b0)
    else begin $error("cQ_full is %b", cQ_full); errors++; end

    $display("Checking single packet node->router");
    send_node(32'h12345678);
    wait_for_quiescence(6);

    $display("Checking FIFO length");
    send_node(32'h12345678);
    send_node(32'h9ABCDEF0);
    send_node(32'h0FEDCBA9);
    send_node(32'h87654321);
    send_node(32'hCAFEF00D);
    @(posedge clock);
    assert (cQ_full === 1'b1)
    else begin $error("cQ_full is %b", cQ_full); errors++; end

    $display("Accepting one packet on the router interface");
    recv_router_timeout(6);
    @(posedge clock);
    assert (cQ_full === 1'b0)
    else begin $error("cQ_full is %b", cQ_full); errors++; end

    $display("Placing one more packet into the queue");
    send_node(32'hDEADBEEF);
    @(posedge clock);
    assert (cQ_full === 1'b1)
    else begin $error("cQ_full is %b", cQ_full); errors++; end

    $display("Flushing remaining packets");
    wait_for_quiescence(50);

    reset_dut();

    $display("Checking single packet router->node");
    send_router(32'h05EAF00D);
    wait_for_quiescence(6);

    $display("Checking simultaneous packets router->node and node->router");
    send_node(32'h51617181);
    send_node(32'hF2F3F4F5);
    send_router(32'h01020304);
    // We want it to show up immediately even though there are packets flowing
    // from node to router
    recv_router_timeout(6);
    wait_for_quiescence(50);

    if (errors > 0) begin
      $display("Final error count: %1d", errors);
      $display("TEST FAILED");
    end else
      $display("TEST PASSED");

    $finish;
  end

`endprotect

endmodule
