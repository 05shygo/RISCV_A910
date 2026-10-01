`timescale 1ns / 1ps

// ---------------------------------------------------------------------------
// RTU_iid_cmp — 两个 7 位 iid 的**年龄**比较 (谁更老)。
// 结构照搬 C910 的 ct_rtu_compare_iid.v (74 行), 只改了端口命名。
//
// 语义: iid = {回绕位, 6 位索引}。回绕位相同 ⇒ 索引小的更老;
//       回绕位不同 ⇒ 索引**大**的那个属于上一圈, 更老。
//
// ⚠️⚠️ **这个模块只许给异常收集 (D9) 与中断掩码用, 绝不许接进重定向链。**
//      D12: BEU 的 iid_oldest 是最严门控下的"相等比较" (inst_iid == 退休指针),
//      1~2 级 LUT; 而这里是完整的年龄比较, 约 5 级深 —— 串进重定向链会直接
//      压在 EX→前端 那条 270 条最差路径的主路上 (§4.2 的 P2)。
//      当年 C910 自己也要靠 "move ex1 iid age compare to rf stage" 来躲它。
// ---------------------------------------------------------------------------
module RTU_iid_cmp (
    input  wire [6:0] x_iid0,
    input  wire [6:0] x_iid1,
    output wire       x_iid0_older      // x_iid0 比 x_iid1 老
);

    wire        iid_msb_mismatch;
    wire [5:0]  iid0_larger;
    wire [5:0]  iid1_larger;
    wire        iid0_5_0_larger;
    wire        iid1_5_0_larger;

    assign iid_msb_mismatch = x_iid0[6] ^ x_iid1[6];

    assign iid0_larger[5] =  x_iid0[5] && !x_iid1[5];
    assign iid0_larger[4] =  x_iid0[4] && !x_iid1[4];
    assign iid0_larger[3] =  x_iid0[3] && !x_iid1[3];
    assign iid0_larger[2] =  x_iid0[2] && !x_iid1[2];
    assign iid0_larger[1] =  x_iid0[1] && !x_iid1[1];
    assign iid0_larger[0] =  x_iid0[0] && !x_iid1[0];

    assign iid1_larger[5] = !x_iid0[5] && x_iid1[5];
    assign iid1_larger[4] = !x_iid0[4] && x_iid1[4];
    assign iid1_larger[3] = !x_iid0[3] && x_iid1[3];
    assign iid1_larger[2] = !x_iid0[2] && x_iid1[2];
    assign iid1_larger[1] = !x_iid0[1] && x_iid1[1];
    assign iid1_larger[0] = !x_iid0[0] && x_iid1[0];

    assign iid0_5_0_larger =
         iid0_larger[5]
      || iid0_larger[4] && !iid1_larger[5]
      || iid0_larger[3] && !(|iid1_larger[5:4])
      || iid0_larger[2] && !(|iid1_larger[5:3])
      || iid0_larger[1] && !(|iid1_larger[5:2])
      || iid0_larger[0] && !(|iid1_larger[5:1]);

    assign iid1_5_0_larger =
         iid1_larger[5]
      || iid1_larger[4] && !iid0_larger[5]
      || iid1_larger[3] && !(|iid0_larger[5:4])
      || iid1_larger[2] && !(|iid0_larger[5:3])
      || iid1_larger[1] && !(|iid0_larger[5:2])
      || iid1_larger[0] && !(|iid0_larger[5:1]);

    assign x_iid0_older = !iid_msb_mismatch && iid1_5_0_larger
                       ||  iid_msb_mismatch && iid0_5_0_larger;

endmodule
