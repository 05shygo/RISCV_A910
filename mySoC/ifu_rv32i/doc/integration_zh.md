# 预测子系统集成约定

**IF阶段接入更新（2026-09-21）**：已新增IFCTRL/IFDP及唯一阵列授权连接层。正式流水的PC坐标、主BTB早期输出、L0接受事件及分域恢复约定见 [if_stage_zh.md](if_stage_zh.md)。本文件中 `bp_top` 的单一 `if_pc` 接线是原独立预测器验证边界，正式流水须区分PCGEN查询地址与已寄存IF地址。

## 1. 层次和地址

`rv32_ifu_bp_top` 接入五个预测器，但不是 Excel 中的完整 IFU 顶层。I-Cache/BIU/MMU/IDU 数据包等不在此层；不能把 `bp_init_done` 当作整个 IFU 的 `ifu_cp0_init_done`。

所有顶层 `*_pc`、`*_target` 均为 32 位物理字节地址。PC 起点低两位必须为 0。BHT 叶模块保留 C910 的半字坐标 `P=PC[31:1]`，由连接层唯一转换：

| 叶模块输入 | 顶层来源 |
|---|---|
| `ipdp_bht_vpc[30:0]` | `ip_pc[31:1]` |
| `iu_ifu_cur_pc[30:0]` | 外部同名字节 PC 的 `[31:1]` |
| `pcgen_bht_ifpc[6:0]` | `if_pc[7:1]` |
| `pcgen_bht_pcindex[9:0]` | 默认独立验证模式使用 `if_pc[13:4]`；STAGED_BHT=1 使用 `if_query_pc[13:4]` |
| `ibctrl_ind_btb_path[7:0]` | `ib_pred_target[11:4]` |

RTU `retireN_chk_idx[7:0]` 来自真实后继字节 PC[11:4]，不是 BHT `chk_idx[24:0]` 的低八位。RAS 叶模块也已经使用完整字节地址；`ibdp_ras_push_pc` 和 `rtu_ifu_retire0_inc_pc` 应为对应源 PC+4，不能再右移。

## 2. IF/IP BHT 时序

保留原提前读阵列、IF→IP 数据锁存、IP 同块多条件分支处理与 LBUF 路径的阶段控制：

- `pcgen_bht_seq_read/chgflw` 发起 selection 查表；`if_pc` 同拍有效。
- `ifctrl_bht_pipedown` 是 IF→IP 实际推进；`ipctrl_bht_vld` 表示 IP 有效上下文。
- `ipctrl_bht_more_br` 为当前块剩余条件分支的重用/继续处理控制；原 H0 专用条件已删除。
- `ipctrl_bht_con_br_vld` 只在当前条件分支预测被接受时有效，`con_br_taken` 为这次方向。阻塞、重发不得重复发脉冲。
- LBUF active 时以 `lbuf_bht_con_br_vld/taken` 追加历史，普通 IP 不再追加同一事件。仅保留 LBUF 接口，不包含循环缓冲实现。

`bht_pred` 与 `bht_chk_idx` 从原输出的两组方向结果、selection 及 onehot 选择生成，快照格式仍为 `{counter_lsb, selector[1:0], GHR_before[21:0]}`。后续 IP/IB 必须原子锁存它们与源 PC，再绑定到 PCFIFO token。输出不是独立 valid/ready 通道，不能在流水状态不匹配时采样。

`local_recover_vld/ghr` 是新增内部修复口，值必须是局部校正后保留前缀的精确历史。优先级：RTU flush > 已使能的 IU 恢复 > local repair > LBUF > IP。它同时修复 VGHR、提前读 hash、offset 和后继恢复标记。`frontend_cancel` 仅阻止本拍前端新事件，本身不提供历史回滚值；撤销已追加历史必须同时提供修复快照。

## 3. 主 BTB 与 L0

主 BTB 布局：row=PC[12:4]、slot=PC[3:2]、tag=PC[31:13]。两个 bank 各有 512×40 Tag RAM、512×68 Data RAM，每 bank 包含两个 word 槽。逻辑总容量为 2048 个目标槽。

新增 `btb_if_vld/pc/hit/target/way_hint` 为E0同步SRAM读取后、E1旧结果寄存前的旁接输出，供IFDP在E1与Cache数据同拍锁存。下面旧的 `btb_result_vld` 接口保持不变；不能把它作为上述早期口使用。

`btb_lookup_vld && btb_lookup_ready` 在边沿 E0 接受查询，E0 完成同步 SRAM 读；E1 后 `btb_result_vld` 输出一拍，四槽结果已锁存，只有入口及其之后的槽可 hit。结果 payload 保持到下一次结果，但 valid 不是等待消费的 ready/valid 通道：IF/IP 必须保证能捕获它。

`btb_update_vld && btb_update_ready` 接受更新。内部一项缓冲于下一拍写 SRAM；有缓冲写时读端暂停，避免单端口冲突。读出锁存与同拍新更新/缓冲写相撞时，匹配源块、槽的最新目标旁路优先。连续写可能连续阻挡读，完整 ADDRGEN 控制应仲裁，不承诺任意读写负载都无损满速。

L0 为组合查询、同步更新的 16 项 CAM。一个块中选择入口之后最早的 taken 候选；return 项还必须有可用旧 RAS 栈顶。更新来自经过真实译码/目标校验的 IB/ADDRGEN 事件，不能把早期猜测未经验证再写回。定向失效 mask 与 hit_index 对应，同拍优先于更新；全失效和 cancel 优先于查询结果。连接层不负责保存 L0 来源索引，IF/IP 必须随块携带以便后期定向失效。

## 4. IND / RAS

IND 项为 `{valid, privilege[1:0], target_byte[31:0]}`，表深 256。保留四段路径与 GHR 低八位 hash、按 retire0→1→2 追加退休路径、retire0 误预测目标训练。

`ipdp_ind_btb_jmp_detect` 发起读；SRAM 读边沿之后还需一个输出锁存边沿。`ind_result_vld` 表示完成一笔读，`ind_target_valid` 进一步判断项 valid、上下文和四字节对齐。输出需由 IB 捕获；恢复/取消/维护会杀掉在途读有效位。`ibctrl_ind_btb_check_vld` 只在 JAL/JALR 前缀实际接受后推进路径，必须配合相同实例的 `ib_pred_target`；不能把单纯查表当作路径接受。

RAS `ibctrl_ras_pcall_vld/preturn_vld` 是已接纳的提示，允许同时有效。`ras_l0_btb_pc` 提供操作前栈顶；`ras_top_valid` 是该旧栈顶真实可用标志。协程目标选择使用这一对信号。原 `ras_ipdp_pc` 保留“较老 IB call 旁路到年轻 IP”的含义，不应用它替代协程旧栈顶。

正常 TOP 容量 12，溢出丢最老项；RTU 备份维护六项已提交有效后缀。恢复包括同拍有效 retire0 的 push/pop，失效未经备份证明的 TOP 条目。该保守规则避免把错误路径覆盖内容重新发布为有效预测。超过备份的深层返回可缺失，应回退其他预测器/执行校验。

`iu_ifu_mispred_stall` 由后端负责跟踪恢复边界。为 1 时，连接层阻止推测 RAS 操作、间接读/路径推进，屏蔽相关预测结果；退休更新继续。IB 控制必须据此阻塞依赖这些状态的 call/return/JALR，不能只看到输出无效便绕过等待。有效源退休或被更老恢复替代后，后端解除等待。这里没有新增 ROB/token 生命周期管理。

## 5. 训练、退休和取消

与 Excel 同名的 40 个信号经过方向/位宽自动核对。其余信号是内部阶段接口，完整列表见 `ports.json`。

BJU `bht_check_vld` 是执行校验，不是提交。IU 在外部完成 token/ROB 活动身份过滤、年龄仲裁和每实例一次反馈；本层没有 PCFIFO，因此不能自行证明收到的 token 仍有效。条件恢复时 `chgflw` 与 check 必须属于同一个源。

RTU 三路 `condbr/jmp` 和 retire0 特殊事件都由对应 `retireN_vld` 限定；有效退休前缀及特殊事件只能 retire0 的规则由后端保证。本层不凭 PC 推断动态身份。RTU flush 的 VGHR/path/RAS 恢复包含同拍已提交的较老事件，符合 P15。

BHT 四项训练缓冲满时沿用有损性能训练策略，不增加 ready。`bht_train_drop` 是一次被丢训练的脉冲，`bht_train_drop_count` 为饱和 32 位计数器，BHT 失效时清零。训练丢弃不应阻止 IU 恢复或 RTUGHR 追加。

## 6. 初始化与维护

复位后连接层主动启动全部预测状态初始化；BHT 1024 行、BTB 512 行、IND 256 行扫描完成后才给出 `bp_init_done`。不用 Data RAM 全清，但 Tag/valid 及必需的计数器已初始化。

`bp_maint_vld/ready` 为**内部预测器维护子请求**；mask[4:0] 对应 Excel pred_mask 的 L0/BTB/BHT/IND/RAS 五位。完整 IFU 维护器负责处理 op、PC、总线排空、IPB/LBUF/SFP 及对外完成。

维护接受时屏蔽新前端事件并按提交边界恢复推测历史/路径；随后只失效 mask 所选状态，完成后发一次 `bp_maint_done`。零 mask 可仅执行提交边界恢复。无 BHT mask 时保留其提交历史和性能表；有 BHT mask 时清零历史并初始化计数器。模式开关仅在停取/维护窗口修改。

## 7. 完整流水接入（v0.2）

完整 IFU 已接入四 word 入口/截尾、多条件分支分段、快照保持、L0 校正、两路 PCFIFO/超带宽分段、IBUF 旁路/合并和故障交付，见 [pipeline_zh.md](pipeline_zh.md)。IU token 回收和 ROB 动态身份仍属后端。局部改向不能简单拉高全局 RTU flush；本版在源包分配前完成校正，保留较老 IBUF/RAS/path，不提供任意局部 RAS/path 检查点。

`STAGED_BHT` 默认 0 保持预测器独立测试行为，正式顶层设为 1：新增 `if_query_pc` 区分请求索引和IF返回偏移；新增 `ib_query_ghr[7:0]` 为IB间接查询提供源关联历史。局部 GHR 修复不再整体屏蔽较老 IB 训练/RAS/path 接受；年轻 IP 由顶层单独取消。BHT 的 pipedown 还包含已接受条件分支且存在后缀时的同块 repipe。LBUF 经普通 IP 路径每轮重新生成预测/历史，独立专用 LBUF BHT 事件端口在该顶层接0，避免重复更新。

顶层调试入口和接受 HAD PCLOAD 会请求提交边界恢复；普通局部 IB 校正仅走 local_recover。维护时仍通过内部 maint_fire 恢复，IU 提前恢复后仍遵循规定退休点的 RAS/IND 互锁。
