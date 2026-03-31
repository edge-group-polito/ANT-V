// Copyright and related rights are licensed under the Solderpad Hardware
// License, Version 2.0 (the "License"); you may not use this file except in
// compliance with the License. You may obtain a copy of the License at
// http://solderpad.org/licenses/SHL-2.0. Unless required by applicable law
// or agreed to in writing, software, hardware and materials distributed under
// this License is distributed on an "AS IS" BASIS, WITHOUT WARRANTIES OR
// CONDITIONS OF ANY KIND, either express or implied. See the License for the
// specific language governing permissions and limitations under the License.
//
// File: cve2_cs_registers_vec.sv


module cve2_cs_registers_vec 
  import cve2_pkg::*;
#(
  parameter int unsigned VLEN = cve2_pkg::VLENb
) (
  input logic                clk_i,
  input logic                rst_ni,

  // From ID stage
  input logic               vl_keep_i,
  input logic               vcfg_write_i,
  input logic [4:0]         rf_raddr_a_i,
  input logic [4:0]         rf_raddr_b_i,
  input logic [3:0]         vrf_sel_operation_i,
  input logic               vrf_memory_op_i,
  input logic [2:0]         vmem_ops_eew_i,
  // From WB stage
  input logic [4:0]         rf_waddr_wb_i,

  input logic [31:0]        alu_operand_a_ex_i,
  input logic [31:0]        alu_operand_b_ex_i,

  // TO VRF if
  output vsew_e              vrf_vsew_o,
  output vlmul_e             vrf_vlmul_o,
  output logic [31:0]        vrf_vl_o, // current vl value vl_d

  // Output regs
  output vsew_e              vsew_o,
  output vlmul_e             vlmul_o,
  output logic [31:0]        vl_o,
  output logic               illegal_vec_csr_insn_o

);


  // ALU operand a - AVL
  // ALU operand b - new vtype setting
  logic [31:0] new_vlmax;
  logic avl_lt, avl_lt_double;

  // Regs signals
  vsew_e    vsew_q, vsew_d;
  vlmul_e   vlmul_q, vlmul_d;
  logic [1:0] vma_vta_q, vma_vta_d;
  logic [31:0] vl_q, vl_d;
  logic vill_q, vill_d;

  logic illegal_vrf_addr_lmul;
  logic illegal_mem_eew;

  // signal combining exceptions related to vector CSR
  assign illegal_vec_csr_insn_o = illegal_mem_eew | illegal_vrf_addr_lmul;

  always_comb begin
    vsew_d     = vsew_q;
    vlmul_d    = vlmul_q;
    vma_vta_d  = vma_vta_q;
    vl_d       = vl_q;
    // vstart_d   = vstart_q;
    // vxrm_d     = vxrm_q;
    // vxsat_d    = vxsat_q;
    vill_d     = vill_q;
    new_vlmax  = '0;
    avl_lt     = 1'b0;
    avl_lt_double = 1'b0;
    if (vcfg_write_i==1'b1) begin
      // sample the values coming from the instruction
      vsew_d     = vsew_e'(alu_operand_b_ex_i[5:3]);
      vlmul_d    = vlmul_e'(alu_operand_b_ex_i[2:0]);
      vma_vta_d  = alu_operand_b_ex_i[7:6];
      // VLMAX = ( (VLEN/8) /SEW)*LMUL
      new_vlmax = ($signed(vlmul_d)>0) ? ((VLEN>>3)>>$unsigned(vsew_d)) << $signed(vlmul_d) :
                                         ((VLEN>>3)>>$unsigned(vsew_d)) >> -$signed(vlmul_d);
      // configuration is valid unless later found otherwise
      vill_d     = 1'b0;
      // compute the VLMAX for the new configuration
      avl_lt = (alu_operand_a_ex_i <= new_vlmax);
      avl_lt_double = (alu_operand_a_ex_i <= (new_vlmax << 1));

      if (vl_keep_i==1'b1) begin    // check validity if the goal is to mantain vl value
        vl_d = vl_q;
        unique case ({vsew_q, vsew_d})
          // vsew not changed
          {VSEW_32, VSEW_32},
          {VSEW_16, VSEW_16},
          {VSEW_8, VSEW_8} : begin
            if (vlmul_q != vlmul_d) begin
              vill_d = 1'b1;
            end
          end
          // vsew multiplied by two
          {VSEW_16, VSEW_32},
          {VSEW_8, VSEW_16} : begin
            unique case ({vlmul_q, vlmul_d})
              {VLMUL_F8, VLMUL_F4},
              {VLMUL_F4, VLMUL_F2},
              {VLMUL_F2, VLMUL_1},
              {VLMUL_1, VLMUL_2},
              {VLMUL_2, VLMUL_4},
              {VLMUL_4, VLMUL_8}: ;
              default: vill_d = 1'b1;
            endcase
          end
          // vsew multiplied by four
          {VSEW_8, VSEW_32} : begin
            unique case ({vlmul_q, vlmul_d})
              {VLMUL_F8, VLMUL_F2},
              {VLMUL_F4, VLMUL_1},
              {VLMUL_F2, VLMUL_2},
              {VLMUL_1, VLMUL_4},
              {VLMUL_2, VLMUL_8}: ;
              default: vill_d = 1'b1;
            endcase
          end
          // vsew divided by two
          {VSEW_32, VSEW_16},
          {VSEW_16, VSEW_8} : begin
            unique case ({vlmul_q, vlmul_d})
              {VLMUL_F4, VLMUL_F8},
              {VLMUL_F2, VLMUL_F4},
              {VLMUL_1, VLMUL_F2},
              {VLMUL_2, VLMUL_1},
              {VLMUL_4, VLMUL_2},
              {VLMUL_8, VLMUL_4}: ;
              default: vill_d = 1'b1;
            endcase
          end
          // vsew divided by four
          {VSEW_32, VSEW_8} : begin
            unique case ({vlmul_q, vlmul_d})
              {VLMUL_F2, VLMUL_F8},
              {VLMUL_1, VLMUL_F4},
              {VLMUL_2, VLMUL_F2},
              {VLMUL_4, VLMUL_1},
              {VLMUL_8, VLMUL_2}: ;
              default: vill_d = 1'b1;
            endcase
          end
          default: vill_d = 1'b1;
        endcase

      // if we don't have the constraint on vl we just need to verify that SEW and LMUL are valid in itself and not one of the few illegal combinations
      // with fractional LMUL
      end else begin
        unique case ({vsew_d, vlmul_d})
          {VSEW_8, VLMUL_F4},
          {VSEW_8, VLMUL_F2},
          {VSEW_8, VLMUL_1},
          {VSEW_8, VLMUL_2},
          {VSEW_8, VLMUL_4},
          {VSEW_8, VLMUL_8},
          {VSEW_16, VLMUL_F2},
          {VSEW_16, VLMUL_1},
          {VSEW_16, VLMUL_2},
          {VSEW_16, VLMUL_4},
          {VSEW_16, VLMUL_8},
          {VSEW_32, VLMUL_1},
          {VSEW_32, VLMUL_2},
          {VSEW_32, VLMUL_4},
          {VSEW_32, VLMUL_8}: begin
            vl_d = avl_lt ? alu_operand_a_ex_i : (avl_lt_double ?
                            (alu_operand_a_ex_i >> 1) + (alu_operand_a_ex_i & 1) : new_vlmax);
          end
          default: begin
            vill_d = 1'b1;
            vl_d = '0;
          end
        endcase
      end
    end
  end

  // Register address validity check wrt LMUL setting
  logic [2:0] vlmul_mask;
  logic [4:0] masked_vs1, masked_vs2, masked_vd;
  always_comb begin
    case (vlmul_q)
      VLMUL_1, VLMUL_F2, VLMUL_F4, VLMUL_F8: vlmul_mask = 3'b111;
      VLMUL_2: vlmul_mask = 3'b110;
      VLMUL_4: vlmul_mask = 3'b100;
      VLMUL_8: vlmul_mask = 3'b000;
      default: vlmul_mask = 3'b111;
    endcase
  end
  assign masked_vs1 = rf_raddr_a_i & {2'b11, vlmul_mask};
  assign masked_vs2 = rf_raddr_b_i & {2'b11, vlmul_mask};
  assign masked_vd  = rf_waddr_wb_i & {2'b11, vlmul_mask};
  assign illegal_vrf_addr_lmul = ((masked_vs1 != rf_raddr_a_i) & vrf_sel_operation_i[0]) |
                                 ((masked_vs2 != rf_raddr_b_i) & vrf_sel_operation_i[1]) |
                                 ((masked_vd  != rf_waddr_wb_i) & (vrf_sel_operation_i[2] | vrf_sel_operation_i[3]));

  vsew_e mem_eew;
  vlmul_e mem_lmul;

  // Logic for EEW/EMUL for vector memory operations
  always_comb begin
    mem_eew = VSEW_32;
    mem_lmul = VLMUL_1;
    illegal_mem_eew = 1'b0;
    if (vrf_memory_op_i) begin
      unique case (vmem_ops_eew_i)
        3'b000: begin
          mem_eew = VSEW_8;
          unique case (vsew_q)
            VSEW_8: mem_lmul = vlmul_q;
            VSEW_16: mem_lmul = vlmul_e'($signed(vlmul_q)-1);
            VSEW_32: mem_lmul = vlmul_e'($signed(vlmul_q)-2);
            default: begin
              illegal_mem_eew = 1'b1;
            end
          endcase
        end
        3'b101: begin
          mem_eew = VSEW_16;
          unique case (vsew_q)
            VSEW_8: mem_lmul = vlmul_e'($signed(vlmul_q)+1);
            VSEW_16: mem_lmul = vlmul_q;
            VSEW_32: mem_lmul = vlmul_e'($signed(vlmul_q)-1);
            default: begin
              illegal_mem_eew = 1'b1;
            end
          endcase
        end
        3'b110: begin
          mem_eew = VSEW_32;
          unique case (vsew_q)
            VSEW_8: mem_lmul = vlmul_e'($signed(vlmul_q)+2);
            VSEW_16: mem_lmul = vlmul_e'($signed(vlmul_q)+1);
            VSEW_32: mem_lmul = vlmul_q;
            default: begin
              illegal_mem_eew = 1'b1;
            end
          endcase
        end
        default: begin
          illegal_mem_eew = 1'b1;
        end
      endcase
      unique case ({mem_eew, mem_lmul})
        {VSEW_8, VLMUL_F4},
        {VSEW_8, VLMUL_F2},
        {VSEW_8, VLMUL_1},
        {VSEW_8, VLMUL_2},
        {VSEW_8, VLMUL_4},
        {VSEW_8, VLMUL_8},
        {VSEW_16, VLMUL_F2},
        {VSEW_16, VLMUL_1},
        {VSEW_16, VLMUL_2},
        {VSEW_16, VLMUL_4},
        {VSEW_16, VLMUL_8},
        {VSEW_32, VLMUL_1},
        {VSEW_32, VLMUL_2},
        {VSEW_32, VLMUL_4},
        {VSEW_32, VLMUL_8}: ;
        default: begin
          // raise illegal instruction exception
        end
      endcase
    end
  end

  // Multiplexers for VRF EEW/EMUL
  assign vrf_vsew_o = vrf_memory_op_i ? mem_eew : vsew_q;
  assign vrf_vlmul_o = vrf_memory_op_i ? mem_lmul : vlmul_q;


// Vector extension CSRs
  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      vsew_q     <= VSEW_32;
      vlmul_q    <= VLMUL_1;
      vma_vta_q  <= '0;
      vl_q       <= '0; 
      // vstart_q   <= '0;
      // vxrm_q     <= '0;
      // vxsat_q    <= '0;
      vill_q     <= '0;
    end else begin
      vsew_q     <= vsew_d;
      vlmul_q    <= vlmul_d;
      vma_vta_q  <= vma_vta_d;
      vl_q       <= vl_d;
      // vstart_q   <= vstart_d;
      // vxrm_q     <= vxrm_d;
      // vxsat_q    <= vxsat_d;
      vill_q     <= vill_d;
    end
  end


// Assign outputs
  assign vsew_o   = vsew_q;
  assign vlmul_o  = vlmul_q;
  assign vl_o     = vl_q;
  assign vrf_vl_o = vl_d;


endmodule
