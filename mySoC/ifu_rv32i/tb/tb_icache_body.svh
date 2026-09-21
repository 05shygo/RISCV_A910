integer cycles = 0;
integer accesses = 0;
integer misses = 0;
integer replays = 0;
integer grants = 0;
integer deliveries = 0;
integer checks = 0;
integer i;
integer j;
integer before_count;
integer before_replay;
reg [31:0] address;
reg [127:0] snapshot;
reg [31:0] expected_pc [0:255];
integer queued = 0;
integer retired = 0;
reg stream_check = 0;

initial forever_cpuclk = 0;
always #5 forever_cpuclk = ~forever_cpuclk;
initial begin
  #2000000;
  $fatal(1, "Timeout cycles=%0d state=%0d maint=%0d", cycles, dut.state_q, dut.maint_state_q);
end

function [31:0] word_at(input [31:0] pa);
  begin
    // Address-dependent instructions, little-endian word ordering.
    case (pa[3:2])
      0: word_at = {pa[15:4], 5'd0, 3'd0, 5'd2, 7'h13};
      1: word_at = 32'h00000063;
      2: word_at = 32'h000082e7; // jalr x5,x1,0: coroutine pop+push
      3: word_at = 32'h00012083;
    endcase
  end
endfunction

function [127:0] block_at(input [31:0] pa);
  reg [31:0] base;
  begin
    base = pa & 32'hfffffff0;
    block_at = {word_at(base+12), word_at(base+8), word_at(base+4), word_at(base)};
  end
endfunction

function [31:0] wrap_addr(input [31:0] pa, input integer beat);
  begin
    wrap_addr = (pa & 32'hffffffc0) | (((pa & 32'h30) + (beat*16)) & 32'h30);
  end
endfunction

task check(input condition, input [1023:0] message);
  begin
    checks = checks + 1;
    if (condition !== 1'b1) begin
      $display("FAIL cycle=%0d: %0s", cycles, message);
      $fatal(1);
    end
  end
endtask

task tick;
  begin @(posedge forever_cpuclk); #1; end
endtask

always @(posedge forever_cpuclk) begin
  if (cpurst_b) begin
    cycles = cycles + 1;
    if (ifu_hpcp_icache_access) accesses = accesses + 1;
    if (ifu_hpcp_icache_miss) misses = misses + 1;
    if (way_reissue) replays = replays + 1;
    if (ifu_biu_rd_req && biu_ifu_rd_grnt) grants = grants + 1;
    if (result_vld && result_ready) deliveries = deliveries + 1;
    // One-hot array owners and no read-through of a partially installed line.
    check((dut.owner_onehot & (dut.owner_onehot - 5'd1)) == 0,
          "array arbitration must be one-hot-or-zero");
    if (dut.install) begin
      check(dut.beat_end && !dut.trans_error_q && !refill_error,
            "only complete successful transactions may install");
    end
    if (maint_busy) check(!lookup_ready, "maintenance blocks lookup");
    if (stream_check) begin
      if (lookup_vld && lookup_ready) begin
        expected_pc[queued] = lookup_pc;
        queued = queued + 1;
      end
      if (result_vld && result_ready) begin
        check(retired < queued, "no unsolicited stream response");
        check(result_pc === expected_pc[retired], "stream response PC ordering");
        check(result_data === block_at(expected_pc[retired]), "stream data ordering");
        check(!result_fault && !result_from_refill, "stream must hit");
        retired = retired + 1;
      end
    end
  end
end

task request(input [31:0] pc, input [1:0] predicted_way);
  integer n;
  begin
    @(negedge forever_cpuclk);
    lookup_pc = pc;
    lookup_way_pred = predicted_way;
    lookup_vld = 1;
    #1;
    n = 0;
    while (!lookup_ready) begin
      tick;
      @(negedge forever_cpuclk);
      n = n + 1;
      check(n < 100, "request ready timeout");
    end
    tick;
    @(negedge forever_cpuclk);
    lookup_vld = 0;
  end
endtask

task wait_miss(input [31:0] pc, input allocate_line);
  integer n;
  begin
    n = 0;
    while (!ifu_biu_rd_req) begin
      tick;
      n = n + 1;
      check(n < 30, "miss request timeout");
    end
    check(ifu_biu_rd_addr === (pc & 32'hfffffff0), "critical-block request address");
    check(ifu_biu_rd_len === (allocate_line ? 2'b11 : 2'b00), "BIU length");
    check(ifu_biu_rd_burst === (allocate_line ? 2'b10 : 2'b01), "WRAP / INCR encoding");
    check(ifu_biu_rd_size === 3'b100 && !ifu_biu_rd_id, "BIU size / ID0");
  end
endtask

task grant;
  begin
    @(negedge forever_cpuclk);
    biu_ifu_rd_grnt = 1;
    check(ifu_biu_rd_req, "grant requires request");
    tick;
    @(negedge forever_cpuclk);
    biu_ifu_rd_grnt = 0;
    check(refill_busy, "grant commits transaction");
  end
endtask

task beat(input [31:0] pa, input err, input last);
  integer n;
  begin
    @(negedge forever_cpuclk);
    biu_ifu_rd_data_vld = 1;
    biu_ifu_rd_data = block_at(pa);
    biu_ifu_rd_resp = err ? 2'b10 : 2'b00;
    biu_ifu_rd_last = last;
    biu_ifu_rd_id = 0;
    #1;
    n = 0;
    while (!ifu_biu_r_ready) begin
      tick;
      @(negedge forever_cpuclk);
      n = n + 1;
      check(n < 40, "refill ready timeout");
    end
    tick;
    @(negedge forever_cpuclk);
    biu_ifu_rd_data_vld = 0;
    biu_ifu_rd_resp = 0;
    biu_ifu_rd_last = 0;
  end
endtask

task expect_result(input [31:0] pc, input fault, input from_refill);
  integer n;
  begin
    n = 0;
    while (!result_vld) begin
      tick;
      n = n + 1;
      check(n < 40, "result timeout");
    end
    check(result_pc === pc, "response PC must retain word offset");
    check(result_fault === fault, "fault precision");
    check(result_from_refill === from_refill, "hit/refill source");
    check(result_slot_mask === (fault ? (4'b0001 << pc[3:2]) : (4'b1111 << pc[3:2])),
          "word mask removes only words before requested PC");
    if (!fault) begin
      check(result_data === block_at(pc), "block data / little-endian word order");
      check(result_precode === 32'h401c0100, "word precode and coroutine hints");
    end else begin
      check(result_data === 128'b0 && result_precode === 32'b0, "fault placeholder");
    end
  end
endtask

task consume;
  begin
    @(negedge forever_cpuclk);
    check(result_vld, "consume must have a result");
    result_ready = 1;
    tick;
    @(negedge forever_cpuclk);
    result_ready = 0;
  end
endtask

task cancel_flow;
  begin
    @(negedge forever_cpuclk); cancel = 1;
    tick;
    check(!result_vld && !miss_vld, "cancel suppresses current path");
    @(negedge forever_cpuclk); cancel = 0;
  end
endtask

task fill(input [31:0] pc);
  integer k;
  begin
    request(pc, 2'b00);
    wait_miss(pc, 1);
    grant;
    for (k = 0; k < 4; k = k + 1) begin
      beat(wrap_addr(pc,k), 0, k==3);
      if (k == 0) begin
        expect_result(pc, 0, 1);
        check(refill_busy, "critical word returned before line completion");
        consume;
      end
    end
    check(!refill_busy, "four beats complete refill");
  end
endtask

task hit_request(input [31:0] pc, input [1:0] predicted_way);
  integer old_grants;
  begin
    old_grants = grants;
    request(pc, predicted_way);
    expect_result(pc,0,0);
    check(grants == old_grants && !miss_vld, "hit/replay never starts refill");
    consume;
  end
endtask

task software_read(input [31:0] pc, input way, input [1:0] kind);
  integer n;
  begin
    @(negedge forever_cpuclk);
    cp0_ifu_icache_read_index = pc[14:4];
    cp0_ifu_icache_read_way = way;
    cp0_ifu_icache_read_kind = kind;
    cp0_ifu_icache_read_req = 1;
    #1;
    n = 0;
    while (!ifu_cp0_icache_read_ready) begin
      tick; @(negedge forever_cpuclk);
      n = n + 1; check(n < 30, "software read ready timeout");
    end
    tick;
    @(negedge forever_cpuclk); cp0_ifu_icache_read_req = 0;
    while (!ifu_cp0_icache_read_data_vld) begin tick; end
    snapshot = ifu_cp0_icache_read_data;
    repeat (3) begin
      tick;
      check(ifu_cp0_icache_read_data_vld && ifu_cp0_icache_read_data === snapshot,
            "software response must survive backpressure");
    end
    @(negedge forever_cpuclk); cp0_ifu_icache_read_data_ready = 1;
    tick;
    @(negedge forever_cpuclk); cp0_ifu_icache_read_data_ready = 0;
  end
endtask

task start_maintenance(input all, input [31:0] pa);
  begin
    @(negedge forever_cpuclk);
    maint_vld = 1; maint_all = all; maint_pa = pa;
    #1;
    check(maint_ready && ipb_invalidate, "maintenance accepts and invalidates IPB");
    tick;
    @(negedge forever_cpuclk); maint_vld = 0;
  end
endtask

task finish_maintenance;
  integer n;
  begin
    n = 0;
    while (!maint_done) begin
      tick;
      n = n + 1;
      check(n < 600, "maintenance completion timeout");
    end
    tick;
    check(!maint_done && maint_ready, "one-cycle maintenance completion");
  end
endtask

initial begin
  cpurst_b = 0;
  defaults;
  repeat (3) tick;
  @(negedge forever_cpuclk); cpurst_b = 1;
  while (!cache_init_done) begin
    check(!lookup_ready && !miss_vld, "no requests during reset sweep");
    tick;
  end
  check(cycles == 2048, "all four block rows and 512 tag rows initialized");
  software_read(32'h00000000,0,1);
  check(snapshot === 128'b0, "reset tag/fifo/valid clear");
  software_read(32'h00007ff0,1,0);
  check(snapshot === 128'b0, "last data row initialized");

  $display("CASE WRAP, early forwarding, blocked response, software read, Way replay");
  request(32'h1034,2'b01); wait_miss(32'h1034,1);
  repeat (4) begin tick; check(ifu_biu_rd_addr===32'h1030 && miss_vld, "ungranted request retained"); end
  grant;
  // A foreign ID cannot advance the demand refill counter.
  @(negedge forever_cpuclk);
  biu_ifu_rd_data_vld=1; biu_ifu_rd_id=1; biu_ifu_rd_last=1;
  repeat (3) begin tick; check(!ifu_biu_r_ready && !result_vld, "ID1 return isolation"); end
  @(negedge forever_cpuclk); biu_ifu_rd_data_vld=0; biu_ifu_rd_id=0; biu_ifu_rd_last=0;
  beat(32'h1030,0,0);
  expect_result(32'h1034,0,1);
  check(refill_busy, "critical forwarding before whole-line valid");
  snapshot = result_data;
  for (i=1;i<4;i=i+1) begin
    beat(wrap_addr(32'h1034,i),0,i==3);
    check(result_vld && result_data===snapshot && result_pc===32'h1034,
          "tail beat cannot overwrite blocked critical response");
  end
  repeat (4) begin tick; check(result_vld && result_data===snapshot, "response held"); end
  consume;
  for (i=0;i<4;i=i+1) hit_request(32'h1000+i*16,2'b01);
  before_replay = replays;
  hit_request(32'h1038,2'b10);
  check(replays==before_replay+1, "wrong predicted way replays exactly once");
  software_read(32'h1030,0,0); check(snapshot===block_at(32'h1030), "software Data layout");
  software_read(32'h1030,0,2); check(snapshot===128'h401c0100, "software Precode layout");
  software_read(32'h1030,0,1); check(snapshot===128'h60000, "Tag valid/FIFO bits 17/18");
  software_read(32'h1030,0,3); check(snapshot===0, "reserved read kind returns zero");

  $display("CASE continuous hit throughput and randomized response backpressure");
  @(negedge forever_cpuclk);
  queued=0; retired=0; stream_check=1; result_ready=1;
  lookup_vld=1; lookup_way_pred=1; lookup_pc=32'h1000;
  for (i=0;i<16;i=i+1) begin
    #1; check(lookup_ready, "sustained one lookup every cycle");
    tick;
    @(negedge forever_cpuclk); lookup_pc=32'h1000+((i+1)%4)*16;
  end
  lookup_vld=0;
  repeat(3) tick;
  check(retired==16 && queued==16, "sustained 16 response blocks");
  @(negedge forever_cpuclk); stream_check=0; result_ready=0;
  for (i=0;i<24;i=i+1) begin
    request(32'h1000+(i%4)*16+(i%4)*4,2'b11);
    expect_result(32'h1000+(i%4)*16+(i%4)*4,0,0);
    snapshot=result_data;
    repeat($urandom_range(0,7)) begin
      tick; check(result_vld && result_data===snapshot, "random response stalls");
    end
    consume;
  end

  $display("CASE FIFO replacement, physical tags, line invalidation");
  fill(32'h9030);
  hit_request(32'h9030,2'b01);
  hit_request(32'h1030,2'b01);
  fill(32'h11030); // hits did not change FIFO: replaces way0, not recently used way1
  hit_request(32'h9030,2'b10);
  request(32'h1030,2'b11); wait_miss(32'h1030,1); cancel_flow;
  software_read(32'h11030,0,1);
  check(snapshot===128'h60002, "tag[31:15], valid, FIFO packing");
  start_maintenance(0,32'h19000); finish_maintenance; // same set, absent tag
  hit_request(32'h11030,2'b01); hit_request(32'h9030,2'b10);
  start_maintenance(0,32'h9000); finish_maintenance;
  hit_request(32'h11030,2'b01);
  request(32'h9030,2'b11); wait_miss(32'h9030,1); cancel_flow;

  $display("CASE error in each beat, no partial install, precise critical fault");
  for (i=0;i<4;i=i+1) begin
    address=32'h2000+i*64+16;
    request(address,0); wait_miss(address,1); grant;
    for(j=0;j<4;j=j+1) begin
      beat(wrap_addr(address,j),j==i,j==3);
      if(j==0) begin
        expect_result(address,i==0,1);
        if(i==0) check(result_cause===1,"access fault cause");
        consume;
      end
    end
    check(!result_vld,"later error must not create another critical fault");
    request(address,0); wait_miss(address,1); cancel_flow;
  end

  $display("CASE cancel before grant, after grant, and simultaneous critical return");
  before_count=grants;
  request(32'h3030,0); wait_miss(32'h3030,1); cancel_flow;
  check(grants==before_count,"ungranted cancel creates no transaction");
  request(32'h3030,0); wait_miss(32'h3030,1); grant;
  cancel_flow;
  for(i=0;i<4;i=i+1) begin
    beat(wrap_addr(32'h3030,i),0,i==3);
    check(!result_vld,"cancelled refill never delivers stale data");
  end
  hit_request(32'h3030,1); // ordinary cancel can legally finish installing
  request(32'h3070,0); wait_miss(32'h3070,1); grant;
  @(negedge forever_cpuclk); cancel=1;
  beat(32'h3070,0,0);
  check(!result_vld,"cancel priority over first beat");
  cancel=0;
  for(i=1;i<4;i=i+1) beat(wrap_addr(32'h3070,i),0,i==3);
  hit_request(32'h3070,1);

  $display("CASE maintenance drains old returns and waits for IPB idle");
  request(32'h4030,0); wait_miss(32'h4030,1); grant;
  beat(32'h4030,0,0); expect_result(32'h4030,0,1);
  ipb_idle=0;
  start_maintenance(0,32'h4000);
  check(!result_vld,"maintenance cancels blocked critical response");
  for(i=1;i<4;i=i+1) begin
    beat(wrap_addr(32'h4030,i),0,i==3);
    check(!maint_done,"cannot complete while external IPB still active");
  end
  repeat(3) begin tick; check(!maint_done,"IPB drain interlock"); end
  @(negedge forever_cpuclk); ipb_idle=1;
  finish_maintenance;
  request(32'h4030,0); wait_miss(32'h4030,1); cancel_flow;
  hit_request(32'h3030,1);
  start_maintenance(1,0); finish_maintenance;
  request(32'h3030,0); wait_miss(32'h3030,1); cancel_flow;

  $display("CASE simultaneous final beat / maintenance and software-read drain");
  request(32'h4830,0); wait_miss(32'h4830,1); grant;
  for(i=0;i<3;i=i+1) beat(wrap_addr(32'h4830,i),0,0);
  @(negedge forever_cpuclk);
  maint_vld=1; maint_all=0; maint_pa=32'h4800;
  biu_ifu_rd_data_vld=1; biu_ifu_rd_id=0;
  biu_ifu_rd_data=block_at(32'h4820); biu_ifu_rd_last=1;
  #1; check(maint_ready && ifu_biu_r_ready,"last beat and maintenance may both handshake");
  tick;
  @(negedge forever_cpuclk); maint_vld=0; biu_ifu_rd_data_vld=0; biu_ifu_rd_last=0;
  finish_maintenance;
  request(32'h4830,0); wait_miss(32'h4830,1); cancel_flow;
  // A previously accepted software response survives maintenance and delays done.
  @(negedge forever_cpuclk);
  cp0_ifu_icache_read_req=1; cp0_ifu_icache_read_kind=1;
  cp0_ifu_icache_read_index=0; cp0_ifu_icache_read_way=0;
  #1; check(ifu_cp0_icache_read_ready,"software read before maintenance");
  tick;
  @(negedge forever_cpuclk); cp0_ifu_icache_read_req=0;
  start_maintenance(0,0);
  repeat(5) begin tick; check(!maint_done && ifu_cp0_icache_read_data_vld,"maintenance waits for held software response"); end
  @(negedge forever_cpuclk); cp0_ifu_icache_read_data_ready=1;
  tick;
  @(negedge forever_cpuclk); cp0_ifu_icache_read_data_ready=0;
  finish_maintenance;

  $display("CASE all address bits, set511, top-of-address-space line");
  fill(32'hfffffff4);
  hit_request(32'hffffffc0,1);
  hit_request(32'hfffffffc,1);
  software_read(32'hfffffff0,0,1);
  check(snapshot===128'h7ffff,"all seventeen physical tag bits retained");
  fill(32'h7ff0); // same set, different high tag, other way
  hit_request(32'hfffffffc,1);
  start_maintenance(0,32'hffffffc0); finish_maintenance;
  hit_request(32'h7ffc,2);
  request(32'hfffffff4,0); wait_miss(32'hfffffff4,1); cancel_flow;

  $display("CASE noncacheable, Cache disabled, region permission, alignment");
  request(32'h10000034,0); wait_miss(32'h10000034,0);
  check(ifu_biu_rd_cache===4'b0011 && ifu_biu_rd_domain===2'b11,"noncacheable attributes");
  grant; beat(32'h10000030,0,1); expect_result(32'h10000034,0,1); consume;
  check(!refill_busy,"bypass is exactly one beat");
  request(32'h10000034,0); wait_miss(32'h10000034,0); cancel_flow;
  cp0_ifu_icache_en=0;
  request(32'h5034,0); wait_miss(32'h5034,0);
  check(ifu_biu_rd_cache===4'b1111,"Cache disable preserves region cacheability");
  grant; beat(32'h5030,0,1); expect_result(32'h5034,0,1); consume;
  cp0_ifu_icache_en=1;
  request(32'h5034,0); wait_miss(32'h5034,1); cancel_flow;
  for(i=0;i<4;i=i+1) begin
    case(i)
      0: address=32'h20000000;
      1: address=32'h30000000;
      2: address=32'h40000000;
      3: address=32'h00001002;
    endcase
    before_count=grants;
    request(address,0); expect_result(address,1,0);
    check(result_cause==((i==3)?0:1),"alignment versus physical permission cause");
    check(grants==before_count && !miss_vld,"denied fetch issues no bus request");
    consume;
  end

  $display("CASE IPB Tag query, stopped fetch, invalid BIU last");
  fill(32'h6030);
  @(negedge forever_cpuclk); ipb_lookup_pa=32'h6000; ipb_lookup_vld=1;
  #1; check(ipb_lookup_ready,"IPB query ready");
  tick;
  @(negedge forever_cpuclk); ipb_lookup_vld=0;
  while(!ipb_result_vld) tick;
  check(ipb_result_hit===2'b01 && ipb_result_allowed,"IPB hit / attributes");
  repeat(3) begin tick; check(ipb_result_vld && ipb_result_hit===1,"IPB response held"); end
  @(negedge forever_cpuclk); ipb_result_ready=1;
  tick;
  @(negedge forever_cpuclk); ipb_result_ready=0;
  cp0_ifu_no_op_req=1;
  repeat(3) begin tick; check(!lookup_ready && !ipb_lookup_ready && cache_no_op,"no-op stops new work"); end
  cp0_ifu_no_op_req=0;
  // Stop in the LOOK->MISS interval: the already accepted lookup must drain.
  request(32'h6830,0);
  cp0_ifu_no_op_req=1;
  wait_miss(32'h6830,1); grant;
  for(i=0;i<4;i=i+1) beat(wrap_addr(32'h6830,i),0,i==3);
  expect_result(32'h6830,0,1); consume;
  check(cache_no_op,"no-op must not deadlock an accepted miss");
  cp0_ifu_no_op_req=0;
  request(32'h7030,0); wait_miss(32'h7030,1); grant;
  cp0_ifu_no_op_req=1;
  beat(32'h7030,0,1); // malformed early last: error token and no line publication
  expect_result(32'h7030,1,1); consume;
  check(refill_busy && refill_protocol_error,"early last cannot release transaction ID");
  for(i=1;i<4;i=i+1) beat(wrap_addr(32'h7030,i),0,i==3);
  cp0_ifu_no_op_req=0;
  request(32'h7030,0); wait_miss(32'h7030,1); cancel_flow;

  $display("PASS ICache: checks=%0d accesses=%0d misses=%0d replays=%0d grants=%0d delivered=%0d",
           checks,accesses,misses,replays,grants,deliveries);
  $finish;
end
