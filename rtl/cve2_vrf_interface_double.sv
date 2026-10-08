// Copyright 2026 Politecnico di Torino.
// Copyright and related rights are licensed under the Solderpad Hardware
// License, Version 2.0 (the "License"); you may not use this file except in
// compliance with the License. You may obtain a copy of the License at
// http://solderpad.org/licenses/SHL-2.0. Unless required by applicable law
// or agreed to in writing, software, hardware and materials distributed under
// this License is distributed on an "AS IS" BASIS, WITHOUT WARRANTIES OR
// CONDITIONS OF ANY KIND, either express or implied. See the License for the
// specific language governing permissions and limitations under the License.
//
// File: cve2_vrf_interface_double.sv
// Author: Flavia Guella
// Date: 18/05/2026
// Description: TODO

module cve2_vrf_interface_double #(
    //parameter int unsigned VLEN = 128,
    parameter int unsigned PIPE_WIDTH = 32
) (
    // Clock and Reset
    input   logic                       clk_i,
    input   logic                       rst_ni, 

    // Read ports
    input   logic                       req_i,                              // request signal for VRF
    output  logic [PIPE_WIDTH-1:0]      rdata_a_o, rdata_b_o, rdata_c_o,

    // Write port
    input   logic [PIPE_WIDTH-1:0]      wdata_i,

    // Data memory interface
    output logic         data_req_o,
    input  logic         data_gnt_i,
    input  logic         data_rvalid_i,
    input  logic         data_err_i,
    input  logic         data_pmp_err_i,
    output logic         data_we_o,
    output logic [3:0]   data_be_o,
    output logic [31:0]  data_wdata_o,
    input  logic [31:0]  data_rdata_i,

    // Instr interface used for VRF
    output logic        instr_data_req_o,
    input  logic        instr_data_gnt_i,
    input  logic        instr_data_rvalid_i,
    output logic        instr_data_we_o,
    output logic [3:0]  instr_data_be_o,
    output logic [31:0] instr_data_wdata_o,
    input  logic [31:0] instr_data_rdata_i,

    output logic        use_double_if_o,

    // LSU control signals
    output logic         data_load_addr_o,  // loads the address for the memory operation in a counter
    input  logic         lsu_gnt_i,         // grant of LSU, if not immediately given for a write we sample the result/operand
    input  logic [1:0]   lsu_offset_i,      // offset provided by the LSU in case of misaligned access
    // AGU
    output logic         agu_load_o,
    output logic [1:0]   agu_get_rs1_o,
    output logic [1:0]   agu_get_rs2_o,
    output logic [1:0]   agu_get_rd_o,
    output logic [2:0]   agu_incr_o, // three different to avoid conflicts between the counters in particular states

    // ID signals
    input  logic [3:0]            sel_operation_i,    // each bit enables a different operation, 0 - R RS1, 1 - R RS2, 2 - R RS3, 3 - W RD
    input  logic                  memory_op_i,        // 0 - arithmetic operation, 1 - load/store operation
    input  logic                  multicycle_op_i,    // 0 - single cycle operation, 1 - multi-cycle operation (e.g. mulh)
    input  logic                  unit_stride_i,      // 0 - non-unit stride, 1 - unit stride
    input  logic                  mult_ops_i,      // 0 - non-interleaved, 1 - interleaved
    output logic                  vector_done_o,      // signals the pipeline that the vector operation is finished (most likely with a write to the VRF)
    
    // Multicycle ops stall unit
    output logic                  ex_stall_o,            // signal to stall the EX block for multi-cycle operations
    
    // Slide signals
    input  logic                  slide_op_i,         // 0 - no slide, 1 - slide
    input  logic [31:0]           slide_offset_i,     // offset for the slide operation
    input  logic                  is_slide_up_i,      // 0 - slide down, 1 - slide up

    // Instruction fetch busy (prefetch buffer has a fetch outstanding or requested): the
    // slave shares the instruction port with fetch, see mst_start_hold
    input  logic                  if_busy_i,

    // LSU signals
    output logic                  lsu_req_o,          // signals the LSU that it can start the memory operation
    input  logic                  lsu_done_i,

    // CSR signals
    input cve2_pkg::vlmul_e      lmul_i,
    input cve2_pkg::vsew_e       sew_i,
    input logic [31:0]           vl_i

);

import cve2_pkg::*;

// Master FSM is always 1cc ahead of the slave, but without losing sync.
// NOTE: laod and store ops are performed using a single interface (MST/data if)
// as we have a single LSU available to which to make the requests (if possible to use both ifs can be done afterwards)

typedef enum logic [5:0] {
  VRF_IDLE_MST, 
  VRF_START_MST,
  VRF_INT_READ1_MST,
  VRF_INT_READ2_MST,
  VRF_INT_READ3_MST,
  VRF_INT_WRITE_MST,
  VRF_READ_MST,
  VRF_WRITE_MST,
  VRF_SYNC_MST,
  VRF_LOAD_SLIDE,
  VRF_LOAD, // states handled by the mst FSM alone
  VRF_LOAD_WAITGNT,
  VRF_LOAD_WRITE,
  VRF_STORE_READ,
  VRF_STORE_WAITLSU,
  VRF_STORE_WAITGNT,
  // Multicycle
  VRF_MC_READ1_MST,
  VRF_MC_READ2_MST,
  VRF_MC_WRITE_MST,
  VRF_MC_IDLE_MST,
  VRF_MC_READ,
  VRF_MC_READ_FIRST,
  VRF_MC_WRITE_SINGLE,
  VRF_MC_FINISH_MST, // TODO: check for multicycle impl how to handle last it correctly (even and odd case)
  ERR_STATE,
  // Appended last so the existing encodings (ERR_STATE = 0x18) do not move
  VRF_DONE_MST       // one cycle after the final VRF write: assert vector_done, then IDLE
} mst_state_t;

typedef enum logic [4:0] {
  VRF_IDLE_SLV,
  VRF_START_SLV,
  VRF_INT_READ1_SLV,
  VRF_INT_READ2_SLV,
  VRF_INT_READ3_SLV,
  VRF_INT_WRITE_SLV,
  VRF_MC_READ1_SLV,
  VRF_MC_READ2_SLV,
  VRF_MC_WRITE_SLV,
  VRF_MC_IDLE_SLV,
  VRF_MC_FINISH_SLV,
  VRF_READ_SLV,
  VRF_WRITE_SLV,
  VRF_SYNC_SLV
} slv_state_t;

mst_state_t curr_mst_state, next_mst_state, saved_mst_state_d, saved_mst_state_q;
logic slv_done_seen_q; // the slave asserted vector_done_slv during the current instruction
slv_state_t curr_slv_state, next_slv_state, saved_slv_state_d, saved_slv_state_q;


// Internal signals 
//-----------------
// Mst FSM
// Agu ctrl
logic [2:0] agu_incr_mst; // three different to avoid conflicts between the counters in particular states
logic agu_get_rs1_mst;
logic agu_get_rs2_mst;
logic agu_get_rd_mst;
// Register enable sample
logic rs1_en_mst, rs2_en_mst, rs3_en_mst,rd_en_mst;
// Operands FFs
logic [PIPE_WIDTH-1:0] rs1_q, rs2_q, rs3_q, rd_q;
logic [PIPE_WIDTH-1:0] rs1_d, rs2_d, rs3_d, rd_d;
logic [PIPE_WIDTH-1:0] rs3_d_1, rs3_q_1;
// Iteration counter control
logic dec_iterations_mst;
// Done
logic vector_done_mst;
// Sync MST --> SLV FSM
logic [3:0] mst_sync_slv; // 1 for each operand to sync (muxeed between comb and reg value)
logic [3:0] mst_sync_slv_d, mst_sync_slv_q; // combinational version of the signal to avoid timing issues
logic mst_start_slv, mst_start_slv_q; // start the slave fsm (when the operation is what required)

// Even iterations
logic even_iteration;

// Signals to handle case number of elements to process =1, in which the slv FSM must not be started
logic slv_active;                       // the slave has at least one beat to execute
logic mst_owns_tail;                    // the master, not the slave, executes the final beat
logic mst_tail_write;                   // the master's current write is the final (partial) beat

// Slave FSM
logic [2:0] agu_incr_slv;
logic agu_get_rs1_slv;
logic agu_get_rs2_slv;
logic agu_get_rd_slv;
// Register enable sample
logic rs1_en_slv, rs2_en_slv, rd_en_slv, rs3_en_slv;
logic src_sel_slv; // select as input operands of the EX unit those coming from the slv interface sampling
logic src_sel_slv_c; // select as input operands of the EX unit those coming from the slv interface sampling for the 3rd operand
// Operands FFs
logic [PIPE_WIDTH-1:0] rs1_q_slv, rs2_q_slv, rs3_q_slv, rd_q_slv;
logic [PIPE_WIDTH-1:0] rs1_d_slv, rs2_d_slv, rs3_d_slv;
// Iteration counter control
logic dec_iterations_slv;
// Done
logic vector_done_slv;
// Sync SLV --> MST FSM
logic [3:0] slv_sync_mst; // 1 for each operand to sync
logic [3:0] slv_sync_mst_d, slv_sync_mst_q; // combinational version of the signal to avoid timing issues
logic [3:0] sample_sync_slv;
logic sample_saved_slv; // sample saved_slv_state_q only (no slv_sync_mst_q resampling)
logic sample_sync_mst; // signal to sample the next state of the master FSM when we need to go in sync
logic sel_sync_slv;
logic sel_sync_mst;

// Iterations control
logic [PIPE_WIDTH-3:0] num_iterations_q, num_iterations_d;
logic [PIPE_WIDTH-1:0] num_bytes_elements;
logic first_iteration_d, first_iteration_q;
logic last_iteration_d, last_iteration_q;
logic last_iteration_odd_d, last_iteration_odd_q;
logic last_iteration_mst; // in odd iteration with double if need to arrive to 0 as the last iteration to do the last iteration correctly with if 0

// Handle delay on gnt on last element of vload
logic lsu_pending_q;  // an LSU request of the load is waiting for its response
logic load_tail;      // every word is in, rd_q holds the last one: this is the final write
logic load_tail_wr_q; // the write waiting in VRF_LOAD_WAITGNT is the final one
assign load_tail = last_iteration_q && !lsu_pending_q;


// Offset handling
logic [1:0] offset_q, offset_d;
logic [3:0] offset_be;
logic no_offset;

// Delayed grant for read operations in store
logic read_delayed;
logic rdata_mux;
logic write_delayed;
logic write_delayed_slv;
logic write_delayed_slv_q;
logic [1:0] curr_state_delay, next_state_delay;
logic [1:0] wdata_mux;
logic buffer_en, rd_buf_en;
logic [PIPE_WIDTH-1:0] buffer_q, buffer_d;
logic [3:0] data_be;     // byte enable of the current access
logic [3:0] buffer_be_q; // byte enable of the delayed memory access, held with buffer_q

// Slide instructions support
logic [23:0] slide_buffer_d, slide_buffer_q;
logic [31:0] slide_rdata;
logic slide_buffer_en;
logic [1:0] slide_offset_q;
logic slide_offset_en;
logic slide_first_write_d, slide_first_write_q;
logic sel_slide_be;                             // signal used to select the correct byte-enable for the first write operation
logic [3:0] slide_offset_be;
logic no_offset_first;
logic slide_empty;                              // slide with OFFSET >= vl: no beat to execute
logic op_uses_slave;                            // this op will start the slave FSM
logic mst_start_hold;                           // wait in IDLE until instruction fetch is quiet

// Handle misaligned sub-word mem accesses
// TODO: only store are supported and tested for now (to improve with load)
logic curr_demux_sel, next_demux_sel;
logic mux_sel;
logic [1:0] lsu_offset_q;
// Handle multi-cycle operations
logic first_mc_write_d, first_mc_write_q;
logic mc_last_d, mc_last_q;           // .vx MC: the read just granted in VRF_MC_READ was the last one
logic curr_mc_demux_sel, next_mc_demux_sel;
logic curr_mc_rd_demux_sel, next_mc_rd_demux_sel;
logic curr_mc_mux_sel, next_mc_mux_sel;
logic curr_mc_rd_mux_sel, next_mc_rd_mux_sel;
logic [PIPE_WIDTH-1:0] rs1_q_1, rs2_q_1, rd_q_1;

//--------------------
// FSM State Evolution
//--------------------



//-----------
// Master FSM
//-----------
always_comb begin
  // Default value
  next_mst_state = curr_mst_state;
  case(curr_mst_state)
    VRF_IDLE_MST: begin
      // An empty slide retires from IDLE.
      // mst_start_hold: wait for instruction fetch to be over in case of a double if instr only
      // uses the slave.
      if (req_i && vl_i != 0 && !slide_empty && !mst_start_hold) begin
        // When there is a req for a vector op and the vlen set is greater than 0, proceed
        next_mst_state = VRF_START_MST;
      end else begin
        next_mst_state = VRF_IDLE_MST;
      end
    end
    VRF_START_MST: begin
      // First CC of the vector op

      // ARITHMETIC ops
      // --------------
      if (!memory_op_i) begin
        if (mult_ops_i) begin // ARITHMETIC VV ops (except vslide)
          if (data_gnt_i) begin
            if (multicycle_op_i) begin // vmulh
              next_mst_state = VRF_MC_READ2_MST;
            end else begin // Normal 2ops VV op
              next_mst_state = VRF_INT_READ1_MST;
            end
          end else begin
            next_mst_state = VRF_START_MST;
          end
        end else begin // .VX, SLIDE
          if (sel_operation_i[0] || sel_operation_i[1]) begin
            if (data_gnt_i) begin
              if (slide_op_i && !is_slide_up_i && !no_offset_first) begin
                next_mst_state = VRF_LOAD_SLIDE;
              end else if (multicycle_op_i) begin
                next_mst_state = VRF_MC_READ;
              end else begin
                next_mst_state = VRF_READ_MST;
              end
            end else begin
              next_mst_state = VRF_START_MST; // wait until gnt
            end
          end else if (sel_operation_i[3]) begin
            if (data_gnt_i) begin
              next_mst_state = VRF_WRITE_MST;
            end else begin
              next_mst_state = VRF_START_MST; // wait until gnt
            end
          end else begin // Illegal op (back to idle)
            next_mst_state = VRF_IDLE_MST;
          end
        end
      // MEM ops
      // -------
      end else begin
        if (sel_operation_i[2]==1'b1) begin // STORE op
          if (data_gnt_i) begin
            next_mst_state = VRF_STORE_READ;
          end else begin
            next_mst_state = VRF_START_MST; // wait until gnt
          end
        end else if (sel_operation_i[3]==1'b1) begin // LOAD op
            next_mst_state = VRF_LOAD;
        end else begin // Illegal op
          next_mst_state = VRF_IDLE_MST; // Back to IDLE
        end
      end
    end

    //---------------
    // Arithmetic Ops
    //---------------
    // 3-source operands

    VRF_INT_READ1_MST: begin
      if (first_iteration_q) begin
        next_mst_state = VRF_INT_WRITE_MST;
      end else begin
        if (data_gnt_i) begin
          if ((((slv_sync_mst[1] && sel_operation_i[0]) || (slv_sync_mst[2] && sel_operation_i[1]) || (slv_sync_mst[1] && sel_operation_i[1])) && instr_data_gnt_i) || last_iteration_mst || last_iteration_q || num_iterations_q ==1) begin // todo: check, added last_iteration_q for read3_slv odd
            next_mst_state = VRF_INT_WRITE_MST;
          end else begin
            next_mst_state = VRF_SYNC_MST; // wait until slave is synced
          end
        end else begin
          next_mst_state = VRF_INT_READ1_MST; // wait until gnt
        end
      end
    end

    VRF_INT_READ2_MST: begin
      // 3 operands ops
      if (sel_operation_i[0] && sel_operation_i[2]) begin
        if (data_gnt_i) begin // todo: no sync mechanism with slave here
          if((slv_sync_mst[0] && instr_data_gnt_i) || last_iteration_q) begin
            // TODO: should actually sync with slv_sync_mst[0], but it is too old, so we use the 1 that is 1cc before
            next_mst_state = VRF_INT_READ3_MST;
          end else begin
            next_mst_state = VRF_SYNC_MST;
          end
        end else begin
          next_mst_state = VRF_INT_READ2_MST;
        end

      end else if (sel_operation_i[3]) begin
        // Must use the SAME threshold as the output logic above, which decides
        // whether a read is issued at all. 
        if (last_iteration_q || num_iterations_q == (no_offset ? 1 : 0)) begin
          next_mst_state = VRF_INT_READ1_MST;
        end else begin
          // Sync with slave on all iterations except the first
          if (data_gnt_i) begin
            if (first_iteration_q || (slv_sync_mst[3] && instr_data_gnt_i) || (last_iteration_odd_q)) begin
              next_mst_state = VRF_INT_READ1_MST;
            end else begin
              next_mst_state = VRF_SYNC_MST;
            end
          end else begin
            next_mst_state = VRF_INT_READ2_MST;
          end
        end
      end
    end

    VRF_INT_READ3_MST: begin
      if (sel_operation_i[3]) begin
        if (data_gnt_i || last_iteration_mst) begin
          if (first_iteration_q || (slv_sync_mst[3] && instr_data_gnt_i) || (last_iteration_odd_q)) begin
            next_mst_state = VRF_INT_READ1_MST;
          end else begin
            next_mst_state = VRF_SYNC_MST;
          end
        end else begin
          next_mst_state = VRF_INT_READ3_MST;
        end
      end
    end

    VRF_INT_WRITE_MST: begin
      if (last_iteration_q && even_iteration) begin
        next_mst_state = VRF_SYNC_MST; // wait at least 1cc to resync with slave
      end else if (last_iteration_odd_q && !even_iteration) begin
        next_mst_state = VRF_IDLE_MST;
      end else begin
        if (sel_operation_i[1]) begin
          if (data_gnt_i) begin
            if (!first_iteration_q) begin
              if (sel_operation_i[0] && sel_operation_i[2]) begin
                if (slv_sync_mst[2] && instr_data_gnt_i) begin
                  next_mst_state = VRF_INT_READ2_MST;
                end else begin
                  next_mst_state = VRF_SYNC_MST;
                end
              end else begin
                if ((slv_sync_mst[0] || slv_sync_mst[1]) && instr_data_gnt_i) begin
                  next_mst_state = VRF_INT_READ2_MST;
                end else begin
                  next_mst_state = VRF_SYNC_MST; // wait until slave is synced
                end
              end
            end else begin
              next_mst_state = VRF_INT_READ2_MST;
            end
          end else begin
            next_mst_state = VRF_INT_WRITE_MST; // wait until gnt
          end
        end else begin
          next_mst_state = VRF_IDLE_MST; // wait until gnt
        end
      end
    end

    // 2-source operands
    // -----------------
    VRF_LOAD_SLIDE: begin
      if (data_gnt_i) begin
        next_mst_state = VRF_READ_MST;
      end else begin
        next_mst_state = VRF_LOAD_SLIDE;
      end
    end

    VRF_READ_MST: begin
      if (!first_iteration_q) begin
        if (data_gnt_i) begin
          if (slv_sync_mst[0] || slv_sync_mst[1]) begin
            next_mst_state = VRF_WRITE_MST;
          end else begin
            next_mst_state = VRF_SYNC_MST; // wait until slave is synced
          end
        end else begin
          next_mst_state = VRF_READ_MST; // wait until gnt
        end
      end else begin
        next_mst_state = VRF_WRITE_MST;
      end
    end

    VRF_WRITE_MST: begin
      // For master-only ops (vmv.v.x/vmv.v.i, slides, single-beat .vx) the slave is never started,
      // mst_owns_tail degenerates to ~even_iteration whenever mst_start_slv_q is
      // set, so .vv/.vx with a running slave are unchanged.
      // Slides terminate through the first arm like any master-only op.
      if (last_iteration_mst && mst_owns_tail) begin
        next_mst_state = VRF_IDLE_MST;
      end else if (last_iteration_q && !mst_owns_tail) begin
        next_mst_state = VRF_SYNC_MST; // wait at least 1cc to resync with slave
      end else begin
        if (sel_operation_i[0] || sel_operation_i[1]) begin
          if (num_iterations_q == (no_offset ? 1 : 0) || (num_iterations_q == (no_offset ? 2 : 1) && !slide_op_i && even_iteration)) begin
            next_mst_state = VRF_READ_MST;
          end else begin
            if (data_gnt_i) begin
              if (slv_sync_mst[3] || first_iteration_q || last_iteration_odd_q) begin
              // Wait for slave to have written back its result
                next_mst_state = VRF_READ_MST;
              end else begin
                next_mst_state = VRF_SYNC_MST;
              end
            end else begin
              next_mst_state = VRF_WRITE_MST;
            end
          end
        end else begin
          next_mst_state = VRF_WRITE_MST; // TODO: check this case?
        end
      end
    end

    // Syn state in case the slave gets out of sync due to not received gntAC
    VRF_SYNC_MST: begin
      // TODO: check, for now we do not check which one is active
      if (saved_mst_state_q == VRF_IDLE_MST) begin
        // Returning to IDLE retires the instruction, which is only correct once
        // the slave has asserted done (now, or earlier in this instruction). The
        // generic exit below let registered sync bits alone send the master to
        // IDLE with req_i still high, so the ID stage re-issued the instruction:
        // a silent infinite loop, or a double accumulation for vmacc.
        if (vector_done_slv || slv_done_seen_q) begin
          next_mst_state = VRF_IDLE_MST;
        end else begin
          next_mst_state = VRF_SYNC_MST;
        end
      end else if(|slv_sync_mst || vector_done_slv) begin
        // Get back to the normal next state
        next_mst_state = saved_mst_state_q;
      end else begin
        next_mst_state = VRF_SYNC_MST;
      end
    end

    //-----------
    // Load/Store
    //-----------

    VRF_LOAD: begin
      // Writing word i needs word i+1 in (lsu_done_i), except for the last word (load_tail)
      if(lsu_done_i || load_tail) begin
        if (!first_iteration_q) begin
          if (data_gnt_i) begin
            if (!load_tail) begin
              next_mst_state = VRF_LOAD_WRITE;
            end else begin
              next_mst_state = VRF_DONE_MST; // done one cycle after the last write
            end
          end else begin
            next_mst_state = VRF_LOAD_WAITGNT;
          end
        end else begin
          next_mst_state = VRF_LOAD_WRITE;
        end
      end else begin
        next_mst_state = VRF_LOAD;
      end
    end

    VRF_LOAD_WAITGNT: begin
      if (data_gnt_i) begin
        // Not last_iteration_q: the last word may have just been sampled in rd_q and still needs its own write.
        if (load_tail_wr_q) begin
          next_mst_state = VRF_DONE_MST;
        end else begin
          next_mst_state = VRF_LOAD_WRITE;
        end
      end else begin
        next_mst_state = VRF_LOAD_WAITGNT;
      end
    end

    VRF_LOAD_WRITE: begin
      //if (last_iteration_q) begin
      //  next_mst_state = VRF_IDLE_MST;
      //end else begin
        next_mst_state = VRF_LOAD;
      //end
    end

    // Store
    // -----
    VRF_STORE_READ: begin
      // Proceed as soon as the value is sampled
      if (data_rvalid_i)  begin
        next_mst_state = VRF_STORE_WAITLSU;
      // The store is pipelined: this state issues the LSU write for the word
      // sampled on the PREVIOUS pass, which is why lsu_req_o is gated by
      // !first_iteration_q. On a single-beat store last_iteration_q is already
      // set while still in VRF_START_MST, so without the !first_iteration_q
      // term this would exit before the write has been requested at all.
      end else if (last_iteration_q && !first_iteration_q && lsu_gnt_i) begin
        next_mst_state = VRF_IDLE_MST;
      end else begin
        next_mst_state = VRF_STORE_READ;
      end
    end
    VRF_STORE_WAITLSU: begin
      if (lsu_done_i || first_iteration_q) begin
        //if (last_iteration_q) begin
        //  next_mst_state = VRF_IDLE_MST;  
        //end else 
        if (num_iterations_q == (no_offset ? 1 : 0)) begin
          next_mst_state = VRF_STORE_READ;
        end else begin
          if (data_gnt_i) begin
            next_mst_state = VRF_STORE_READ;
          end else begin
            next_mst_state = VRF_STORE_WAITGNT;
          end
        end
      end else begin
        next_mst_state = VRF_STORE_WAITLSU;
      end
    end
    VRF_STORE_WAITGNT: begin
      // Stay in this state until request is granted
      if (data_gnt_i) begin
        next_mst_state = VRF_STORE_READ;
      end else begin
        next_mst_state = VRF_STORE_WAITGNT;
      end
    end
    
    // Multicycle OPS
    // --------------
    // vmulh
    // Support is limited to two cycles ops only for now, otherwise the mechanism would be more complex

    VRF_MC_READ2_MST: begin
      if (sel_operation_i[1]) begin
        //if (!last_iteration_q) begin
        if (data_gnt_i) begin
          next_mst_state = VRF_MC_IDLE_MST;
        end else begin
          next_mst_state = VRF_MC_READ2_MST;
        end
      end else begin
        next_mst_state = ERR_STATE;
      end
    end

    VRF_MC_IDLE_MST: begin
      if (!slv_sync_mst[0] && !first_iteration_q) begin
        next_mst_state = VRF_SYNC_MST;
      end else begin
        next_mst_state = VRF_MC_READ1_MST;
      end
    end
    
    VRF_MC_READ1_MST: begin
      //if (first_iteration_q && !last_iteration_q) begin
      //  if (num_iterations_q != 1) begin // at least another iteration to perform
      //    if (data_gnt_i) begin
      //        next_mst_state = VRF_MC_WRITE_MST;
      //      end
      //    end else begin
      //      next_mst_state = VRF_MC_READ1_MST;
      //    end
      //  end else begin
      //    next_mst_state = VRF_MC_WRITE_MST; //todo: check (write but nothing to read)
      //  end
      //end else begin
        if (last_iteration_q && !even_iteration && first_iteration_q) begin
          next_mst_state = VRF_MC_WRITE_MST;
        end else if (last_iteration_q && !even_iteration) begin
          next_mst_state = VRF_MC_FINISH_MST;
          if (!first_iteration_q && !slv_sync_mst[3]) begin
            if (data_gnt_i) begin
              next_mst_state = VRF_SYNC_MST;
            end else begin
              next_mst_state = VRF_MC_READ1_MST;
            end
          end
        end else if (last_iteration_q && even_iteration) begin
          next_mst_state = VRF_IDLE_MST;
        end else begin
          if (data_gnt_i || num_iterations_q == 1) begin //blabla
            next_mst_state = VRF_MC_WRITE_MST;
          end else begin
            next_mst_state = VRF_MC_READ1_MST;
          end
        end
      end

    VRF_MC_WRITE_MST: begin
      // TODO: handle last iteration
      if (data_gnt_i) begin
        if (!slv_sync_mst[1]) begin
          next_mst_state = VRF_SYNC_MST;
        end else begin
          if (last_iteration_q && !even_iteration) begin
            next_mst_state = VRF_MC_FINISH_MST;
          end else begin
            next_mst_state = VRF_MC_READ2_MST;
          end
        end
      end else begin
        next_mst_state = VRF_MC_WRITE_MST;
      end
    end

    VRF_MC_READ: begin
      if (data_gnt_i) begin
        if (!first_iteration_q) begin
          next_mst_state = VRF_MC_WRITE_SINGLE;
        end else begin
          next_mst_state = VRF_MC_READ_FIRST;
        end
      end else begin
        next_mst_state = VRF_MC_READ;
      end
    end
  
    VRF_MC_READ_FIRST: begin
      if (data_rvalid_i) begin
        next_mst_state = VRF_MC_WRITE_SINGLE;
      end else begin
        next_mst_state = VRF_MC_READ_FIRST;
      end
    end

    VRF_MC_WRITE_SINGLE: begin
      // Terminate on mc_last_q (set by the preceding VRF_MC_READ), not on
      // last_iteration_q. The exit
      // waits for the grant of this state's write request, which is always
      // issued here, so a late grant do not drop the final write.
      // On the final write, retire through VRF_DONE_MST (vector_done one cycle later).
      if (data_gnt_i) begin
        if (mc_last_q) begin
          next_mst_state = VRF_DONE_MST; // done one cycle after the last write
        end else begin
          next_mst_state = VRF_MC_READ;
        end
      end else begin
        next_mst_state = VRF_MC_WRITE_SINGLE;
      end
    end

    // Retire one cycle after the final VRF write was granted, so that its
    // response arrives while the vector op is still active (see VRF_LOAD).
    VRF_DONE_MST: begin
      next_mst_state = VRF_IDLE_MST;
    end

    VRF_MC_FINISH_MST: begin
      next_mst_state = VRF_IDLE_MST;
    end

    ERR_STATE: begin
      next_mst_state = ERR_STATE;
    end

    default: begin
    end

  endcase
end


//---------------
// Internal logic
//---------------

always_comb begin
  // Register enables
  rs1_en_mst = 1'b0;
  rs2_en_mst = 1'b0;
  rs3_en_mst = 1'b0;
  rd_en_mst  = 1'b0;

  write_delayed = 1'b0;
  read_delayed = 1'b0;
  // Data memory interface
  data_req_o = 1'b0;
  data_we_o  = 1'b0;
  // The master always load the intial counters
  agu_load_o = 1'b0;
  agu_get_rs1_mst = 1'b0;
  agu_get_rs2_mst = 1'b0;
  agu_get_rd_mst = 1'b0;
  agu_incr_mst = 3'b000; // default no incr
  first_iteration_d = first_iteration_q;
  // Iteration counter decrement
  dec_iterations_mst = 1'b0;
  vector_done_mst = 1'b0;
  // TODO: left unchanged for now
  // slide
  slide_buffer_en = 1'b0;
  slide_offset_en = 1'b0;
  slide_first_write_d = slide_first_write_q;
  sel_slide_be = 1'b0;
  // LSU signals
  lsu_req_o = 1'b0;
  data_load_addr_o = 1'b0;
  // Demux to handle sub-word mem accesses
  next_demux_sel = curr_demux_sel;
  mux_sel = '0;
  //next_rs1_demux_sel = '0;
  ex_stall_o = 1'b0;
  first_mc_write_d = first_mc_write_q;
  mc_last_d = mc_last_q;
  next_mc_demux_sel = curr_mc_demux_sel;
  next_mc_rd_demux_sel = curr_mc_rd_demux_sel;
  next_mc_mux_sel = curr_mc_mux_sel;
  next_mc_rd_mux_sel = curr_mc_rd_mux_sel;
  // Sync signals with slave FSM
  mst_sync_slv_d = 4'b0;
  mst_start_slv = 1'b0;
  sample_sync_mst = 1'b0;
  sel_sync_mst = 1'b0;
  saved_mst_state_d = curr_mst_state; // default saved state is the current one, in case we need to go in sync we save the next_state


  case(curr_mst_state)
  VRF_IDLE_MST: begin
    next_demux_sel = 1'b0;
    if (req_i && vl_i == '0) begin
      vector_done_mst  = 1'b1;
    end else if (req_i && vl_i != '0) begin
      agu_load_o = 1'b1; // load the initial values of the counters
      // Data memory if - load the start address
      if (memory_op_i) data_load_addr_o = 1'b1;
      // memory ops and slide do not have access to the double interface, as
      // first use the LSU that is share, second could not respect the interleaved bank policy
      slide_offset_en = slide_op_i;
      // agu_load_o must stay ungated here: it is what makes slide_offset_i carry
      // the byte offset this cycle, and slide_empty is computed from it.
      if (slide_empty) vector_done_mst = 1'b1;
    end
  end
  VRF_START_MST: begin
    first_iteration_d = 1'b1;
    slide_first_write_d = 1'b1;
    next_mc_demux_sel = 1'b0;
    next_mc_mux_sel = 1'b0;
    next_mc_rd_mux_sel = 1'b0;
    next_mc_rd_demux_sel = 1'b0;
    first_mc_write_d = 1'b0;
    mc_last_d = 1'b0;
    if (!memory_op_i) begin   // ARITH Op
      if (mult_ops_i) begin
        data_req_o = 1'b1;
        mst_start_slv = slv_active; // Start slave FSM next cycle, only if it has a beat to do
        if (sel_operation_i[0]) agu_get_rs1_mst = 1'b1;
        else agu_get_rs2_mst = 1'b1;
        if (data_gnt_i) begin
          if (sel_operation_i[0]) begin
            agu_incr_mst[0] = 1'b1;
            mst_sync_slv_d[0] = 1'b1;
          end else begin
            agu_incr_mst[1] = 1'b1;
            mst_sync_slv_d[1] = 1'b1;
          end
          if (multicycle_op_i) begin
            mst_start_slv = 1'b0; // for now single interface only supported
            agu_incr_mst[0] = 1'b1;
            mst_sync_slv_d[0] = 1'b1;
            first_mc_write_d = 1'b1;
            next_mc_demux_sel = 1'b0;
          end
        end
      end else begin // .vx, slide
        if (sel_operation_i[0] || sel_operation_i[1]) begin
          data_req_o = 1'b1;
          if (sel_operation_i[0]) agu_get_rs1_mst = 1'b1;
          else agu_get_rs2_mst = 1'b1;
          if (data_gnt_i) begin
            if (!slide_op_i && !multicycle_op_i) begin
              // Start slave FSM on .vx except on slide and move, and only when
              // there is a second beat for the slave to execute
              mst_start_slv = slv_active;
            end
            if (sel_operation_i[0]) begin
              agu_incr_mst[0] = 1'b1;
              mst_sync_slv_d[0] = 1'b1;
            end else begin
              agu_incr_mst[1] = 1'b1;
              mst_sync_slv_d[1] = 1'b1;
            end
            if (multicycle_op_i) begin
              first_mc_write_d = 1'b1;
            end
          end
        end else if (sel_operation_i[3]) begin
          data_req_o = 1'b1;
          data_we_o = 1'b1;
          agu_get_rd_mst = 1'b1;
          if (data_gnt_i) begin
            agu_incr_mst[2] = 1'b1;
            mst_sync_slv_d[3] = 1'b1;
          end
        end
      end
      
    end else begin // MEMORY ops
      if (sel_operation_i[2] == 1'b1) begin           // store
        data_req_o = 1'b1;
        agu_get_rd_mst = 1'b1;
        if (data_gnt_i) begin
          agu_incr_mst[2] = 1'b1;
        end
      end else if (sel_operation_i[3]==1'b1) begin  // load
        lsu_req_o = 1'b1;
      end
    end
  end

  //-----------
  // Arithmetic
  //-----------
  VRF_INT_READ1_MST: begin
    if (data_rvalid_i && !last_iteration_mst) begin
      if (sel_operation_i[0]) rs1_en_mst = 1;
      else rs2_en_mst = 1;
    end
    if (!first_iteration_q) begin
      data_we_o = 1'b1;
      data_req_o = 1'b1;
      agu_get_rd_mst = 1'b1;
      write_delayed = ~data_gnt_i;
      if (data_gnt_i) begin
        if (((!slv_sync_mst[1] && sel_operation_i[0]) || (!slv_sync_mst[2] && sel_operation_i[1])) && !last_iteration_mst && num_iterations_q != 1 && !last_iteration_q) begin
          saved_mst_state_d = VRF_INT_WRITE_MST;
          sample_sync_mst = 1'b1; // sample the next state of the master  
        end
        agu_incr_mst[2] = 1'b1;
        mst_sync_slv_d[3] = 1'b1; // write incs
      end
    end
    //else begin
    //  first_iteration_d = 1'b0;
    //end
  end
  VRF_INT_READ2_MST: begin
    if (data_rvalid_i) begin
      if (sel_operation_i[0]) rs2_en_mst = 1'b1;
      else rs3_en_mst = 1'b1;
    end
    if (sel_operation_i[0] && sel_operation_i[2]) begin // vmacc.vv
      data_req_o = 1'b1;
      agu_get_rd_mst = 1'b1;
      if (data_gnt_i) begin
        //agu_incr_mst[2] = 1'b1; (increment only on write back)
        mst_sync_slv_d[2] = 1'b1;
        if (!slv_sync_mst[0]) begin
          saved_mst_state_d = VRF_INT_READ3_MST;
          sample_sync_mst = 1'b1;
        end
      end
    // if next operation is WRITE RD
    end else if (sel_operation_i[3]) begin
      // Threshold must follow no_offset, as everywhere else the counter is
      // compared (see the counter block and VRF_MC_FINISH_MST): with a partial
      // tail the last beat sits at 0, not at 1.
      if (!last_iteration_q && num_iterations_q != (no_offset ? 1 : 0)) begin
        data_req_o = 1'b1;
        if (sel_operation_i[0]) agu_get_rs1_mst = 1'b1;
        else agu_get_rs2_mst = 1'b1;
        if (data_gnt_i) begin
          if (first_iteration_q) begin
            first_iteration_d = 1'b0;
          end
          if (sel_operation_i[0]) begin
            agu_incr_mst[0] = 1'b1;
            mst_sync_slv_d[0] = 1'b1;
          end else begin
            agu_incr_mst[1] = 1'b1;
            mst_sync_slv_d[1] = 1'b1;
          end
          if (!(first_iteration_q || slv_sync_mst[3])) begin
            saved_mst_state_d = VRF_INT_READ1_MST;
            sample_sync_mst = 1'b1; // sample the next state of the master
          end
        end
      end else begin
        // No further operand read is issued on this path (the master has no
        // beat left to fetch). Both operands of the pending result have been
        // sampled by now. This matters when the master owns a single beat
        if (first_iteration_q) begin
          first_iteration_d = 1'b0;
        end
        // The sync pulse must be driven even though no read is issued: the slave
        // consumes it in VRF_INT_WRITE_SLV to leave its write state. When the
        // slave owns the final beat this is its only way out, and without it the
        // slave stalls in VRF_SYNC_SLV. No agu_incr here, since no address was
        // consumed, and no data_gnt_i qualifier, since no request was made.
        if (sel_operation_i[0]) begin
          mst_sync_slv_d[0] = 1'b1;
        end else begin
          mst_sync_slv_d[1] = 1'b1;
        end
      end
    end

  end
  VRF_INT_READ3_MST: begin
    if (data_rvalid_i) rs3_en_mst = 1'b1;
    if (sel_operation_i[3]) begin
      if (!last_iteration_mst) begin
        data_req_o = 1'b1;
        agu_get_rs1_mst = 1'b1;
        if (data_gnt_i) begin
          agu_incr_mst[0] = 1'b1;
          mst_sync_slv_d[0] = 1'b1;
          if (first_iteration_q) begin
            first_iteration_d = 1'b0;
          end
          if (!(first_iteration_q || slv_sync_mst[3])) begin
            saved_mst_state_d = VRF_INT_READ1_MST;
            sample_sync_mst = 1'b1; // sample the next state of the master
          end
        end
      end else begin
        if (first_iteration_q) begin
          first_iteration_d = 1'b0;
        end
      end
    end
  end


  VRF_INT_WRITE_MST: begin
    if (last_iteration_mst && !even_iteration) begin
      vector_done_mst = 1'b1;
    //end else if (last_iteration_odd_q && !even_iteration) begin
    //  vector_done_mst = 1'b1;
    end else if (last_iteration_mst && even_iteration) begin
      vector_done_mst = 1'b0; // Do nothing, last iteration is for the slave
      saved_mst_state_d = VRF_IDLE_MST;
      sample_sync_mst = 1'b1;
    end else begin
      if (sel_operation_i[1]) begin
        data_req_o = 1'b1;
        if (sel_operation_i[0]) begin 
          agu_get_rs2_mst = 1'b1;
        end else begin
          agu_get_rd_mst = 1'b1;
        end
        if (data_gnt_i) begin
          if (sel_operation_i[0]) begin
            agu_incr_mst[1] = 1'b1;
            mst_sync_slv_d[1] = 1'b1;  // get rs2
          end else if (sel_operation_i[1]) begin
            agu_incr_mst[2] = 1'b1;
            mst_sync_slv_d[2] = 1'b1;  // get rd
          end
             // TODO: check if else should be handled
          if (sel_operation_i[0] && sel_operation_i[2]) begin //vmacc.vv
            if (!slv_sync_mst[2]) begin
              saved_mst_state_d = VRF_INT_READ2_MST;
              sample_sync_mst = 1'b1;
            end
          end else begin
            if (!(slv_sync_mst[0] || slv_sync_mst[1])) begin
              saved_mst_state_d = VRF_INT_READ2_MST;
              sample_sync_mst = 1'b1;
            end
          end
          dec_iterations_mst = 1'b1;
          //if (num_iterations_q == (no_offset ? 1 : 0)) last_iteration_d = 1'b1;
          //else num_iterations_d = num_iterations_q - 1;
        end else begin
          //num_iterations_d = num_iterations_q;   // if the operation wasn't accepted we need to repeat it
        end
      end
    end
  end

  // 2-source operands
  // -----------------
  VRF_LOAD_SLIDE: begin
    if (data_rvalid_i) begin
      rs2_en_mst = 1'b1;
      slide_buffer_en = 1'b1;
    end
    data_req_o = 1'b1;
    agu_get_rs2_mst = 1'b1;
    if(data_gnt_i) begin
      agu_incr_mst[1] = 1'b1;
    end
  end
  VRF_READ_MST: begin
    // SAMPLE
    if (data_rvalid_i && !last_iteration_mst) begin
      rs2_en_mst = 1'b1;
      if (slide_op_i) slide_buffer_en = 1'b1;
    end
    if (!first_iteration_q) begin
      data_we_o = 1'b1;
      data_req_o = 1'b1;
      agu_get_rd_mst = 1'b1;
      write_delayed = ~(data_gnt_i); // TODO: check
      if (slide_first_write_q && is_slide_up_i) sel_slide_be = 1'b1;
      if (data_gnt_i) begin
        agu_incr_mst[2] = 1'b1;
        slide_first_write_d = 1'b0; // only the first slideup write uses slide_offset_be
        mst_sync_slv_d[3] = 1'b1; // write incs
      if (!(slv_sync_mst[0] || slv_sync_mst[1] || last_iteration_mst)) begin
          saved_mst_state_d = VRF_WRITE_MST;
          sample_sync_mst = 1'b1;
        end
      end
    end
  end
  VRF_WRITE_MST: begin
    // Must assert done on exactly the conditions that reach VRF_IDLE_MST above.
    if (last_iteration_mst && mst_owns_tail) begin
      vector_done_mst = 1'b1;
    end else if (last_iteration_mst) begin
      vector_done_mst = 1'b0; // Do nothing, last iteration is for the slave
      saved_mst_state_d = VRF_IDLE_MST;
      sample_sync_mst = 1'b1;
    end else begin
      // if next operation is READ
      if (sel_operation_i[0] || sel_operation_i[1]) begin
        // Stop fetching when the master has no beat left: at VRF_WRITE_MST of
        // round j the counter holds N-2j, and the master's next beat 2j+2 does
        // not exist once the counter is at T (slave owns the tail -> the master
        // already did its last) or at T+1 when the slave owns the final beat.
        // T+1 is 2 only when no_offset; with a partial tail the final master
        // round sits at 1, which matched NEITHER of the old terms, so the master
        // over-ran by a beat. The !slide_op_i guard on the second term is
        // untouched, so slides never evaluate it and are bit-identical.
        // Must stay textually identical to the next-state guard in this state.
        if (num_iterations_q == (no_offset ? 1 : 0) || (num_iterations_q == (no_offset ? 2 : 1) && !slide_op_i && even_iteration)) begin
          data_req_o = 1'b0;
          dec_iterations_mst = 1'b1;
          // no further operand read is issued here, so release the first-iteration flag, otherwise
          // VRF_READ_MST never takes its !first_iteration_q write path and vd is
          // never written at all.
          if (first_iteration_q) begin
            first_iteration_d = 1'b0;
          end
        end else begin 
          data_req_o = 1'b1;
          if (sel_operation_i[0]) begin
            agu_get_rs1_mst = 1'b1;
          end else begin
            agu_get_rs2_mst = 1'b1;
          end
          if (data_gnt_i) begin
            dec_iterations_mst = 1'b1;
            if (first_iteration_q) begin
              first_iteration_d = 1'b0;
            end
            if (sel_operation_i[0]) begin
              agu_incr_mst[0] = 1'b1;
              mst_sync_slv_d[0] = 1'b1;
            end else begin
              agu_incr_mst[1] = 1'b1;
              mst_sync_slv_d[1] = 1'b1;
            end
            if (!slv_sync_mst[3]) begin
              saved_mst_state_d = VRF_READ_MST;
              sample_sync_mst = 1'b1;
            end
          end
        end
      // if we don't read vs2 it means we write again
      end else begin
        data_we_o = 1'b1;
        data_req_o = 1'b1;
        agu_get_rd_mst = 1'b1;
        if (data_gnt_i) begin
          // TODO: check: moved here to ensure that slave FSM correctly sees the first_iteration_q flag still at 1 on its first iteration
          if (first_iteration_q) begin
            first_iteration_d = 1'b0;
          end
          agu_incr_mst[2] = 1'b1;
          mst_sync_slv_d[3] = 1'b1; // write incs
          dec_iterations_mst = 1'b1;
        end
      end
    end

  end
  VRF_SYNC_MST: begin
    sel_sync_mst = 1'b1; // default is to sample the next state of the master FSM, as we save it when we enter in sync
  end
  //-----------
  // Load/Store
  //----------- 

  VRF_LOAD: begin
    if (lsu_done_i) rd_en_mst = 1'b1;
    if (lsu_done_i || load_tail) begin
      if (!first_iteration_q) begin
        data_we_o = 1'b1;
        data_req_o = 1'b1;
        agu_get_rd_mst = 1'b1;
        write_delayed = ~data_gnt_i;
        if (data_gnt_i) begin
          agu_incr_mst[2] = 1'b1;
          // vector_done for the last write is asserted in VRF_DONE_MST, one cycle
          // after this grant: the write's response must arrive while the vector op
          // is still active, otherwise cve2_dmem_switch hands it to the scalar LSU,
          // which writes it into the rd of the next instruction.
        end
      end else begin
        first_iteration_d = 1'b0;
      end
    end
  end
  VRF_LOAD_WAITGNT: begin
    data_we_o = 1'b1;
    data_req_o = 1'b1;
    agu_get_rd_mst = 1'b1;
    // Keep the delay FSM on buffer_q until the grant: rd_q may already hold the next word
    write_delayed = ~data_gnt_i;
    if (data_gnt_i) begin
      agu_incr_mst[2] = 1'b1;
    end
  end
  VRF_LOAD_WRITE: begin
    //if (last_iteration_q) begin
    //  vector_done_mst = 1'b1;
    //end else begin
      // Request to LSU only if not last iteration
      // Iterations are decremented by the m  ain logic
    if (!last_iteration_q && !(num_iterations_q == (no_offset ? 1 : 0))) begin
      dec_iterations_mst = 1'b1;
      lsu_req_o = 1'b1;
    end
    //end
  end
  VRF_STORE_READ: begin
    if (data_rvalid_i) rs3_en_mst = 1'b1;
    if (data_rvalid_i || last_iteration_q) begin
      // Done only on the pass that actually raises lsu_req_o below: on the
      // first pass the word has just been sampled and no write was requested.
      vector_done_mst = last_iteration_q && !first_iteration_q && lsu_gnt_i;
      if (!first_iteration_q) begin
        lsu_req_o = 1'b1;
        if (lsu_offset_q != 2'b00) begin
          mux_sel = ~curr_demux_sel;
        end
        if (!lsu_gnt_i) read_delayed = 1'b1;
      end
    end
  end
  VRF_STORE_WAITLSU: begin
    if (lsu_offset_q != 2'b00) begin
        mux_sel = ~curr_demux_sel; // keep constant out mux selection
    end
    if (lsu_done_i || first_iteration_q) begin
      first_iteration_d = 1'b0;
      //read_delayed = 1'b0;
      // Exit condition
      //if (last_iteration_q) begin
      //  vector_done_mst = 1'b1;
      //  //num_iterations_d = '0;
      //// In the last cycle we don't read the operand
      //end else
      if (num_iterations_q == (no_offset ? 1 : 0)) begin
        //last_iteration_d = 1'b1;
        if (lsu_offset_q != 2'b00 && lsu_done_i) begin
          next_demux_sel = ~curr_demux_sel;
        end
      // Send read request to memory
      //end else if (lsu_offset_i != 2'b00 && first_iteration_q) begin //!lsu_done_i
      //  // do the request to the LSU and wait until done
      //  vrf_next_state = VRF_STORE_READ;
      end else begin
        dec_iterations_mst = 1'b1;
        data_req_o = 1'b1;
        agu_get_rd_mst = 1'b1;
        if (data_gnt_i) begin
          if (lsu_offset_q != 2'b00) begin
            // Request is for the same data (previous read data already consumed)
            next_demux_sel = ~curr_demux_sel;
          end 
          agu_incr_mst[2] = 1'b1;
        end
      end
    // we wait in this state
    end
  end
  VRF_STORE_WAITGNT: begin
    data_req_o = 1'b1;
    agu_get_rd_mst = 1'b1;
    if (data_gnt_i) begin
      agu_incr_mst[2] = 1'b1;
    end
  end

  //---------------
  // Multicycle Ops
  //---------------

  VRF_MC_READ2_MST: begin
    // Sample first operand and read second operand
    if (data_rvalid_i && sel_operation_i[0] && first_iteration_q) begin
      rs1_en_mst = 1'b1;
      if (first_iteration_q) begin
        // Tell slave FSM it can start in the next cycle, only if it has a beat to
        // do (same gating as VRF_START_MST). Started for a single-beat op, the
        // slave was left stranded in VRF_SYNC_SLV when the master finished alone,
        // and the next MC op resumed from that stale state without reading its
        // operands: vmulh.vv vl=2 after vl=1 wrote 0 for the slave's beat.
        mst_start_slv = slv_active;
        //mst_sync_slv_d[1] = 1'b1; // get rs1 // TODO: do with the correct one
      end
    end
    // Request RS2
    if (sel_operation_i[1]) begin
      //if (!last_iteration_q) begin
      data_req_o = 1'b1;
      if (sel_operation_i[0]) begin
        agu_get_rs2_mst = 1'b1;
        if (data_gnt_i) begin
          // TODO: handle last iteration
          agu_incr_mst[1] = 1'b1;
          mst_sync_slv_d[1] = 1'b1; // get rs2
        end
      end
      //end
    end
    if (!first_iteration_q) begin
      rd_en_mst = 1'b1;
    end
  end


  VRF_MC_IDLE_MST: begin
    // Sample RS2, do not make any request to mem
    if (data_rvalid_i && sel_operation_i[1]) begin
      rs2_en_mst = 1'b1;
    end
    if (!slv_sync_mst[0] && !first_iteration_q) begin
      saved_mst_state_d = VRF_MC_READ1_MST;
      sample_sync_mst = 1'b1; // sample the next state of the master
    end
  end

  VRF_MC_READ1_MST: begin
    // Read RS1 of next iteration (do not sample anything, keep A constant)
    if (!last_iteration_q && !last_iteration_mst) begin
      if (num_iterations_q != 1) begin
        data_req_o = 1'b1;
        if (sel_operation_i[0]) begin
          agu_get_rs1_mst = 1'b1;
          if (data_gnt_i) begin
            agu_incr_mst[0] = 1'b1;
            mst_sync_slv_d[0] = 1'b1; // get rs1
            if (!first_iteration_q && !slv_sync_mst[3]) begin
              saved_mst_state_d = VRF_MC_WRITE_MST;
              sample_sync_mst = 1'b1; // sample the next state of the master
            end
            //if (num_iterations_q == (no_offset ? 1 : 0))
            //  last_iteration_d = 1'b1;
          end
        end
      //end else begin
        // TODO: check whether to put elsewhere
      //  dec_iterations_mst = 1'b1;
      //end
        if (first_iteration_q) begin
          first_iteration_d = 1'b0;
        end
      end
    end
    if (last_iteration_q && even_iteration) begin
      ex_stall_o = 1'b1;
    end
  end

  VRF_MC_WRITE_MST: begin
    // Sample the next iteration RS1
    if (!last_iteration_q) begin
      rs1_en_mst = 1'b1;
    end
    if (sel_operation_i[3]) begin
      data_req_o = 1'b1;
      data_we_o = 1'b1;
      agu_get_rd_mst = 1'b1;
      write_delayed = ~data_gnt_i; // TODO: check
      if (data_gnt_i) begin
        agu_incr_mst[2] = 1'b1;
        mst_sync_slv_d[3] = 1'b1; // write incs
        if (!slv_sync_mst[1]) begin
          saved_mst_state_d = VRF_MC_READ2_MST;
          sample_sync_mst = 1'b1; // sample the next state of the master
        end
        if (!last_iteration_q) begin
          dec_iterations_mst = 1'b1;
        end
        if (num_iterations_q == (no_offset ? 1 : 0)) begin
          ex_stall_o = 1'b0;
        end else begin
          ex_stall_o = 1'b1; // stall the EX stage
        end
          // TODO: check where to do this
          //next_mc_mux_sel = ~curr_mc_mux_sel;
          //next_mc_rd_mux_sel = ~curr_mc_rd_mux_sel;
          //next_mc_rd_demux_sel = ~curr_mc_rd_demux_sel;
        //end else begin
        //  vector_done_mst = 1'b1;
      end
    end
      //if (first_mc_write_q) begin
      //  first_mc_write_d = 1'b0;
      //end
  end

  VRF_MC_READ: begin
    data_req_o = 1'b1;
    agu_get_rs2_mst = 1'b1;
    if (data_gnt_i) begin
      agu_incr_mst[1] = 1'b1;
      if (num_iterations_q != (no_offset ? 1 : 0)) begin
        dec_iterations_mst = 1'b1;
      end
      // Counter already at T: no decrement, and the write that follows this
      // read is the final one (same threshold as the decrement guard above).
      mc_last_d = (num_iterations_q == (no_offset ? 1 : 0));
      if (first_iteration_q) begin
        if (data_rvalid_i) begin
          rs2_en_mst = 1'b1;
          next_mc_demux_sel = ~curr_mc_demux_sel;
        end
        first_iteration_d = 1'b0;
        ex_stall_o = 1'b1; // stall the EX stage until the next read is done
      end
    end
  end

  VRF_MC_READ_FIRST: begin
    if (data_rvalid_i) begin
      rs2_en_mst = 1'b1;
      next_mc_demux_sel = ~curr_mc_demux_sel;
    end
  end

  VRF_MC_WRITE_SINGLE: begin
    data_req_o = 1'b1;
    data_we_o = 1'b1;
    agu_get_rd_mst = 1'b1;
    if (data_rvalid_i) begin
      rs2_en_mst = 1'b1;
      next_mc_demux_sel = ~curr_mc_demux_sel;
    end
    if (data_gnt_i) begin
      agu_incr_mst[2] = 1'b1;
      next_mc_mux_sel = ~curr_mc_mux_sel;
      // On the last write (mc_last_q) done is asserted in VRF_DONE_MST
    end
  end

  VRF_DONE_MST: begin
    vector_done_mst = 1'b1;
    // Hold the multiplier, as VRF_MC_FINISH_MST does: the instruction is still in
    // EX this cycle with the multiplier enabled (vmulh*.vx), and without the stall
    // its FSM steps MULL -> MULH, so the NEXT multiply (e.g. a scalar mulh) starts
    // in MULH and returns only ah*bh. ex_stall_o feeds nothing else.
    ex_stall_o = 1'b1;
  end

  VRF_MC_FINISH_MST: begin
    ex_stall_o = 1'b1; // unstall the EX stage
    vector_done_mst = 1'b1;
  end
  default: begin
  end


endcase
end




//----------
// Slave FSM
//----------
always_comb begin
  next_slv_state = curr_slv_state;
  case(curr_slv_state)
    VRF_IDLE_SLV: begin
      if (mst_start_slv && mst_sync_slv != '0) begin
        // Mst has entered the start state and the first request has been granted
        next_slv_state = VRF_START_SLV;
      end else begin
        next_slv_state = VRF_IDLE_SLV;
      end
    end
    VRF_START_SLV: begin
      // Already know it is a valid operation for the slave, as the master
      // only assert mst_start_slv in that case
      if (instr_data_gnt_i) begin
        if (multicycle_op_i) begin // vmulh
          next_slv_state = VRF_MC_READ2_SLV;
        end else if (mult_ops_i) begin // Normal 2ops VV op
          next_slv_state = VRF_INT_READ1_SLV;
        end else begin
          next_slv_state = VRF_READ_SLV; // .vx
        end
      end else begin
        next_slv_state = VRF_START_SLV;
      end
    end

    // Arithmetic Ops
    //---------------
    // 2/3-source operands

    VRF_INT_READ1_SLV: begin
      if (first_iteration_q) begin
        //if (sel_operation_i[0]) begin
          if ((mst_sync_slv[1] && sel_operation_i[0]) || (mst_sync_slv[2] && sel_operation_i[1])) begin  
            next_slv_state = VRF_INT_WRITE_SLV;
          end else begin
            next_slv_state = VRF_SYNC_SLV;
          end
        //end else if (sel_operation_i[1]) begin
        //  if (mst_sync_slv[1]) begin
        //    next_slv_state = VRF_INT_WRITE_SLV;
        //  end else begin
        //    next_slv_state = VRF_SYNC_SLV;
        //  end
        //end else begin
        //  // Stay in this state until the mst has received its grant (cannot go ahead otherwise)
        //  next_slv_state = VRF_INT_READ1_SLV; // wait until master gives the sync
        //end
      end else begin
        if (instr_data_gnt_i) begin
          // When gnt from VRF and mst has already finished its write
          if (sel_operation_i[0] || !sel_operation_i[2]) begin
            if (mst_sync_slv[0] || mst_sync_slv[1] || last_iteration_q) begin
              next_slv_state = VRF_INT_WRITE_SLV;
            end else begin
              next_slv_state = VRF_SYNC_SLV; // wait until master is synced
            end
          end else begin
            if (mst_sync_slv[2] || last_iteration_q) begin
              next_slv_state = VRF_INT_WRITE_SLV;
            end else begin
              next_slv_state = VRF_SYNC_SLV; // wait until master is synced
            end
          
          end
        end else begin
          next_slv_state = VRF_INT_READ1_SLV; // wait until gnt
        end
      end
    end

    VRF_INT_READ2_SLV: begin
      // 3 operands ops
      if (sel_operation_i[0] && sel_operation_i[2]) begin
        if (instr_data_gnt_i) begin
          if (mst_sync_slv[0] || (last_iteration_q) ) begin
            next_slv_state = VRF_INT_READ3_SLV;
          end else begin
            next_slv_state = VRF_SYNC_SLV;
          end
        end else begin
          next_slv_state = VRF_INT_READ2_SLV;
        end
      end else if (sel_operation_i[3]) begin
        // The slave's last beat is B-1 when the beat count is EVEN (the slave
        // owns the tail) but only B-2 when it is ODD (the master owns the tail),
        // so the threshold is parity-dependent. Only the even case with a partial
        // tail needs the lowered value; everywhere else the original `== 1` is
        // correct, and lowering it there makes the slave issue one read too many,
        // whose agu_incr_slv advances the SHARED rs1 pointer (agu_incr_o is the OR
        // of both FSMs) and corrupts the master's tail beat.
        if (last_iteration_q || num_iterations_q == ((!no_offset && even_iteration) ? 0 : 1)) begin
          next_slv_state = VRF_INT_READ1_SLV;
        end else begin
          if (instr_data_gnt_i) begin
            if (mst_sync_slv[3]) begin
              next_slv_state = VRF_INT_READ1_SLV;
            end else begin
              next_slv_state = VRF_SYNC_SLV;
            end
          end else begin
            next_slv_state = VRF_INT_READ2_SLV;
          end
        end
      end
    end

    VRF_INT_READ3_SLV: begin
      if (sel_operation_i[3]) begin
        if (last_iteration_q) begin
          next_slv_state = VRF_INT_READ1_SLV;
        end else begin
          if (instr_data_gnt_i) begin
            if (mst_sync_slv[3]) begin
              next_slv_state = VRF_INT_READ1_SLV;
            end else begin
              next_slv_state = VRF_SYNC_SLV;
            end
          end else begin
            next_slv_state = VRF_INT_READ3_SLV;
          end
        end
      end
    end

    VRF_INT_WRITE_SLV: begin
      if (last_iteration_q) begin
        next_slv_state = VRF_IDLE_SLV;
      end else begin
        if (sel_operation_i[1]) begin
          if (instr_data_gnt_i) begin
            if (sel_operation_i[2]) begin
            // vmacc.vv, vmacc.vx
              if ((mst_sync_slv[2]|| mst_sync_slv[1]) || (num_iterations_q == 1 && even_iteration)) begin
                next_slv_state = VRF_INT_READ2_SLV;
              end else begin
                next_slv_state = VRF_SYNC_SLV;
              end
            end else begin
              if (mst_sync_slv[0] || (num_iterations_q == 1 && even_iteration)) begin
                next_slv_state = VRF_INT_READ2_SLV;
              end else begin
                next_slv_state = VRF_SYNC_SLV;
              end
            end
          end else begin
            next_slv_state = VRF_INT_WRITE_SLV; // wait until gnt and mst granted
          end
        end else begin
          next_slv_state = VRF_IDLE_SLV; // wait until gnt
        end
      end
    end

    // 2-source operands
    // -----------------
    VRF_READ_SLV: begin
      if (!first_iteration_q) begin
        if (instr_data_gnt_i) begin
          // no master sync left to wait for
          if (mst_sync_slv[0] || mst_sync_slv[1] || last_iteration_q
            || (num_iterations_q == (no_offset ? 1 : 0))
            || (even_iteration && num_iterations_q == (no_offset ? 2 : 1))) begin
            next_slv_state = VRF_WRITE_SLV;
          end else begin
            next_slv_state = VRF_SYNC_SLV;
          end
        end else begin
          next_slv_state = VRF_READ_SLV; // wait until gnt
        end
      end else begin
        next_slv_state = VRF_WRITE_SLV;
      end
    end

    VRF_WRITE_SLV: begin
      if (last_iteration_q) begin
        next_slv_state = VRF_IDLE_SLV;
      end else begin
        if (sel_operation_i[0] || sel_operation_i[1]) begin
          if ((num_iterations_q == (no_offset ? 2 : 1) && !even_iteration)
            || num_iterations_q == (no_offset ? 1 : 0) || last_iteration_q) begin
              if (mst_sync_slv[3]) begin
                next_slv_state = VRF_READ_SLV;
              end else begin
                next_slv_state = VRF_SYNC_SLV;
              end
          end else begin
            if (instr_data_gnt_i) begin
              // Wait for slave to have written back its result
              if (mst_sync_slv[3]) begin
                next_slv_state = VRF_READ_SLV;
              end else begin
                next_slv_state = VRF_SYNC_SLV;
              end
            end else begin
              next_slv_state = VRF_WRITE_SLV;
            end
          end
        end else begin
          next_slv_state = VRF_WRITE_SLV; // TODO: check this case?
        end
      end
    end

    // Sync state in case the master gets out of sync due to not received gnt
    VRF_SYNC_SLV: begin
      if (|mst_sync_slv) begin
        next_slv_state = saved_slv_state_q;
      end else begin
        next_slv_state = VRF_SYNC_SLV;
      end
    end

    //---------------
    // Multicycle Ops
    //---------------

    VRF_MC_READ2_SLV: begin
      // TODO: handle sync with master and last iteration
      if (num_iterations_q == 1 || (num_iterations_q == 2 && !even_iteration)) begin
        // Nothing else to read
        if (mst_sync_slv[0]) begin // TODO: check, I don't like having a single mst_sync_slv sample signal
          next_slv_state = VRF_MC_IDLE_SLV;
        end else begin
          next_slv_state = VRF_SYNC_SLV;
        end
      end
      if (sel_operation_i[1]) begin
        if (instr_data_gnt_i) begin
          if (mst_sync_slv[0]) begin // TODO: check, I don't like having a single mst_sync_slv sample signal
            next_slv_state = VRF_MC_IDLE_SLV;
          end else begin
            next_slv_state = VRF_SYNC_SLV;
          end
        end else begin
          next_slv_state = VRF_MC_READ2_SLV;
        end
      end else begin
        next_slv_state = VRF_IDLE_SLV; // Error
      end
    end

    VRF_MC_IDLE_SLV: begin
      if (last_iteration_q) begin
        next_slv_state = VRF_IDLE_SLV;
      end else begin
        // TODO: handle sync with master and last iteration
        if (mst_sync_slv[3]) begin
          next_slv_state = VRF_MC_READ1_SLV;
        end else begin
          next_slv_state = VRF_SYNC_SLV;
        end
      end
    end
    
    VRF_MC_READ1_SLV: begin
      // TODO: handle sync with master and last iteration
      if (!last_iteration_q) begin
        if (num_iterations_q == 1 || (num_iterations_q == 2 && !even_iteration)) begin
          if (mst_sync_slv[1]) begin
            // move to write without reading anything
              next_slv_state = VRF_MC_WRITE_SLV;
            end else begin
              next_slv_state = VRF_SYNC_SLV;
            end
        end else begin
          if (instr_data_gnt_i) begin
            if (mst_sync_slv[1]) begin
              next_slv_state = VRF_MC_WRITE_SLV;
            end else begin
              next_slv_state = VRF_SYNC_SLV;
            end
          end else begin
            next_slv_state = VRF_MC_READ1_SLV;
          end
        end
      end else begin
        next_slv_state = VRF_MC_FINISH_SLV;
      end
    end
    
    VRF_MC_WRITE_SLV: begin
      if (last_iteration_q && even_iteration) begin
        next_slv_state = VRF_MC_FINISH_SLV;
      end else begin
        if (instr_data_gnt_i) begin
          // mst is in idle, no sync here
          next_slv_state = VRF_MC_READ2_SLV;
        end else begin
          next_slv_state = VRF_MC_WRITE_SLV;
        end
      end
    end
    
    VRF_MC_FINISH_SLV: begin
      next_slv_state = VRF_IDLE_SLV;
    end

    default: begin
    end

  endcase
end



//---------------
// Internal logic
//---------------
always_comb begin
  rs1_en_slv = 1'b0;
  rs2_en_slv = 1'b0;
  rs3_en_slv = 1'b0;
  rd_en_slv  = 1'b0;
  // Instr interface used for VRF
  instr_data_req_o = 1'b0;
  instr_data_we_o  = 1'b0;
  // Counters increment
  agu_get_rs1_slv = 1'b0;
  agu_get_rs2_slv = 1'b0;
  agu_get_rd_slv = 1'b0;
  agu_incr_slv = 3'b0;
  // Delayed write when no gnt received or not in sync
  write_delayed_slv = 1'b0;
  // Iteration counter decrement
  dec_iterations_slv = 1'b0;
  // Done
  vector_done_slv = 1'b0;
  src_sel_slv = 1'b0;
  src_sel_slv_c = 1'b0;
  // Sync signals with master FSM
  slv_sync_mst_d = 4'b0;
  // Sample signals for sync
  sel_sync_slv = 1'b0;
  sample_sync_slv = '0;
  sample_saved_slv = 1'b0;
  saved_slv_state_d = curr_slv_state; // default saved state is the current one
  use_double_if_o = 1'b1; // default is to use the single interface, some operations can use the double one to be faster

  case(curr_slv_state)
    VRF_IDLE_SLV: begin
      // By default enable the master to go ahead
      // This is useful in case of operations done in single-interface mode (slide, move) with common branches with the double if version
      use_double_if_o = 1'b1;
      slv_sync_mst_d = 4'b1111;
    end
    VRF_START_SLV: begin
      //use_double_if_o = 1'b1;
      sample_sync_slv = 4'hF;
      if (mult_ops_i) begin
        sel_sync_slv = 1'b1; // default is to sample the next state of the master FSM
        instr_data_req_o = 1'b1;
        if (sel_operation_i[0]) begin
          agu_get_rs1_slv = 1'b1;
        //sample_sync_slv[0] = 1'b1; // sample the next state of the master FSM
        end else begin
          agu_get_rs2_slv = 1'b1;
        //sample_sync_slv[1] = 1'b1;
        end
        if (instr_data_gnt_i) begin
          if (sel_operation_i[0]) begin
            agu_incr_slv[0] = 1'b1;
            slv_sync_mst_d[0] = 1'b1;
          end else begin
            agu_incr_slv[1] = 1'b1;
            slv_sync_mst_d[1] = 1'b1;
          end
        end
      end else begin // .vx, slide
        // TODO: actually unsupported (just pasted)
        if (sel_operation_i[0] || sel_operation_i[1]) begin
          instr_data_req_o = 1'b1;
          if (sel_operation_i[0]) agu_get_rs1_slv = 1'b1;
          else agu_get_rs2_slv = 1'b1;
          if (instr_data_gnt_i) begin
            if (sel_operation_i[0]) begin
              agu_incr_slv[0] = 1'b1;
            end else begin
              agu_incr_slv[1] = 1'b1;
            end
            //if (multicycle_op_i) begin // TODO: left unchanged MC
            //  first_mc_write_d = 1'b1;
            //end
          end
        end else if (sel_operation_i[3]) begin
          instr_data_req_o = 1'b1;
          instr_data_we_o = 1'b1;
          agu_get_rd_slv = 1'b1;
          if (instr_data_gnt_i) begin
            agu_incr_slv[2] = 1'b1;
          end
        end
      end
    end
    //-----------
    // Arithmetic
    //-----------
    VRF_INT_READ1_SLV: begin
      sel_sync_slv = 1'b1; // default is to sample the next state of the master FSM
      if (instr_data_rvalid_i && !last_iteration_mst) begin
        if (sel_operation_i[0]) rs1_en_slv = 1;
        else rs2_en_slv = 1;
      end
      if (!first_iteration_q) begin
        // 3 ops operation
        if (sel_operation_i[2]) begin
          src_sel_slv_c = 1'b1; // select input operands
        end else begin
          src_sel_slv = 1'b1; // select input operands
        end
        instr_data_we_o = 1'b1;
        instr_data_req_o = 1'b1;
        if (sel_operation_i[0])
          agu_get_rd_slv = 1'b1;
        else // special case for vmacc.vx, use A counter to avoid overlap
          agu_get_rs1_slv = 1'b1;
        write_delayed_slv = ~(instr_data_gnt_i);// && mst_sync_slv[2]); // TODO: check
        sample_sync_slv[3] = 1'b1;
        if (instr_data_gnt_i) begin
          if (sel_operation_i[0] || (!sel_operation_i[2]) && !(mst_sync_slv[0] || mst_sync_slv[1])) begin
            saved_slv_state_d = VRF_INT_WRITE_SLV;
            //sample_sync_state = 4'hf;
            //sample_sync_slv = 1'b1; // sample the next state of the master
          end else if (sel_operation_i[2] || (!sel_operation_i[0]) && !mst_sync_slv[2]) begin
            saved_slv_state_d = VRF_INT_WRITE_SLV;
          end
          if (sel_operation_i[0])
            agu_incr_slv[2] = 1'b1;
          else
            agu_incr_slv[0] = 1'b1;
          slv_sync_mst_d[3] = 1'b1; // write incs
        end
      end else begin
        // First pass: if the master's sync pulse was missed the next-state logic goes to
        // VRF_SYNC_SLV; record where to resume. Dedicated
        // enable: sample_sync_slv would also resample slv_sync_mst_q. Safety net only:
        // mst_start_hold keeps the slave aligned, so this should not fire.
        if (!((mst_sync_slv[1] && sel_operation_i[0]) || (mst_sync_slv[2] && sel_operation_i[1]))) begin
          saved_slv_state_d = VRF_INT_WRITE_SLV;
          sample_saved_slv  = 1'b1;
        end
      end
    end
    VRF_INT_READ2_SLV: begin
      sel_sync_slv = 1'b1; // default is to sample the next state of the master FSM
      if (instr_data_rvalid_i) begin
        if (sel_operation_i[0]) rs2_en_slv = 1;
        else rs3_en_slv = 1; //todo: check we can still use rs3 here
      end
      if (sel_operation_i[0] && sel_operation_i[2]) begin
        instr_data_req_o = 1'b1;
        agu_get_rd_slv = 1'b1;
        sample_sync_slv[2] = 1'b1;
        if (instr_data_gnt_i) begin
          //agu_incr_slv[2] = 1'b1;
          slv_sync_mst_d[2] = 1'b1;
          if (!mst_sync_slv[0] && !last_iteration_q) begin
            saved_slv_state_d = VRF_INT_READ3_SLV;
            //sample_sync_slv = 4'hf;
          end
        end
      // if next operation is WRITE RD
      end else if (sel_operation_i[3]) begin
        if (sel_operation_i[0] == 1'b0)
          src_sel_slv = 1'b1; // select input operands  
        if (!(last_iteration_q || num_iterations_q == ((!no_offset && even_iteration) ? 0 : 1))) begin
          instr_data_req_o = 1'b1;
          if (sel_operation_i[0]) begin 
            agu_get_rs1_slv = 1'b1;
            sample_sync_slv[0] = 1'b1; // sample the next state of the master FSM
          end else begin 
            agu_get_rs2_slv = 1'b1;
            sample_sync_slv[1] = 1'b1;
          end
          if (instr_data_gnt_i) begin
            if (sel_operation_i[0]) begin
              agu_incr_slv[0] = 1'b1;
              slv_sync_mst_d[0] = 1'b1;
            end else begin
              //sample_sync_slv[1] = 1'b1;
              agu_incr_slv[1] = 1'b1;
              slv_sync_mst_d[1] = 1'b1;
            end
            if (!mst_sync_slv[3]) begin
              saved_slv_state_d = VRF_INT_READ1_SLV;
              //sample_sync_slv = 4'hF; // sample the next state of the master
            end
          end
        end
      end
    end
    VRF_INT_READ3_SLV: begin
      sel_sync_slv = 1'b1; // default is to sample the next state of the master FSM
      if (instr_data_rvalid_i) rs3_en_slv = 1;
      src_sel_slv = 1'b1; // select input operands
      // NEXT STATE SELECTION
      if (sel_operation_i[3]) begin
        if (!last_iteration_q) begin
          instr_data_req_o = 1'b1;
          agu_get_rs1_slv = 1'b1;
          sample_sync_slv[0] = 1'b1; // sample the next state of the master FSM
          if (instr_data_gnt_i) begin
            agu_incr_slv[0] = 1'b1;
            slv_sync_mst_d[0] = 1'b1;
            if (!mst_sync_slv[3]) begin
              saved_slv_state_d = VRF_INT_READ1_SLV;
              //sample_sync_slv = 4'hF; // sample the next state of the master
            end
          end
        end
      end
    end
    VRF_INT_WRITE_SLV: begin
      sel_sync_slv = 1'b1; // default is to sample the next state of the master FSM
      if (last_iteration_q && even_iteration) begin
        vector_done_slv = 1'b1;
      end else if (!last_iteration_q) begin
        if (sel_operation_i[1]) begin
          instr_data_req_o = 1'b1;
          if (sel_operation_i[0]) begin 
            agu_get_rs2_slv = 1'b1;
            sample_sync_slv[1] = 1'b1; // sample the next state of the master FSM
          end else begin
            //agu_get_rd_slv = 1'b1;
            //sample_sync_slv[2] = 1'b1; // sample the next state of the master FSM
            agu_get_rs1_slv = 1'b1;
            sample_sync_slv[2] = 1'b1; // sample the next state
          end
          if (instr_data_gnt_i) begin
            if (sel_operation_i[0]) begin
              agu_incr_slv[1] = 1'b1;
              slv_sync_mst_d[1] = 1'b1;  // get rs2
            end else begin
              //agu_incr_slv[2] = 1'b1;
              agu_incr_slv[0] = 1'b1;
              slv_sync_mst_d[2] = 1'b1;  // get rd
            end// TODO: check if else should be handled
            dec_iterations_slv = 1'b1;
            if ((sel_operation_i[0] && sel_operation_i[2])) begin
              if(!mst_sync_slv[2] && !(num_iterations_q == 1 && even_iteration)) begin
                saved_slv_state_d = VRF_INT_READ2_SLV;
                //sample_sync_slv = 4'hF;
              end
            end else begin
              if (!mst_sync_slv[0] && !(num_iterations_q == 1 && even_iteration)) begin
                saved_slv_state_d = VRF_INT_READ2_SLV;
                //sample_sync_slv = 4'hF;
              end
            end
          end
        end
      end
    end

  // 2-source operands
  // -----------------
  VRF_READ_SLV: begin
    // SAMPLE
    if (instr_data_rvalid_i && !last_iteration_mst) begin
      rs2_en_slv = 1'b1;
    end
    if (!first_iteration_q) begin
      instr_data_we_o  = 1'b1;
      src_sel_slv      = 1'b1; // select input operands
      instr_data_req_o = 1'b1;
      agu_get_rd_slv   = 1'b1;
      write_delayed_slv = ~(instr_data_gnt_i);// && (mst_sync_slv[0] || mst_sync_slv[1])); // TODO: check
      if (instr_data_gnt_i) begin
        if (mst_sync_slv[0] || mst_sync_slv[1] || last_iteration_q
            || (num_iterations_q == (no_offset ? 1 : 0))
            || (even_iteration && num_iterations_q == (no_offset ? 2 : 1))) begin
          // TODO: importante, invece di usare confronti, asserire dei segnali e mettere un registro, quando la condizione uguale si verifica, dovrebbe essere piu semplice logica
          agu_incr_slv[2] = 1'b1;
          slv_sync_mst_d[3] = 1'b1; // write incs
        end else begin
          saved_slv_state_d = VRF_WRITE_SLV;
          sample_sync_slv[3] = 1'b1; // sample the next state
        end
      end
    end
  end
  VRF_WRITE_SLV: begin
    if (last_iteration_q && even_iteration) begin
      vector_done_slv = 1'b1;
    end else begin
      // if next operation is READ
      if (sel_operation_i[0] || sel_operation_i[1]) begin
        if ((num_iterations_q == (no_offset ? 2 : 1) && !even_iteration)
            || num_iterations_q == (no_offset ? 1 : 0) || last_iteration_q) begin // TODO: just changed check
          instr_data_req_o = 1'b0;
          dec_iterations_slv = 1'b1;
          slv_sync_mst_d[0] = 1'b1;
        end else begin 
          instr_data_req_o = 1'b1;
          if (sel_operation_i[0]) begin
            agu_get_rs1_slv = 1'b1;
          end else begin
            agu_get_rs2_slv = 1'b1;
          end
          if (instr_data_gnt_i) begin
            if (!mst_sync_slv[3]) begin // TODO: check on last iterations etc missing
              saved_slv_state_d = VRF_READ_SLV;
              if (sel_operation_i[0]) begin
                sample_sync_slv[0] = 1'b1; // sample the next state of the master FSM
              end else begin
                sample_sync_slv[1] = 1'b1; // sample the next state of the master FSM
              end
            end
            if (sel_operation_i[0]) begin
              agu_incr_slv[0] = 1'b1;
              slv_sync_mst_d[0] = 1'b1;
            end else begin
              agu_incr_slv[1] = 1'b1;
              slv_sync_mst_d[1] = 1'b1;
            end
            dec_iterations_slv = 1'b1;
          end
        end
      // if we don't read vs2 it means we write again
      end else begin // TODO: check this corner case may not work in 2-interface mode
        instr_data_we_o = 1'b1;
        instr_data_req_o = 1'b1;
        agu_get_rd_slv = 1'b1;
        if (instr_data_gnt_i) begin
          agu_incr_slv[2] = 1'b1;
          slv_sync_mst_d[3] = 1'b1; // write incs
          dec_iterations_slv = 1'b1;
        end
      end
    end
  end
  VRF_SYNC_SLV: begin
    sel_sync_slv = 1'b1; // default is to sample the next state of the master FSM, as we save it when we enter in sync
  end

  //---------------
  // Multicycle Ops
  //---------------
  // TODO: multicycle, capire ex_stall a cosa e se serve ancora, e conto iterazioni

  VRF_MC_READ2_SLV: begin
    // Read second operand and sample first
    sel_sync_slv = 1'b1;
    if (first_iteration_q && instr_data_rvalid_i && !last_iteration_mst) begin
      rs1_en_slv = 1;
    end
    instr_data_req_o = 1'b1;
    agu_get_rs2_slv = 1'b1;
    if (instr_data_gnt_i) begin
      agu_incr_slv[1] = 1'b1;
      slv_sync_mst_d[1] = 1'b1; // read incs
      sample_sync_slv[1] = 1'b1; // sample the next state of the master FSM
      if (!mst_sync_slv[0]) begin
        saved_slv_state_d = VRF_MC_IDLE_SLV;
      end
    end

  end

  VRF_MC_IDLE_SLV: begin
    sel_sync_slv = 1'b1;
    if (instr_data_rvalid_i) begin
      rs2_en_slv = 1;
      if (!mst_sync_slv[3]) begin
        saved_slv_state_d = VRF_MC_READ1_SLV;
        sample_sync_slv = '1; // sample the next state of the master FSM
      end
    end
  end

  VRF_MC_READ1_SLV: begin
    sel_sync_slv = 1'b1;
    // Read RS1 of next iteration
    src_sel_slv = 1'b1; // select input operands
    if (num_iterations_q == 1 || (num_iterations_q == 2 && !even_iteration)) begin
      slv_sync_mst_d[0] = 1'b1; // read incs
    end else begin
      instr_data_req_o = 1'b1;
      agu_get_rs1_slv = 1'b1;
      if (instr_data_gnt_i) begin
        agu_incr_slv[0] = 1'b1;
        slv_sync_mst_d[0] = 1'b1; // read incs
        sample_sync_slv[0] = 1'b1; // sample the next state of the master FSM
        if (!mst_sync_slv[1]) begin
          saved_slv_state_d = VRF_MC_WRITE_SLV;
        end
      end
    end
  end

  VRF_MC_WRITE_SLV: begin
    sel_sync_slv = 1'b1;
    src_sel_slv = 1'b1; // select input operands
    //if (last_iteration_q && even_iteration) begin
    //  vector_done_slv = 1'b1;
    //end
    // Write result and sample the RS1 for next iteration
    if (!last_iteration_q && instr_data_rvalid_i) begin
      rs1_en_slv  = 1'b1; // TODO: check, must be different than rs1 currently in use
    end
    instr_data_req_o = 1'b1;
    instr_data_we_o = 1'b1;
    agu_get_rd_slv = 1'b1;
    if (instr_data_gnt_i) begin
      agu_incr_slv[2] = 1'b1;
      slv_sync_mst_d[2] = 1'b1;
      sample_sync_slv[2] = 1'b1; // sample the next state of the master FSM
      dec_iterations_slv = 1'b1;
    end
  end

  VRF_MC_FINISH_SLV: begin
    vector_done_slv = 1'b1;
    //ex_stall_o = 1'b1;
  end


  default: begin
  end

  endcase


end

//-------------
// Sync signals
//-------------

always_ff @(posedge clk_i or negedge rst_ni) begin
  if (!rst_ni) begin
    mst_sync_slv_q <= '0;
    slv_sync_mst_q <= '0;
    saved_mst_state_q <= VRF_IDLE_MST;
    saved_slv_state_q <= VRF_IDLE_SLV;
    slv_done_seen_q <= 1'b0;
  end else begin
    if (curr_mst_state == VRF_START_MST) begin
      // A new instruction must not inherit the previous one's return state.
      // Use ERR_STATE to see if FSM is getting stuck on incorrect MST-SLV sync.
      saved_mst_state_q <= ERR_STATE;
    end else if (sample_sync_mst) begin
      mst_sync_slv_q <= mst_sync_slv_d;
      saved_mst_state_q <= saved_mst_state_d;
    end
    if (curr_mst_state == VRF_START_MST) begin
      slv_done_seen_q <= 1'b0;
    end else if (vector_done_slv) begin
      slv_done_seen_q <= 1'b1;
    end
    if (|sample_sync_slv || sample_saved_slv) begin
      saved_slv_state_q <= saved_slv_state_d;
    end
      for (int i = 0; i < 4; i++) begin
        if (sample_sync_slv[i]) begin
          slv_sync_mst_q[i] <= slv_sync_mst_d[i];
        end
      end
    //if (sample_sync_slv) begin
    //  slv_sync_mst_q <= slv_sync_mst_d; // reset slave sync to allow the master to go ahead
    //  saved_slv_state_q <= saved_slv_state_d;
    //end
  end
end

assign mst_sync_slv = (sel_sync_mst) ? mst_sync_slv_q : mst_sync_slv_d;
assign slv_sync_mst = (sel_sync_slv) ? slv_sync_mst_q : slv_sync_mst_d;


// The operation takes more than one 32-bit beat, i.e. ceil(bytes/4) > 1, i.e. bytes > 4.
assign slv_active = (num_bytes_elements > 'd4);

// The master executes the final beat when the beat count is odd, or whenever the
// slave was never started at all (slides, memory ops, single-beat ops). When the
// slave owns the final beat, EVERY master beat is a whole word, so the partial
// byte-enable must follow the owner of the tail rather than the global
// last_iteration_q flag.
assign mst_owns_tail = ~even_iteration | ~mst_start_slv_q;

// last_iteration_q rises when the counter reaches T.
assign mst_tail_write = (mult_ops_i && sel_operation_i[0] && sel_operation_i[2]) ? last_iteration_mst
                                                                                 : last_iteration_q;

// Parity of the beat count, which decides whether the last beat belongs to the
// master (even index) or the slave (odd index). ~vl_i[0] is only correct for
// SEW=32, where beats == vl.
assign even_iteration = slide_op_i ? ~vl_i[0]
                                   : ~(num_bytes_elements[2] ^ (|num_bytes_elements[1:0]));
//-------------
// Output logic
//-------------
// Iteration count
assign num_bytes_elements = vl_i << sew_i;

// TODO: NOTE vslidedown: no-op as well, which is NOT
// spec compliant (vd[i] = vs2[i+OFFSET] for i+OFFSET < VLMAX, else 0), and is a
// known limitation, like vd[vl-OFFSET..vl-1] staying unwritten when OFFSET < vl.
assign slide_empty = slide_op_i && (slide_offset_i >= num_bytes_elements);

// The slave uses the instruction port, which the instruction-port cve2_dmem_switch gives
// to fetch whenever the prefetch buffer is busy (fetch outstanding or requested). After a
// taken branch into a vector op the prefetch buffer is still refilling while the op starts.
// Starting only once fetch is quiet
// keeps the 1-cycle master/slave skew the handshake relies on. Fetch then stays quiet for
// the whole op: the prefetch FIFO is full and nothing is consumed while the op is in ID.
// The delay is bounded by the outstanding fetches (NUM_REQS = 2).
assign op_uses_slave  = !memory_op_i && slv_active &&
                        (mult_ops_i || (!slide_op_i && !multicycle_op_i && (sel_operation_i[0] || sel_operation_i[1])));
assign mst_start_hold = if_busy_i && op_uses_slave;
always_comb begin
  // Default values
  last_iteration_mst = (even_iteration && mst_start_slv_q) ? last_iteration_q : last_iteration_odd_q;
  last_iteration_d = last_iteration_q; // preserve previous value
  last_iteration_odd_d = last_iteration_odd_q; // preserve previous value
  num_iterations_d = num_iterations_q; // preserve previous value
  offset_d = offset_q; // preserve previous value
  if (curr_mst_state == VRF_IDLE_MST) begin
    // Load the number of iterations at the beginning of the operation (can be used by both FSMs)
    num_iterations_d   = slide_op_i ? num_bytes_elements[31:2] - slide_offset_i[31:2] : num_bytes_elements[31:2];
    last_iteration_d = 1'b0;
    last_iteration_odd_d = 1'b0;
    offset_d = num_bytes_elements[1:0];
  end else begin
    if (num_iterations_q == (no_offset ? 1 : 0)) begin
      last_iteration_d = 1'b1;
      if (dec_iterations_mst || dec_iterations_slv) begin
        num_iterations_d = num_iterations_q - 1;
      end else begin
        num_iterations_d = num_iterations_q;
      end
    // One decrement PAST the last beat. With no_offset the last beat sits at 1
    // and this value is 0; with a partial tail the last beat already sits at 0,
    // so the decrement wraps and the value is all-ones.
    end else if (num_iterations_q == {(PIPE_WIDTH-2){~no_offset}}) begin
      last_iteration_odd_d = 1'b1;
    end else begin
      last_iteration_d = last_iteration_q;
      if (dec_iterations_mst || dec_iterations_slv) begin
        num_iterations_d = num_iterations_q - 1;
      end else begin
        num_iterations_d = num_iterations_q;
      end
    end
  end
end

// AGU control signals
assign agu_incr_o = agu_incr_mst | agu_incr_slv;
assign agu_get_rs1_o = {agu_get_rs1_slv, agu_get_rs1_mst};
assign agu_get_rs2_o = {agu_get_rs2_slv, agu_get_rs2_mst};
assign agu_get_rd_o = {agu_get_rd_slv, agu_get_rd_mst};

// Done signal
assign vector_done_o = vector_done_mst | vector_done_slv; // if mst_start_slv_q && !even_iteration vector_done_slv else vector_done_mst

//-----------
// Signal FFs
//-----------
always_ff @(posedge clk_i or negedge rst_ni) begin
  if (!rst_ni) begin
    first_iteration_q <= 1'b0;
    num_iterations_q <= '0;
    last_iteration_q <= 1'b0;
    last_iteration_odd_q <= 1'b0;
    offset_q <= '0;
    slide_first_write_q <= 1'b0;
    slide_offset_q <= '0;
    mst_start_slv_q <= 1'b0;
    curr_demux_sel <= 1'b0;
  end else begin
    first_iteration_q <= first_iteration_d;
    num_iterations_q <= num_iterations_d;
    last_iteration_q <= last_iteration_d;
    last_iteration_odd_q <= last_iteration_odd_d;
    offset_q <= offset_d;
    slide_first_write_q <= slide_first_write_d;
    curr_demux_sel <= next_demux_sel;
    if (curr_mst_state == VRF_START_MST) mst_start_slv_q <= mst_start_slv;
    if (slide_offset_en) slide_offset_q <= slide_offset_i[1:0];
  end
end

// Load: track the LSU request in flight and whether the delayed write is the last one
always_ff @(posedge clk_i or negedge rst_ni) begin
  if (!rst_ni) begin
    lsu_pending_q  <= 1'b0;
    load_tail_wr_q <= 1'b0;
  end else begin
    if (curr_mst_state == VRF_IDLE_MST) lsu_pending_q <= 1'b0;
    else if (lsu_req_o)                 lsu_pending_q <= 1'b1;
    else if (lsu_done_i)                lsu_pending_q <= 1'b0;
    if (curr_mst_state == VRF_LOAD) load_tail_wr_q <= load_tail;
  end
end

//----------
// State FFs
//----------

always_ff @(posedge clk_i or negedge rst_ni) begin
  if (!rst_ni) begin
    curr_mst_state <= VRF_IDLE_MST;
    curr_slv_state <= VRF_IDLE_SLV;
  end else begin
    curr_mst_state <= next_mst_state;
    curr_slv_state <= next_slv_state;
  end
end





  //////////////////
  // BE selector  //
  //////////////////

  // depending on vl we could need to access only a section of the 32 bit word
  always_comb begin
    no_offset = 1'b0;
    no_offset_first = 1'b0;
    // BE for last write
    // For slide down operations it depends both on vl and the offset
    if (slide_op_i && !is_slide_up_i) begin
      no_offset = 1'b1;
      slide_offset_be = 4'b1111;
      case ({offset_q, slide_offset_q})
        4'b0111, 4'b0010: begin
          offset_be = 4'b0011;
        end
        4'b0001, 4'b0110, 4'b1011: begin
          offset_be = 4'b0111;
        end
        4'b0000, 4'b0101, 4'b1010, 4'b1111: begin
          offset_be = 4'b1111;
        end
        4'b0011: begin
          offset_be = 4'b0001;
        end
        4'b1000, 4'b1101: begin
          offset_be = 4'b0011;
          no_offset = 1'b0;
        end
        4'b1100: begin
          offset_be = 4'b0111;
          no_offset = 1'b0;
        end
        4'b0100, 4'b1001, 4'b1110: begin
          offset_be = 4'b0001;
          no_offset = 1'b0;
        end
        default: offset_be = 4'b0000;
      endcase
    end
    // For other operations it depends only on vl
    else begin
      case (offset_q)
        2'b00: begin
          offset_be = 4'b1111;
          no_offset = 1'b1;
        end
        2'b01: offset_be = 4'b0001;
        2'b10: offset_be = 4'b0011;
        2'b11: offset_be = 4'b0111;
        default: offset_be = 4'b0000;
      endcase
    end
    // In slide up operation the first read can be a different be
    case (slide_offset_q)
      2'b00: begin
        slide_offset_be = 4'b1111;
        no_offset_first = 1'b1;
      end
      2'b01: slide_offset_be = 4'b1110;
      2'b10: slide_offset_be = 4'b1100;
      2'b11: slide_offset_be = 4'b1000;
      default: slide_offset_be = 4'b0000;
    endcase
  end

  always_comb begin
    if (sel_slide_be) begin
      if (last_iteration_q) begin
        data_be = slide_offset_be & offset_be;
      end
      else data_be = slide_offset_be;
    end
    else if (mst_tail_write && mst_owns_tail) begin
      data_be = offset_be;
    end
    else begin
      data_be = 4'b1111;
    end
  end
  // While a load/store access waits for its grant the byte enable must not change
  assign data_be_o = (memory_op_i && curr_state_delay != 2'b00) ? buffer_be_q : data_be;

  ////////////////////////////////
  // Slide instructions support //
  ////////////////////////////////
  
  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      slide_buffer_q <= '0;
    end else begin
      if (slide_buffer_en) slide_buffer_q <= slide_buffer_d;
    end
  end
  // Since the sampled offset bits are already shifted of SEW bits we can directly use them
  always_comb begin
    slide_buffer_d = slide_buffer_q;
    case (slide_offset_q)
      2'b01: begin
        slide_rdata = is_slide_up_i ? {data_rdata_i[23:0], slide_buffer_q[7:0]} : {data_rdata_i[7:0], slide_buffer_q[23:0]};
        slide_buffer_d = is_slide_up_i ? {16'h0, data_rdata_i[31:24]} : data_rdata_i[31:8];
      end
      2'b10: begin
        slide_rdata = {data_rdata_i[15:0], slide_buffer_q[15:0]};
        slide_buffer_d = {8'h00, data_rdata_i[31:16]};
      end
      2'b11: begin
        slide_rdata = is_slide_up_i ? {data_rdata_i[7:0], slide_buffer_q[23:0]} : {data_rdata_i[23:0], slide_buffer_q[7:0]};
        slide_buffer_d = is_slide_up_i ? data_rdata_i[31:8] : {16'h0, data_rdata_i[31:24]};
      end
      default: slide_rdata = data_rdata_i;
    endcase
  end

 ///////////////////////////
  // Delayed grant support //
  ///////////////////////////

  // Delayed write buffer
  assign buffer_d = read_delayed ? ((mux_sel) ? rs3_q_1 : rs3_q) : rd_q;
  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      curr_state_delay <= 2'b00;
      buffer_q <= '0;
      buffer_be_q <= '0;
    end else begin
      curr_state_delay <= next_state_delay;
      if (buffer_en) begin
        buffer_q    <= buffer_d;
        buffer_be_q <= data_be;
      end
    end
  end
  always_comb begin
    rd_buf_en = 1'b0;
    buffer_en = 1'b0;
    rdata_mux = 1'b0;
    wdata_mux = memory_op_i ? 2'b01 : 2'b00;
    case (curr_state_delay)
      // Initial state: we wait for delay
      2'b00: begin
        if (write_delayed || read_delayed) begin
          if (!memory_op_i) rd_buf_en = 1'b1;          // if it's not a memory operation we need to sample input signal
          else buffer_en = 1'b1;                       // if it's a memory operations we : load - sample the already sampled result, store - sample the operand to avoid changing LSU inputs while we wait
          next_state_delay = write_delayed ? 2'b01 : 2'b10;
        end else begin
          next_state_delay = 2'b00;
        end
      end
      // State with write delayed
      2'b01: begin
        wdata_mux = memory_op_i ? 2'b10 : 2'b01;
        if (write_delayed) begin
          next_state_delay = 2'b01;
        end else begin
          next_state_delay = 2'b00;
        end
      end
      // State with read delayed until the grant, however long it takes
      2'b10: begin
        rdata_mux = 1'b1;
        if (read_delayed || !lsu_gnt_i) begin
          next_state_delay = 2'b10;
        end else begin
          next_state_delay = 2'b00;
        end
      end
      default: begin
        next_state_delay = 2'b00;
      end
    endcase
  end


  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      lsu_offset_q <= '0;
    end else begin
      if (curr_mst_state == VRF_START_MST) begin
        lsu_offset_q <= lsu_offset_i;
      end
    end
  end

  // Operands and result registers - master
  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      rs1_q <= '0;
      rs2_q <= '0;
      rs3_q <= '0;
      rs3_q_1 <= '0;
      rd_q  <= '0;
    end else begin
      if (rs1_en_mst && curr_mc_demux_sel == 0) begin
        rs1_q <= rs1_d;
      end else if (rs1_en_mst && curr_mc_demux_sel == 1) begin
        rs1_q_1 <= rs1_d;
      end
      if (rs2_en_mst && curr_mc_demux_sel == 0) begin
        rs2_q <= rs2_d;
      end else if (rs2_en_mst && curr_mc_demux_sel == 1) begin
        rs2_q_1 <= rs2_d;
      end
      if (rs3_en_mst && curr_demux_sel == 0) begin
          rs3_q <= rs3_d;
      end
      if (rs3_en_mst && curr_demux_sel == 1) begin
        rs3_q_1 <= rs3_d_1;
      end
      if (rd_en_mst || rd_buf_en) 
        if (curr_mc_rd_demux_sel == 0) begin
          rd_q <= rd_d;
        end else begin
          rd_q_1 <= rd_d;
        end
    end
  end
  always_comb begin
    rs1_d   = data_rdata_i;
    rs2_d   = slide_op_i ? slide_rdata : data_rdata_i;
    rs3_d   = data_rdata_i;
    rs3_d_1 = data_rdata_i;
    rd_d    = wdata_i;
  end
  
  // Operands and result registers - slave
  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      rs1_q_slv <= '0;
      rs2_q_slv <= '0;
      rs3_q_slv <= '0;
      //rs3_q_1_slv <= '0;
      rd_q_slv  <= '0;
    end else begin
      if (rs1_en_slv) begin
        rs1_q_slv <= rs1_d_slv;
      end
      if (rs2_en_slv && curr_mc_demux_sel == 0) begin
        rs2_q_slv <= rs2_d_slv;
      end
      if (rs3_en_slv) begin
          rs3_q_slv <= rs3_d_slv;
      end
      if (rd_en_slv || rd_buf_en) begin
        rd_q_slv <= rd_d;
      end
    end
  end
  always_comb begin
    rs1_d_slv   = instr_data_rdata_i;
    rs2_d_slv   = instr_data_rdata_i;
    rs3_d_slv   = instr_data_rdata_i;
    //rs3_d_1_slv = instr_data_rdata_i;
    //rd_d_slv    = wdata_i;
  end


  // FFs for multicycle
  // ------------------
  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      curr_mc_demux_sel <= 1'b0;
      curr_mc_rd_demux_sel <= 1'b0;
      curr_mc_mux_sel <= 1'b0;
      curr_mc_rd_mux_sel <= 1'b0;
      first_mc_write_q <= 1'b0;
      mc_last_q <= 1'b0;
    end else begin
      curr_mc_demux_sel <= next_mc_demux_sel;
      curr_mc_rd_mux_sel <= next_mc_rd_mux_sel;
      curr_mc_rd_demux_sel <= next_mc_rd_demux_sel;
      curr_mc_mux_sel <= next_mc_mux_sel;
      first_mc_write_q <= first_mc_write_d;
      mc_last_q <= mc_last_d;
    end
  end

  /////////////
  // Outputs //
  /////////////

  assign rdata_a_o = (curr_mc_mux_sel == 0) ? (src_sel_slv ? rs1_q_slv : rs1_q) : rs1_q_1;
  assign rdata_b_o = (curr_mc_mux_sel == 0) ? (src_sel_slv ? rs2_q_slv : rs2_q) : rs2_q_1;
  assign rdata_c_o = rdata_mux ? buffer_q : ((mux_sel) ? rs3_q_1 : (src_sel_slv_c ? rs3_q_slv : rs3_q)); // TODO: not supported for now in 2 ops mode
  // mux for the write data
  always_comb begin
    case (wdata_mux)
      2'b00: data_wdata_o = (!multicycle_op_i) ? wdata_i : ((first_mc_write_q) ? wdata_i : (curr_mc_rd_mux_sel == 0 ? rd_q : rd_q_1));
      2'b01: data_wdata_o = rd_q;
      2'b10: data_wdata_o = buffer_q; // TODO: this should be only for mem ops (check)
      default: data_wdata_o = '0;
    endcase
  end
  
  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      write_delayed_slv_q <= 1'b0;
    end else begin
      write_delayed_slv_q <= write_delayed_slv;
    end
  end


  assign instr_data_wdata_o = (write_delayed_slv_q) ? rd_q_slv : wdata_i;
  // The slave owns the final beat whenever the beat count is even; that beat
  // carries the partial tail when offset_q != 0. No slide or STR support on this
  // interface, so offset_be is the only non-full pattern it can ever need.
  assign instr_data_be_o = (last_iteration_q && !mst_owns_tail) ? offset_be : 4'b1111;

`ifndef SYNTHESIS
  ////////////////////////////////////////
  // Debug monitor: VRF_SYNC_MST / _SLV //
  ////////////////////////////////////////
  // In the nominal flow neither FSM should ever wait in a SYNC state, except for it to be the last state
  // before completion (e.g. MST waiting for the SLV last beat to be processed), so every entry is
  // reported as a warning, with the state it comes from, the state it will return to
  // (as sampled on entry), the other FSM's state and the handshake/grant context; every
  // exit is reported with its dwell time and destination. grep "[VRF-SYNC]" in the
  // simulator output. Simulation only, no effect on the design.
  mst_state_t  dbg_mst_ret;
  slv_state_t  dbg_slv_ret;
  int unsigned dbg_mst_sync_cycles, dbg_slv_sync_cycles;
  int unsigned dbg_mst_sync_entries, dbg_slv_sync_entries;

  // Return state as it will be once the entry edge has sampled it
  assign dbg_mst_ret = sample_sync_mst  ? saved_mst_state_d : saved_mst_state_q;
  assign dbg_slv_ret = (|sample_sync_slv || sample_saved_slv) ? saved_slv_state_d : saved_slv_state_q;

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      dbg_mst_sync_cycles  <= 0;
      dbg_slv_sync_cycles  <= 0;
      dbg_mst_sync_entries <= 0;
      dbg_slv_sync_entries <= 0;
    end else begin
      // Master
      if (curr_mst_state != VRF_SYNC_MST && next_mst_state == VRF_SYNC_MST) begin
        dbg_mst_sync_entries <= dbg_mst_sync_entries + 1;
        $display("[VRF-SYNC] %0t WARNING MST enters VRF_SYNC_MST #%0d from %s, return=%s (sampled=%b) | slv=%s | cnt=%0d first=%b last=%b last_odd=%b | slv_sync_mst=%b mst_sync_slv=%b | d_req=%b d_gnt=%b i_req=%b i_gnt=%b | vl=%0d sew=%0d sel=%b mult=%b mc=%b mem=%b slide=%b",
                 $time, dbg_mst_sync_entries + 1, curr_mst_state.name(), dbg_mst_ret.name(), sample_sync_mst,
                 curr_slv_state.name(), num_iterations_q, first_iteration_q, last_iteration_q, last_iteration_odd_q,
                 slv_sync_mst, mst_sync_slv, data_req_o, data_gnt_i, instr_data_req_o, instr_data_gnt_i,
                 vl_i, sew_i, sel_operation_i, mult_ops_i, multicycle_op_i, memory_op_i, slide_op_i);
      end
      if (curr_mst_state == VRF_SYNC_MST) begin
        dbg_mst_sync_cycles <= dbg_mst_sync_cycles + 1;
        if (next_mst_state != VRF_SYNC_MST) begin
          $display("[VRF-SYNC] %0t MST leaves VRF_SYNC_MST after %0d cycle(s) -> %s | slv=%s slv_sync_mst=%b vector_done_slv=%b slv_done_seen=%b",
                   $time, dbg_mst_sync_cycles + 1, next_mst_state.name(), curr_slv_state.name(),
                   slv_sync_mst, vector_done_slv, slv_done_seen_q);
        end
      end else begin
        dbg_mst_sync_cycles <= 0;
      end
      // Slave
      if (curr_slv_state != VRF_SYNC_SLV && next_slv_state == VRF_SYNC_SLV) begin
        dbg_slv_sync_entries <= dbg_slv_sync_entries + 1;
        $display("[VRF-SYNC] %0t WARNING SLV enters VRF_SYNC_SLV #%0d from %s, return=%s (sampled=%b) | mst=%s | cnt=%0d first=%b last=%b last_odd=%b | mst_sync_slv=%b slv_sync_mst=%b | i_req=%b i_gnt=%b d_req=%b d_gnt=%b | vl=%0d sew=%0d sel=%b mult=%b mc=%b",
                 $time, dbg_slv_sync_entries + 1, curr_slv_state.name(), dbg_slv_ret.name(), (|sample_sync_slv || sample_saved_slv),
                 curr_mst_state.name(), num_iterations_q, first_iteration_q, last_iteration_q, last_iteration_odd_q,
                 mst_sync_slv, slv_sync_mst, instr_data_req_o, instr_data_gnt_i, data_req_o, data_gnt_i,
                 vl_i, sew_i, sel_operation_i, mult_ops_i, multicycle_op_i);
      end
      if (curr_slv_state == VRF_SYNC_SLV) begin
        dbg_slv_sync_cycles <= dbg_slv_sync_cycles + 1;
        if (next_slv_state != VRF_SYNC_SLV) begin
          $display("[VRF-SYNC] %0t SLV leaves VRF_SYNC_SLV after %0d cycle(s) -> %s | mst=%s mst_sync_slv=%b",
                   $time, dbg_slv_sync_cycles + 1, next_slv_state.name(), curr_mst_state.name(), mst_sync_slv);
        end
      end else begin
        dbg_slv_sync_cycles <= 0;
      end
    end
  end
`endif
endmodule
