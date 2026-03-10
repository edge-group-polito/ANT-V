// Copyright 2024 Politecnico di Torino.
// Copyright and related rights are licensed under the Solderpad Hardware
// License, Version 2.0 (the "License"); you may not use this file except in
// compliance with the License. You may obtain a copy of the License at
// http://solderpad.org/licenses/SHL-2.0. Unless required by applicable law
// or agreed to in writing, software, hardware and materials distributed under
// this License is distributed on an "AS IS" BASIS, WITHOUT WARRANTIES OR
// CONDITIONS OF ANY KIND, either express or implied. See the License for the
// specific language governing permissions and limitations under the License.
//
// File: cve2_dmem_switch.sv


module cve2_dmem_switch #(
) (
	input  logic                  clk_i,
	input  logic                  rst_ni,
	// Data memory interface
	output logic                  data_req_o,
  input  logic                  data_gnt_i,
  input  logic                  data_rvalid_i,
  output logic                  data_we_o,
  output logic [3:0]            data_be_o,
  output logic [31:0]           data_addr_o,
  output logic [31:0]           data_wdata_o,
  input  logic [31:0]           data_rdata_i,
  input  logic                  data_err_i,
	// VRF signals
	input  logic                  vrf_data_req_i,
  output logic                  vrf_data_gnt_o,
  output logic                  vrf_data_rvalid_o,
  input  logic                  vrf_data_we_i,
  input  logic [3:0]            vrf_data_be_i,
  input  logic [31:0]           vrf_data_addr_i,
  input  logic [31:0]           vrf_data_wdata_i,
  output logic [31:0]           vrf_data_rdata_o,
  output logic                  vrf_data_err_o,
  // LSU signals
	input  logic                  lsu_data_req_i,
  output logic                  lsu_data_gnt_o,
  output logic                  lsu_data_rvalid_o,
  input  logic                  lsu_data_we_i,
  input  logic [3:0]            lsu_data_be_i,
  input  logic [31:0]           lsu_data_addr_i,
  input  logic [31:0]           lsu_data_wdata_i,
  output logic [31:0]           lsu_data_rdata_o,
  output logic                  lsu_data_err_o,
  input  logic                  lsu_resp_valid_i,
  input  logic                  lsu_busy_i,
  // Control signals
  input  logic                  vector_op_i,
  input  logic                  vector_mem_op_i
);

typedef enum logic {LSU, VRF} dmem_op_t;
dmem_op_t prev_op_q, prev_op_d;
logic vrf_has_mem;

// signal is high when the VRF has control of the data memory, it can happen when the following conditions are met:
// - it's a vector operation
// - the VRF didn't request a memory operation
// - the LSU is not busy with a previously requested memory operation (needed especially for misaligned accesses)
assign vrf_has_mem = vector_op_i && (!vector_mem_op_i && !lsu_busy_i);

////////////
// Inputs //
////////////

assign vrf_data_rdata_o = data_rdata_i;
assign lsu_data_rdata_o = data_rdata_i;

// first cycle responses, the grant is given (or not) immediately
assign vrf_data_gnt_o = vrf_has_mem && data_gnt_i;
assign lsu_data_gnt_o = !vrf_has_mem && data_gnt_i;

// second cycle responses, responses given on the next cycle, FSM needed to keep track of the previous unit
always_ff @(posedge clk_i or negedge rst_ni) begin
  if (!rst_ni) begin
    prev_op_q <= VRF;
  end else begin
    if (!vector_op_i) begin
      prev_op_q <= VRF;
    end else begin
      prev_op_q <= prev_op_d;
    end
  end
end
always_comb begin
  case (prev_op_q)
    VRF: prev_op_d = dmem_op_t'(vrf_has_mem);
    LSU: prev_op_d = (vector_op_i && lsu_resp_valid_i) ? dmem_op_t'(vrf_has_mem) : LSU;
  endcase
end

// different conditions to ensure that when there is no vector operation the data memory is controlled by the LSU
assign vrf_data_rvalid_o = ((prev_op_q == VRF) && vector_op_i) && data_rvalid_i;
assign lsu_data_rvalid_o = ((prev_op_q == LSU) || !vector_op_i) && data_rvalid_i;
assign vrf_data_err_o = ((prev_op_q == VRF) && vector_op_i) && data_err_i;
assign lsu_data_err_o = ((prev_op_q == LSU) || !vector_op_i) && data_err_i;

////////////////////////
// Output multiplexer //
////////////////////////

assign data_req_o = vrf_has_mem ? vrf_data_req_i : lsu_data_req_i;
assign data_we_o = vrf_has_mem ? vrf_data_we_i : lsu_data_we_i;
assign data_be_o = vrf_has_mem ? vrf_data_be_i : lsu_data_be_i;
assign data_addr_o = vrf_has_mem ? vrf_data_addr_i : lsu_data_addr_i;
assign data_wdata_o = vrf_has_mem ? vrf_data_wdata_i : lsu_data_wdata_i;

endmodule
