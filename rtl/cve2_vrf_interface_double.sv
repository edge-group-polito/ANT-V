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

    // LSU signals
    output logic                  lsu_req_o,          // signals the LSU that it can start the memory operation
    input  logic                  lsu_done_i,

    // CSR signals
    input cve2_pkg::vlmul_e      lmul_i,
    input cve2_pkg::vsew_e       sew_i,
    input logic [31:0]           vl_i

);

import cve2_pkg::*;

// Master FSM is the one who is always 1cc ahead of the slave one, but without losing sync.
// NOTE: laod and store ops are performed using a single interface (MST/data if)
// as we have a single LSU available to which to make the requests (if possible to use both ifs can be done afterwards)
// Optimizing vector LOAD and STR is not a priority right now as they are not so used (arithmetic is the bottleneck on long sequence of vector ops)
// Start from .vv with two operands

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
  VRF_MC_READ1,
  VRF_MC_READ2,
  VRF_MC_WRITE,
  VRF_MC_READ,
  VRF_MC_READ_FIRST,
  VRF_MC_WRITE_SINGLE,
  ERR_STATE
} mst_state_t;

typedef enum logic [4:0] {
  VRF_IDLE_SLV,
  VRF_START_SLV,
  VRF_INT_READ1_SLV,
  VRF_INT_READ2_SLV,
  VRF_INT_READ3_SLV,
  VRF_INT_WRITE_SLV,
  VRF_READ_SLV,
  VRF_WRITE_SLV,
  VRF_SYNC_SLV
} slv_state_t;

mst_state_t curr_mst_state, next_mst_state, saved_mst_state_d, saved_mst_state_q;
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

// Handle misaligned sub-word mem accesses
// TODO: only store are supported and tested for now (to improve with load)
logic curr_demux_sel, next_demux_sel;
logic mux_sel;
logic [1:0] lsu_offset_q;
// Handle multi-cycle operations
logic first_mc_write_d, first_mc_write_q;
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
      if (req_i && vl_i != 0) begin
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
              next_mst_state = VRF_MC_READ1;
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
        if (last_iteration_q || num_iterations_q ==1) begin // TODO: mst e usato veramente?
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
      // TODO: implement
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

    // TODO: add slide and move (in single-port mode)
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
      if (last_iteration_q && even_iteration) begin
        next_mst_state = VRF_SYNC_MST; // wait at least 1cc to resync with slave
      end else if (last_iteration_odd_q && !even_iteration) begin
        next_mst_state = VRF_IDLE_MST;
      end else if (last_iteration_q && slide_op_i) begin
        next_mst_state = VRF_IDLE_MST;
      end else begin
        if (sel_operation_i[0] || sel_operation_i[1]) begin
          if (num_iterations_q == (no_offset ? 1 : 0) || (num_iterations_q == 2 && !slide_op_i && even_iteration)) begin
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
      if(|slv_sync_mst || vector_done_slv) begin
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
      if(lsu_done_i || last_iteration_q) begin
        if (!first_iteration_q) begin
          if (data_gnt_i) begin
            if (!last_iteration_q) begin
              next_mst_state = VRF_LOAD_WRITE;
            end else begin
              next_mst_state = VRF_IDLE_MST;
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
        next_mst_state = VRF_LOAD_WRITE;
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
      end else if (last_iteration_q) begin
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
      // TODO: left unchanged (slide an mem ops)
      // Data memory if - load the start address
      if (memory_op_i) data_load_addr_o = 1'b1;
      // TODO: maybe can use less than 32 bits (optimize it, some are fixed, avoid ovf)
      // memory ops and slide do not have access to the double interface, as
      // first use the LSU that is share, second could not respect the interleaved bank policy
      slide_offset_en = slide_op_i;
    end
  end
  VRF_START_MST: begin
    first_iteration_d = 1'b1;
    // TODO: left unchanged
    slide_first_write_d = 1'b1;
    next_mc_demux_sel = 1'b0;
    next_mc_mux_sel = 1'b0;
    next_mc_rd_mux_sel = 1'b0;
    next_mc_rd_demux_sel = 1'b0;
    first_mc_write_d = 1'b0;
    if (!memory_op_i) begin   // ARITH Op
      if (mult_ops_i) begin
        data_req_o = 1'b1;
        mst_start_slv = 1'b1; // Tell slave FSM it can start in the next cycle
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
            // TODO: left unchanged MC
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
            if (!slide_op_i) begin
              // Start slave FSM on .vx except on slide and move
              mst_start_slv = 1'b1;
            end
            if (sel_operation_i[0]) begin
              agu_incr_mst[0] = 1'b1;
              mst_sync_slv_d[0] = 1'b1;
            end else begin
              agu_incr_mst[1] = 1'b1;
              mst_sync_slv_d[1] = 1'b1;
            end
            if (multicycle_op_i) begin // TODO: left unchanged MC
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
      write_delayed = ~data_gnt_i; // TODO: check
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
      if (!last_iteration_q && num_iterations_q != 1) begin
        data_req_o = 1'b1;
        if (sel_operation_i[0]) agu_get_rs1_mst = 1'b1;
        else agu_get_rs2_mst = 1'b1;
        if (data_gnt_i) begin
          // Remove flag for first iteration ahead enough that it has been correctly processed by
          // slave FSM and now by VRF_INT_READ2_MST needing it
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
      end
    end

  end
  VRF_INT_READ3_MST: begin
    // TODO: check, left unchanged for now
    if (data_rvalid_i) rs3_en_mst = 1'b1;
    // NEXT STATE SELECTION
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
      end
    end
  end

  //// TO FIX TODO
  // vmacc.vx has a big problem with the handling of rd pointers
  // Need to handle correctly when the increment is done.
  // Rispetto alla vmacc.vv il problema e che rd ha bisogno di essere incrementato
  // in WR e mentre lo slave sta facendo RD1, quindi tutti e due accedono allo stesso valore,
  // ma slv dovrebbe vedere il vecchio
  // Soluzione easy: aggiungere 1 cc di idle tra rd1 e wr solo per vmacc.vx per poter usare lo stesso counter
  // dovrebbe comunque essere meglio che singola interfaccia
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
        mst_sync_slv_d[3] = 1'b1; // write incs
      if (!(slv_sync_mst[0] || slv_sync_mst[1] || last_iteration_mst)) begin
          saved_mst_state_d = VRF_WRITE_MST;
          sample_sync_mst = 1'b1;
        end
      end
    end
  end
  VRF_WRITE_MST: begin
    if (last_iteration_mst && !even_iteration) begin
      vector_done_mst = 1'b1;
    end else if (last_iteration_mst && (even_iteration || slide_op_i)) begin
      vector_done_mst = 1'b0; // Do nothing, last iteration is for the slave
      saved_mst_state_d = VRF_IDLE_MST;
      sample_sync_mst = 1'b1;
    end else begin
      // if next operation is READ
      if (sel_operation_i[0] || sel_operation_i[1]) begin
        if (num_iterations_q == (no_offset ? 1 : 0) || (num_iterations_q == 2 && !slide_op_i && even_iteration)) begin
          data_req_o = 1'b0;
          dec_iterations_mst = 1'b1;
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
      end else begin // TODO: check this corner case may not work in 2-interface mode
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
    if (lsu_done_i || last_iteration_q) begin
      if (!first_iteration_q) begin
        data_we_o = 1'b1;
        data_req_o = 1'b1;
        agu_get_rd_mst = 1'b1;
        write_delayed = ~data_gnt_i; // TODO: check
        if (data_gnt_i) begin
          agu_incr_mst[2] = 1'b1;
          if (last_iteration_q) begin
            vector_done_mst = 1'b1;
          end
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
    if (data_gnt_i) begin
      agu_incr_mst[2] = 1'b1;
    end
  end
  VRF_LOAD_WRITE: begin
    //if (last_iteration_q) begin
    //  vector_done_mst = 1'b1;
    //end else begin
      // Request to LSU only if not last iteration
      // Iterations are decremented by the main logic
      dec_iterations_mst = 1'b1;
      lsu_req_o = 1'b1;
    //end
  end
  VRF_STORE_READ: begin
    if (data_rvalid_i) rs3_en_mst = 1'b1;
    if (data_rvalid_i || last_iteration_q) begin
      vector_done_mst = last_iteration_q; // if it is the last iteration we are done, else we need to go through the LSU
      //TODO: check
      if (!first_iteration_q) begin
        lsu_req_o = 1'b1;
        if (lsu_offset_q != 2'b00) begin
          mux_sel = ~curr_demux_sel; // TODO: check
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
          next_demux_sel = ~curr_demux_sel; // TODO: check
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
  default: begin
  end


endcase
end

// TODO:
// handle last_iteration (should work as it is for 2 interface ops)


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
          //next_slv_state = VRF_MC_READ1;
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
        if (instr_data_gnt_i) begin // TODO: left unchanged for now
          if (mst_sync_slv[0] || (last_iteration_q) ) begin
            next_slv_state = VRF_INT_READ3_SLV;
          end else begin
            next_slv_state = VRF_SYNC_SLV;
          end
        end else begin
          next_slv_state = VRF_INT_READ2_SLV;
        end
      end else if (sel_operation_i[3]) begin
        if (last_iteration_q || num_iterations_q == 1) begin //n_it_q for odd
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
        next_slv_state = VRF_IDLE_SLV; // TODO: change
      end else begin
        if (sel_operation_i[1]) begin
          if (instr_data_gnt_i) begin
            if (sel_operation_i[2]) begin
            // vmacc.vv, vmacc.vx
              if ((mst_sync_slv[2]|| mst_sync_slv[1]) || (num_iterations_q == 1 && even_iteration)) begin // TODO: CAMBIATO ORA (occhio alla mac vv), usare sel_operation_i[0]
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
    // TODO: add slide and move (in single-port mode)
    VRF_READ_SLV: begin
      if (!first_iteration_q) begin
        if (instr_data_gnt_i) begin
          if (mst_sync_slv[0] || mst_sync_slv[1] || (num_iterations_q <= 1 && !even_iteration) || (num_iterations_q <= 2 && even_iteration)) begin
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
          if (num_iterations_q == 1 || (num_iterations_q == 2 && !even_iteration)) begin
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
  saved_slv_state_d = curr_slv_state; // default saved state is the current one
  use_double_if_o = 1'b1; // default is to use the single interface, some operations can use the double one to be faster

  case(curr_slv_state)
    VRF_IDLE_SLV: begin
      // By default enable the master to go ahead
      // This is useful in case of operations done in single-interface mode (slide, move) with common branches with the double if version
      use_double_if_o = 1'b1;
      slv_sync_mst_d = 4'b111;
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
          //if (multicycle_op_i) begin
          //  // TODO: left unchanged MC (actually usupported, just pasted)
          //  //first_mc_write_d = 1'b1;
          //  //next_mc_demux_sel = 1'b0;
          //end
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
      end 
      //else begin
      //  first_iteration_d = 1'b0;
      //end
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
          // TODO: sample correct signal for slv sync
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
        if (!(last_iteration_q || num_iterations_q == 1)) begin
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
    VRF_INT_WRITE_SLV: begin // TODO: handle last iteration with no read in case of odd num iterations
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
  // TODO: nei due stati VRF_READ_SLV e VRF_WRITE_SLV non ho messo i check su mst_sync
  // e sample e salvo stato. Perche? Perchè non serve o perchè mi sono scordata? Capire (perchè nei mst c'è)
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
        if (mst_sync_slv[0] || mst_sync_slv[1] || (num_iterations_q <= 1 && !even_iteration) || (num_iterations_q <= 2 && even_iteration)) begin
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
        if ((num_iterations_q == 2 && !even_iteration) || num_iterations_q == 1 || last_iteration_q) begin // TODO: just changed check
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
            // TODO: add here the sync state case
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
  end else begin
    if (sample_sync_mst) begin
      mst_sync_slv_q <= mst_sync_slv_d;
      saved_mst_state_q <= saved_mst_state_d;
    end
    if (|sample_sync_slv) begin
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


assign even_iteration = ~vl_i[0];
//-------------
// Output logic
//-------------
// Iteration count
assign num_bytes_elements = vl_i << sew_i;
always_comb begin
  // Default values
  // TODO: handle last iteration in the case of even and odd
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
    end else if (num_iterations_q == 0) begin
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
        data_be_o = slide_offset_be & offset_be;
      end
      else data_be_o = slide_offset_be;
    end
    else if (last_iteration_q) begin
      data_be_o = offset_be;
    end
    else begin
      data_be_o = 4'b1111;
    end
  end

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
    end else begin
      curr_state_delay <= next_state_delay;
      if (buffer_en) buffer_q <= buffer_d;
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
      // State with read delayed
      2'b10: begin
        rdata_mux = 1'b1;
        if (read_delayed) begin
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
    end else begin
      curr_mc_demux_sel <= next_mc_demux_sel;
      curr_mc_rd_mux_sel <= next_mc_rd_mux_sel;
      curr_mc_rd_demux_sel <= next_mc_rd_demux_sel;
      curr_mc_mux_sel <= next_mc_mux_sel;
      first_mc_write_q <= first_mc_write_d;
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
  assign instr_data_be_o = 4'b1111; // No slide or STR support on this interface
endmodule
