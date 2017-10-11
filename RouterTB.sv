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
////      e.g. ./simv -gui +STRESS +PERFORMANCE +vcs+finish+1000000 +VERBOSE=3
////
////     - +BASIC:        Transfer one packet at a time between every node pair
////                      within the same router
////     - +ACROSS:       Transfer one packet at a time between every node pair
////                      going across the bridge
////     - +BROADCAST:    test triangular concurrency between every node pair in
////                      the same router; for example 0->1 1->2 2->3
////                      simultaneously
////     - +STRESS_SRC:   TB has one node bombard all other destinations with
////                      packets
////     - +STRESS_DEST:  TB has every node bombard a single destination with
////                      packets
////     - +FAIRNESS:     TB checks for transaction fairness at each destination
////                      node by sending three packets simultaneously across
////                      the router-to-router port and counting the number of
////                      first receipts for each source
////     - +PERFORMANCE:  deterministically measures router performance under
////                      real-world conditions
////
module automatic RouterTB (
  input logic cQ_full[`NODES],
  input pkt_t pkt_out[`NODES],
  input logic pkt_out_avail[`NODES],
  output logic clock, reset_n,
  output pkt_t pkt_in[`NODES],
  output logic pkt_in_avail[`NODES]);

  function logic are_close (integer a, b, c, real tol=0.1);
    if ((1.0-tol) * b > a || a > (1.0+tol) * b) return 1'b0;
    if ((1.0-tol) * c > a || a > (1.0+tol) * c) return 1'b0;

    if ((1.0-tol) * a > b || b > (1.0+tol) * a) return 1'b0;
    if ((1.0-tol) * c > b || b > (1.0+tol) * c) return 1'b0;

    if ((1.0-tol) * a > c || c > (1.0+tol) * a) return 1'b0;
  if ((1.0-tol) * b > c || c > (1.0+tol) * b) return 1'b0;

    return 1'b1;
  endfunction

  /* !!WARNING!!
   *   For some reason, VCS does not treat ##N cycle delays as blocking events
   *   inside threads so you must use repeat(N) @(posedge clock) instead
   */
  default clocking cb_main @(posedge clock); endclocking

  // Wrapper for NoC packets to allow for inter-process synchronizaton
  class PktWrapper;
    rand pkt_t pkt; // NoC packet
    time create_time, send_time, recv_time; // Packet creation and receive times
    event received; // Inter-process event

    constraint legal_pkt {
      pkt.src != pkt.dest;
      pkt.src inside {[0:`NODES-1]};
      pkt.dest inside {[0:`NODES-1]};}

    function new;
      this.create_time = $time;
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
    reset_n <= 1'b0;

    // Initialize inter-process FIFOs with no bound
    for (int src=0; src < 6; src++) begin
      for (int dest=0; dest < 6; dest++) begin
        send_M[src][dest] = new(0);
      end
    end
    if (debug_level > 2) $info("Initialized send_M mailboxes");

    recv_M = new(0);
    if (debug_level > 2) $info("Initialized recv_M mailbox");

    // Initialize semaphores as mutexes
    for (int src=0; src < 6; src++) begin
      node_sem[src] = new(1);
    end
    if (debug_level > 2) $info("Initialized source semaphores");

    #1 reset_n <= 1'b1;
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

      assert(!$isunknown(pkt_from_node)) else
        $fatal("Monitor%0d detected packet with unknown bits %b, must quit",
               node_id, pkt_from_node);

      assert(pkt_from_node.dest == node_id) else
        $error("Monitor%0d detected packet with incorrect dest=%0d",
               node_id, pkt_from_node.dest);

      if (send_M[pkt_from_node.src]
                [pkt_from_node.dest].try_get(pkt_from_M)) begin
        pkt_from_M.recv_time = $time;

        assert (pkt_from_M.pkt.src == pkt_from_node.src) else
          $error({"Monitor%0d detected violation of sequential consistency ",
                  "for user packet {src: %0d, dest: %0d, data: %h}, expected ",
                  "{src: %0d, dest: %0d, data: %h} from mailbox"},
                 node_id,
                 pkt_from_node.src, pkt_from_node.dest, pkt_from_node.data,
                 pkt_from_M.pkt.src, pkt_from_M.pkt.dest, pkt_from_M.pkt.data);

        assert(pkt_from_M.pkt.data == pkt_from_node.data) else
          $error("Monitor%0d detected corrupt data from user %h should be %h",
                 node_id, pkt_from_node.data, pkt_from_M.pkt.data);

        if (debug_level > 1) begin
          $info({"Monitor%0d detected user packet ",
                 "{src: %0d, dest: %d0, data: %h} ",
                 "corresponding to mailbox entry ",
                 "{src: %d, dest: %d, data: %h} ",
                 "created @%0t, sent @%0t and received @%0t"},
                node_id,
                pkt_from_node.src, pkt_from_node.dest, pkt_from_node.data,
                pkt_from_M.pkt.src, pkt_from_M.pkt.dest, pkt_from_M.pkt.data,
                pkt_from_M.create_time, pkt_from_M.send_time,
                pkt_from_M.recv_time);
        end

        recv_M.put(pkt_from_M);
        -> pkt_from_M.received; // Notify blocking process in send_pkt
      end else begin
        $error({"Monitor%0d detected untracked user packet ",
                "{src: %0d, dest: %0d, data: %h}"},
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
                          input logic do_delay=1'b0);
    PktWrapper pkt_to_M = new();

    if (src == -1 && dest == -1) begin
      pkt_to_M.randomize();
    end else if (src inside {[0:`NODES-1]} && dest == -1) begin
      pkt_to_M.randomize() with {pkt.src == src;};
    end else if (src == -1 && dest inside {[0:`NODES-1]}) begin
      pkt_to_M.randomize() with {pkt.dest == dest;};
    end else if (src inside {[0:`NODES-1]} && dest inside {[0:`NODES-1]}
                 && src != dest) begin
       pkt_to_M.randomize() with {pkt.src == src; pkt.dest == dest;};
    end else begin
      $error("Unable to satisfy constraints for src=%0d dest=%0d", src, dest);
    end

    src = pkt_to_M.pkt.src;
    dest = pkt_to_M.pkt.dest;

    node_sem[src].get(1); // BEGIN critical region
      #1 ;
      wait(~cQ_full[src]); // Must check after reactive region
      if (do_delay) repeat($urandom_range(`MAX_DELAY)) @(posedge clock);

      pkt_to_M.send_time = $time; // Update the packet with accurate send time

      assert(~cQ_full[src]) else begin
        $error("Node queue unexpectedly became full, should not attempt");
        $finish;
      end

      pkt_in[src] <= pkt_to_M.pkt;
      pkt_in_avail[src] <= 1'b1;
      send_M[src][dest].put(pkt_to_M);

      if (debug_level > 1) begin
        $info("Testbench dispatched packet from %0d to %0d with data %h",
              pkt_to_M.pkt.src, pkt_to_M.pkt.dest, pkt_to_M.pkt.data);
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
    ##1000000;
    $display("%m @%0t: Testbench issued timeout", $time);
    $finish;
   end

  // Spawn node monitors
  initial begin
    fork // Isolating thread
      for (int dest=0; dest < 6; dest++) begin
        automatic int fork_dest = dest;
        fork
          monitor_recv(fork_dest);
        join_none // Never join
      end
    join
  end

  initial begin
    PktWrapper tmp_1, tmp_2, tmp_3;
    integer fair_first[6]; // FAIRNESS
    integer cycle_count = 0; // PERFORMANCE

    pkt_in = '{default: '0}; // `NULL_PKT placeholder
    pkt_in_avail = '{default: 1'b0};

    do_reset;

    if ($test$plusargs("BASIC")) begin
      $display({"\n",
                "-----------------------------------------------------------\n",
                " <Started> Basic Send/Recv Test\n",
                "-----------------------------------------------------------",
                "\n"});
      do_reset;
      ##1 ;

      $display("Sending packets inside router 1 with random delay");
      for (int src=0; src < 3; src++) begin
        for (int dest=0; dest < 3; dest++) begin
          if (src == dest) continue;

          send_pkt(src, dest, 1'b1);
        end
      end

      $display("Sending packets inside router 2 with random delay");
      for (int src=4; src < 6; src++) begin
        for (int dest=4; dest < 6; dest++) begin
          if (src == dest) continue;

          send_pkt(src, dest, 1'b1);
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

      $display("Sending packets from router 1 to router 2 with random delay");
      for (int src=0; src < 3; src++) begin
        for (int dest=4; dest < 6; dest++) begin
          send_pkt(src, dest, 1'b1);
        end
      end

      $display("Sending packets from router 2 to router 1 with random delay");
      for (int src=4; src < 6; src++) begin
        for (int dest=0; dest < 3; dest++) begin
          send_pkt(src, dest, 1'b1);
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

      $display("Sending concurrent packets inside router 1");
      for (int i=0; i < 3; i++) begin
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
          $error("Packets to nodes %0d %0d %0d were not simultaneous",
                 tmp_1.pkt.dest, tmp_2.pkt.dest, tmp_3.pkt.dest);
      end

      $display("Sending packets inside router 2");
      for (int i=0; i < 3; i++) begin
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
          $error("Packets to nodes %0d %0d %0d were not simultaneous",
                 tmp_1.pkt.dest, tmp_2.pkt.dest, tmp_3.pkt.dest);
      end

      $display({"\n",
                "-----------------------------------------------------------\n",
                " <Finished> Broadcast Concurrency Test\n",
                "-----------------------------------------------------------",
                "\n"});
    end

    if ($test$plusargs("STRESS_DEST")) begin
      $display({"\n",
                "-----------------------------------------------------------\n",
                " <Started> Node Destination Stress Test\n",
                "-----------------------------------------------------------",
                "\n"});
      do_reset;
      ##1 ;

      for (int dest=0; dest < 6; dest++) begin
        automatic int fork_dest = dest;
        $display("Stressing destination node %0d from all other nodes", dest);

        fork // Isolating thread
          begin
            for (int i=0; i < `NUM_STRESS; i++) begin
              fork
                send_pkt(,fork_dest,1'b1);
              join_none
            end

            wait fork;
          end
        join
      end

      $display({"\n",
                "-----------------------------------------------------------\n",
                " <Finished> Node Destination Stress Test\n",
                "-----------------------------------------------------------",
                "\n"});
    end

    if ($test$plusargs("STRESS_SRC")) begin
      $display({"\n",
                "-----------------------------------------------------------\n",
                " <Started> Node Source Stress Test\n",
                "-----------------------------------------------------------",
                "\n"});
      do_reset;
      ##1 ;

      for (int src=0; src < 6; src++) begin
        automatic int fork_src = src;
        $display("Stressing source node %0d to all other nodes", src);

        fork // Isolating thread
          begin
            for (int i=0; i < `NUM_STRESS; i++) begin
              fork
                send_pkt(fork_src,,1'b1);
              join_none
            end

            wait fork;
          end
        join
      end

      $display({"\n",
                "-----------------------------------------------------------\n",
                " <Finished> Node Source Stress Test\n",
                "-----------------------------------------------------------",
                "\n"});
    end

    if ($test$plusargs("FAIRNESS")) begin
      $display({"\n",
                "-----------------------------------------------------------\n",
                " <Started> Fairness Test Across Router-Router Port\n",
                "-----------------------------------------------------------",
                "\n"});
      do_reset;
      ##1 ;

      $display("Checking fairness in router 1");
      for (int dest=0; dest < 3; dest++) begin
        automatic int fork_dest = dest;
        $display("\nFairness destination is **%0d** in router 1", fork_dest);
        fair_first = '{0, 0, 0, 0, 0, 0};

        for (int i=0; i < `NUM_FAIRNESS; i++) begin
          fork
            begin
              send_pkt(3, fork_dest, 1'b0);
            end

            begin
              send_pkt(4, fork_dest, 1'b0);
            end

            begin
              send_pkt(5, fork_dest, 1'b0);
            end
          join

          recv_M.get(tmp_1);
          recv_M.get(tmp_2);
          recv_M.get(tmp_3);

          fair_first[tmp_1.pkt.src] += 1;
        end

        $display("Number of first receipts from source (3: %d) (4: %d) (5: %d)",
                 fair_first[3], fair_first[4], fair_first[5]);

        assert(are_close(fair_first[3], fair_first[4], fair_first[5])) else
          $error("Some packets were received more than others");
      end


      $display("Checking fairness in router 2");
      for (int dest=3; dest < 6; dest++) begin
        automatic int fork_dest = dest;
        $display("\nFairness destination is **%0d** in router 2", fork_dest);
        fair_first = '{0, 0, 0, 0, 0, 0};

        for (int i=0; i < `NUM_FAIRNESS; i++) begin
          fork
            begin
              send_pkt(0, fork_dest, 1'b0);
            end

            begin
              send_pkt(1, fork_dest, 1'b0);
            end

            begin
              send_pkt(2, fork_dest, 1'b0);
            end
          join

          recv_M.get(tmp_1);
          recv_M.get(tmp_2);
          recv_M.get(tmp_3);

          fair_first[tmp_1.pkt.src] += 1;
        end

        $display("Number of first receipts from source (0: %d) (1: %d) (2: %d)",
                 fair_first[0], fair_first[1], fair_first[2]);

        assert(are_close(fair_first[0], fair_first[1], fair_first[2])) else
          $error("Some packets were received more than others");
      end

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
          for (int i=0; i < `NUM_PERFORMANCE; i++) begin
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
