`default_nettype none
`include "Router.svh"
`include "RouterPkg.pkg"

//////
////// Network on Chip (NoC) 18-341
////// (created S'17, Daniel Stiffler)
//////

////
//// The NoC Testbench
////
////   cQ_full       (input)  - Node queue status indicators
////   pkt_out       (input)  - NoC packets outbound from router
////   pkt_out_avail (input)  - Router has a packet for collection
////   clock         (output) - The clock
////   reset_n       (output) - Asynchronous reset
////   pkt_in        (output) - NoC packets inbound to router
////   pkt_in_avail  (output) - Testbench has a packet for transmission
////
//// Testbench Usage
////   1. Compile your code using the Makefile supplied "make {full/clean}"
////   2. Run the testbench with one or more of the following runtime arguments
////      ./simv {-gui} {+{plusargs ... }} {+vcs+finish+{d}} {+VERBOSE={1,2,3}}
////      e.g. ./simv -gui +STRESS +PERFORMANCE +vcs+finish+10000 +VERBOSE=3
////
////     - +BASIC:       transfer one packet at a time between every node pair
////                     within the same router
////     - +ACROSS:      transfer one packet at a time between every node pair
////                     going across the bridge
////     - +BROADCAST:   test triangular concurrency between every node pair in
////                     the same router; for example 0->1 1->2 2->3
////                     simultaneously
////     - +STRESS:      TB every node to bombard a single destination with
////                     packets to stress internal queues
////     - +FAIRNESS:    TB checks for transaction fairness at each destination
////                     node by sending three packets simultaneously
////     - +PERFORMANCE: deterministically measures router performance under
////                     real-world conditions
////
module automatic RouterTB (
  input logic cQ_full[`NODES],
  input pkt_t pkt_out[`NODES],
  input logic pkt_out_avail[`NODES],
  output logic clock, reset_n,
  output pkt_t pkt_in[`NODES],
  output logic pkt_in_avail[`NODES]);

  /* !!WARNING!!
   *   For some reason, VCS does not treat ##N cycle delays as blocking events
   *   inside threads so you must use repeat(N) @(posedge clock) instead
   */
  default clocking cb_main @(posedge clock); endclocking

  // Wrapper for NoC packets to allow for inter-process synchronizaton
  class PktWrapper;
    rand pkt_t pkt; // NoC packet
    time send_time, recv_time; // Packet creation and receive times
    event received; // Inter-process event

    constraint legal_pkt {
      pkt.src != pkt.dest;
      pkt.src inside {[0:`NODES-1]};
      pkt.dest inside {[0:`NODES-1]};}

    function new;
      this.send_time = $time;
    endfunction : new
  endclass : PktWrapper

  // Inter-process FIFOs to track transactions outside the main process
  mailbox #(PktWrapper) send_M[`NODES][`NODES];
  mailbox #(PktWrapper) recv_M;

  // Semaphore to prevent overlapping sends from the same node
  semaphore node_sem[`NODES];

  integer debug_level = 0;
  initial $value$plusargs("VERBOSE=%d", debug_level);

  // Conduct a system reset and flush the inter-process communications
  task do_reset;
    $srandom(18341);
    reset_n = 1'b1;
    reset_n = 1'b0;

    // Initialize inter-process FIFOs with no bound
    for (int i=0; i<`NODES; i++) begin
      for (int j=0; j<`NODES; j++) begin
        send_M[i][j] = new(0);
      end
    end
    if (debug_level > 2) $info("Initialized send_M mailboxes");

    recv_M = new(0);
    if (debug_level > 2) $info("Initialized recv_M mailbox");

    // Initialize semaphores as mutexes
    for (int i=0; i<`NODES; i++) begin
      node_sem[i] = new(1);
    end
    if (debug_level > 2) $info("Initialized source semaphores");

    reset_n <= 1'b1;
  endtask : do_reset

  /*
   * Passive receiver responsible for collecting outbound packets from the router
   * and checking that they are legitimate
   */
  task automatic monitor_recv(input int node_id);
    pkt_t pkt_from_node;
    PktWrapper pkt_from_M;

    if (debug_level > 2) $info("Setting up monitor for node %0d", node_id);

    forever begin
      @(posedge pkt_out_avail[node_id]);

      pkt_from_node = pkt_out[node_id];

      assert(pkt_from_node.dest == node_id) else
        $error("Monitor%0d detected packet with incorrect dest=%d",
               node_id,
               pkt_from_node.dest);

      if (send_M[pkt_from_node.src]
                [pkt_from_node.dest].try_get(pkt_from_M)) begin
        pkt_from_M.recv_time = $time;

        assert (pkt_from_M.pkt.src == pkt_from_node.src) else
          $error({"Monitor%0d detected violation of sequential consistency ",
                  "for packet {src: %d, dest: %d, data: %h}, expected ",
                  "{src: %d, dest: %d, data: %h} from mailbox"},
                 node_id,
                 pkt_from_node.src, pkt_from_node.dest, pkt_from_node.data,
                 pkt_from_M.pkt.src, pkt_from_M.pkt.dest, pkt_from_M.pkt.data);

        assert(pkt_from_M.pkt.data == pkt_from_node.data) else
          $error({"Monitor%0d detected corrupted data %h corresponding to %h ",
                  "from mailbox"},
                 node_id,
                 pkt_from_node.data, pkt_from_M.pkt.data);

        if (debug_level > 1) begin
          $info({"Monitor%0d detected packet {src: %d, dest: %d, data: %h} ",
                 "sent @%0t and received @%0t"},
                node_id,
                pkt_from_M.pkt.src, pkt_from_M.pkt.dest, pkt_from_M.pkt.data,
                pkt_from_M.send_time, pkt_from_M.recv_time);
        end

        recv_M.put(pkt_from_M);
        -> pkt_from_M.received; // Notify blocking process in send_pkt
      end else begin
        $error({"Monitor%0d detected untracked packet ",
                "{src: %d, dest: %d, data: %h}"},
               node_id,
               pkt_from_node.src, pkt_from_node.dest, pkt_from_node.data);
        $finish;
      end
    end
  endtask : monitor_recv

  /*
   * Blocking task to send packets to the nodes one at time and confirm receipt
   * before passing
   */
  task automatic send_pkt(input int src=-1, dest=-1,
                          input bit do_delay=1'b0);
    PktWrapper pkt_to_M;

    if (src == -1) src = $urandom_range(`NODES-1);

    node_sem[src].get(1); // BEGIN critical region
      pkt_to_M = new();
      if (dest == -1) begin
        pkt_to_M.randomize() with {pkt.src == src;};
      end else begin
        pkt_to_M.randomize() with {pkt.src == src; pkt.dest == dest;};
      end
      dest = pkt_to_M.pkt.dest;

      #1 ;
      wait(~cQ_full[src]); // Must check after reactive region
      if (do_delay) repeat($urandom_range(`MAX_DELAY)) @(cb_main);

      assert(~cQ_full[src]) else begin
        $error("Node queue unexpectedly became full, should not attempt");
        $finish;
      end

      pkt_in[src] <= pkt_to_M.pkt;
      pkt_in_avail[src] <= 1'b1;
      send_M[src][dest].put(pkt_to_M);

      if (debug_level > 1) begin
        $info("Testbench dispatched packet from %d to %d",
              pkt_to_M.pkt.src, pkt_to_M.pkt.dest);
      end

      @(posedge clock); // See warning, this must be a blocking event
      pkt_in[src] <= `NULL_PKT;
      pkt_in_avail[src] <= 1'b0;

    node_sem[src].put(1); // END critical region

    wait(pkt_to_M.received.triggered); // Block process
  endtask : send_pkt

  initial begin
    clock = 1'b0;
    forever #5 clock = ~clock;
  end

  // Unconditional timeout so that students do not have to worry about hanging
  initial begin
    ##10000000 ;
    $display("%m @%0t: Testbench issued timeout", $time);
    $finish;
   end

  // Spawn node monitors
  initial begin
    fork // Isolating thread
      for (int i=0; i<`NODES; i++) begin
        automatic int fork_i = i;
        fork
          monitor_recv(fork_i);
        join_none
      end
    join
  end

  initial begin
    PktWrapper tmp_1, tmp_2, tmp_3;
    logic [3:0][`NUM_FAIRNESS-1:0] fair_order[`NUM_FAIRNESS]; // FAIRNESS
    integer cycle_count = 0; // PERFORMANCE

    pkt_in = '{default: '0}; // `NULL_PKT placeholder
    pkt_in_avail = '{default: 1'b0};

    if ($test$plusargs("BASIC")) begin
      $display({"\n",
                "-----------------------------------------------------------\n",
                " <Started> Basic Send/Recv Test\n",
                "-----------------------------------------------------------",
                "\n"});
      do_reset;
      ##1 ;

      $display("Sending packets inside router 1");
      for (int i=0; i<3; i++) begin
        for (int j=0; j<3; j++) begin
          if (i == j) continue;

          send_pkt(i, j, 1'b1);
        end
      end

      $display("Sending packets inside router 2");
      for (int i=4; i<6; i++) begin
        for (int j=4; j<6; j++) begin
          if (i == j) continue;

          send_pkt(i, j, 1'b1);
        end
      end

      $display({"\n",
                "-----------------------------------------------------------\n",
                " <Finished> Basic Send/Recv Test\n",
                "-----------------------------------------------------------",
                "\n"});
    end

    if ($test$plusargs("ACROSS")) begin
      $display({"\n",
                "-----------------------------------------------------------\n",
                " <Started> Across-router Send/Recv Test\n",
                "-----------------------------------------------------------",
                "\n"});
      do_reset;
      ##1 ;

      $display("Sending packets from router 1 to router 2");
      for (int i=0; i<3; i++) begin
        for (int j=4; j<6; j++) begin
          send_pkt(i, j, 1'b1);
        end
      end

      $display("Sending packets from router 2 to router 1");
      for (int i=4; i<6; i++) begin
        for (int j=0; j<3; j++) begin
          send_pkt(i, j, 1'b1);
        end
      end

      $display({"\n",
                "-----------------------------------------------------------\n",
                " <Finished> Across-router Send/Recv Test\n",
                "-----------------------------------------------------------",
                "\n"});
    end

    if ($test$plusargs("BROADCAST")) begin
      $display({"\n",
                "-----------------------------------------------------------\n",
                " <Started> Broadcast Concurrency Test\n",
                "-----------------------------------------------------------",
                "\n"});
      do_reset;
      ##1 ;

      $display("Sending packets inside router 1");
      for (int i=0; i<3; i++) begin
        automatic int fork_i = i;
        fork
          send_pkt((fork_i+0)%3, (fork_i+1)%3);
          send_pkt((fork_i+1)%3, (fork_i+2)%3);
          send_pkt((fork_i+2)%3, (fork_i+0)%3);
        join

        recv_M.get(tmp_1);
        recv_M.get(tmp_2);
        recv_M.get(tmp_3);

        assert(tmp_1.recv_time == tmp_2.recv_time
               && tmp_2.recv_time == tmp_3.recv_time) else
          $error("Packets to nodes %d %d %d were not received simultaneously",
                 tmp_1.pkt.dest, tmp_2.pkt.dest, tmp_3.pkt.dest);
      end

      $display("Sending packets inside router 2");
      for (int i=0; i<3; i++) begin
        automatic int fork_i = i;
        fork
          send_pkt(3 + (fork_i+0)%3, 3 + (fork_i+1)%3);
          send_pkt(3 + (fork_i+1)%3, 3 + (fork_i+2)%3);
          send_pkt(3 + (fork_i+2)%3, 3 + (fork_i+0)%3);
        join

        recv_M.get(tmp_1);
        recv_M.get(tmp_2);
        recv_M.get(tmp_3);

        assert(tmp_1.recv_time == tmp_2.recv_time
               && tmp_2.recv_time == tmp_3.recv_time) else
          $error("Packets to nodes %d %d %d were not received simultaneously",
                 tmp_1.pkt.dest, tmp_2.pkt.dest, tmp_3.pkt.dest);
      end

      $display({"\n",
                "-----------------------------------------------------------\n",
                " <Finished> Broadcast Concurrency Test\n",
                "-----------------------------------------------------------",
                "\n"});
    end

    if ($test$plusargs("STRESS")) begin
      $display({"\n",
                "-----------------------------------------------------------\n",
                " <Started> Node Stress Test\n",
                "-----------------------------------------------------------",
                "\n"});
      do_reset;
      ##1 ;

      for (int i=0; i<`NODES; i++) begin
        automatic int fork_i = i;
        $display("Stressing destination port %0d", i);

        fork // Isolating thread
          begin
            for (int j=0; j<`NUM_STRESS; j++) begin
              fork
                send_pkt(fork_i,,1'b1);
              join_none
            end

            wait fork;
          end
        join
      end

      $display({"\n",
                "-----------------------------------------------------------\n",
                " <Finished> Node Stress Test\n",
                "-----------------------------------------------------------",
                "\n"});
    end

    if ($test$plusargs("FAIRNESS")) begin
      $display({"\n",
                "-----------------------------------------------------------\n",
                " <Started> Fairness Test\n",
                "-----------------------------------------------------------",
                "\n"});
      do_reset;
      ##1 ;

      $display("Checking fairness in router 1");
      for (int i=0; i<3; i++) begin
        automatic int fork_i = i;

        for (int j=0; j<`NUM_FAIRNESS; j++) begin
          fork
            begin
              send_pkt(4, fork_i, 1'b0);
            end

            begin
              // See warning, this must be a blocking event
              repeat(6) @(posedge clock) ;
              send_pkt((fork_i+1)%3, fork_i, 1'b0);
            end

            begin
              // See warning, this must be a blocking event
              repeat(6) @(posedge clock) ;
              send_pkt((fork_i+2)%3, fork_i, 1'b0);
            end
          join

          recv_M.get(tmp_1);
          recv_M.get(tmp_2);
          recv_M.get(tmp_3);

          fair_order[i] = {tmp_1.pkt.src, tmp_2.pkt.src, tmp_3.pkt.src};
        end
      end

      assert(fair_order[0] != fair_order[1] && fair_order[1] != fair_order[2]
             && fair_order[2] != fair_order[0]) else
        $error({"Fairness was not upheld for the following orderings:\n",
                "(%d %d %d) (%d %d %d) (%d %d %d)"},
               fair_order[0][0], fair_order[0][1], fair_order[0][2],
               fair_order[1][0], fair_order[1][1], fair_order[1][2],
               fair_order[2][0], fair_order[2][1], fair_order[2][2]);

      $display("Checking fairness in router 2");
      for (int i=0; i<3; i++) begin
        automatic int fork_i = i;

        for (int j=0; j<`NUM_FAIRNESS; j++) begin
          fork
            begin
              send_pkt(0, 3 + fork_i, 1'b0);
            end

            begin
              // See warning, this must be a blocking event
              repeat(6) @(posedge clock) ;
              send_pkt(3 + (fork_i+1)%3, 3 + fork_i, 1'b0);
            end

            begin
              // See warning, this must be a blocking event
              repeat(6) @(posedge clock) ;
              send_pkt(3 + (fork_i+2)%3, 3 + fork_i, 1'b0);
            end
          join

          recv_M.get(tmp_1);
          recv_M.get(tmp_2);
          recv_M.get(tmp_3);

          fair_order[i] = {tmp_1.pkt.src, tmp_2.pkt.src, tmp_3.pkt.src};
        end
      end

      assert(fair_order[0] != fair_order[1] && fair_order[1] != fair_order[2]
             && fair_order[2] != fair_order[0]) else
        $error({"Fairness was not upheld for the following orderings:\n",
                "(%d %d %d) (%d %d %d) (%d %d %d)"},
               fair_order[0][0], fair_order[0][1], fair_order[0][2],
               fair_order[1][0], fair_order[1][1], fair_order[1][2],
               fair_order[2][0], fair_order[2][1], fair_order[2][2]);

      $display({"\n",
                "-----------------------------------------------------------\n",
                " <Finished> Fairness Test\n",
                "-----------------------------------------------------------",
                "\n"});
    end

    if ($test$plusargs("PERFORMANCE")) begin
      $display({"\n",
                "-----------------------------------------------------------\n",
                " <Started> Performance Test\n",
                "-----------------------------------------------------------",
                "\n"});
      do_reset;
      ##1 ;

      fork // Isolating thread
        begin
          for (int i=0; i<`NUM_PERFORMANCE; i++) begin
            fork
              send_pkt(,,1'b1);
            join_none
          end

          wait fork;
        end

        begin
          // See warning, this must be a blocking event
          forever @(posedge clock) cycle_count++;
        end
      join_any
      disable fork;

      $display({"\n",
                "-----------------------------------------------------------\n",
                " <Finished> Performance Test\n",
                "   Cycle count: %0d\n",
                "-----------------------------------------------------------",
                "\n"},
               cycle_count);
    end

    $finish;
  end
endmodule : RouterTB
