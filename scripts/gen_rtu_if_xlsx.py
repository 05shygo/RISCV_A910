#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
生成 doc/rtu_接口对照表.xlsx (手写 xlsx: zip + XML, 本机没有 openpyxl/pandas)。

三张表:
  1. RTU↔IDU   2. RTU↔LSU   3. 汇总
⚠️ 只整理 **RTU 的两条边**。IDU↔LSU（发射口 idu_lsu_*）不在这张表里 —— 那是别人的事。
分类口径 (列 "分类"):
  已有·直接接   两侧端口都在, 位宽/相位都对得上 -> 接线即可
  已有·需适配   两侧都在, 但位宽/布局/极性/语义有差 -> 适配层解决
  需新增        有一侧压根没有这个口 -> 必须改 RTL (列里注明改哪一侧)
  暂无对应      一侧有、另一侧不需要 (或我们的实现不走这条路) -> 记录, 不接线

用法: python3 scripts/gen_rtu_if_xlsx.py
输出: doc/rtu_接口对照表.xlsx + .csv (CSV 供 git 里看差异; Excel 用 xlsx)
"""
import csv
import os
import zipfile

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
DOC = os.path.join(ROOT, "doc")
BASE = "rtu_接口对照表"

HDR = ["分类", "方向", "RTU 端口", "宽", "对方端口", "宽", "说明 / 契约"]

# ============================== 表 1: RTU ↔ IDU ==============================
IDU = [
    ("## 分配握手 (§6.0)", None),
    ("已有·需适配", "IDU→RTU", "ren_preg_req[1:0]", "2",
     "idu_rtu_ir_preg0/1/2_alloc_vld", "3×1",
     "IDU 发三路独立请求 vld；适配层数个数编成\"程序序前缀\"2 位。⚠️ 语义是"
     "\"请求 = 当拍取走\"(门房, 2026-10-07)"),
    ("已有·需适配", "(适配层)", "ren_preg_req_lreg0/1/2[4:0]", "3×5",
     "—（填常量）", "—",
     "IDU 没有\"请求者的 dst lreg\"输出；适配层填**非零常量**即可（IDU 的请求本身已排除 x0）"),
    ("已有·需适配", "RTU→IDU", "rtu_preg_alloc0/1/2[6:0]", "3×7",
     "rtu_idu_alloc_preg0/1/2", "3×6",
     "位宽 7→6：PREG=64 档下最高位恒 0 ⇒ 切 [5:0] 即可"),
    ("已有·直接接", "RTU→IDU", "rtu_preg_alloc_vld0/1/2", "3×1",
     "rtu_idu_alloc_preg0/1/2_vld", "3×1",
     "同拍许可；为 0 时 IDU 必须停 IR 级（组合环已于 2026-10-07 断掉）"),
    ("暂无对应", "RTU→(IDU)", "rtu_preg_free_cnt[1:0]", "2", "—", "—",
     "IDU 不用它（按逐路 vld 自己停）；留作观察口"),

    ("## iid 回执 与 停派遣", None),
    ("已有·直接接", "RTU→IDU", "rtu_disp_iid0/1/2[6:0]", "3×7",
     "rtu_idu_rob_inst0/1/2_iid", "3×7",
     "位宽/相位完全对齐（两边都是\"create 指针寄存器 + 组合\"）"),
    ("需新增", "RTU→IDU", "rtu_disp_vld0/1/2", "3×1", "—（无此输入口）", "—",
     "IDU 没有\"派遣被接受\"的口；有 disp_stall 保证不越界即可。要用就得给 IDU 加口"),
    ("已有·直接接", "RTU→IDU", "rtu_disp_stall", "1", "rtu_idu_rob_full", "1",
     "两边都是\"只依赖寄存器\"的停派遣（C910 的 rob_full 也是寄存器）"),

    ("## 派遣记录（13 根/路 × 3 路 = 39 根）—— 全部是 IDU 侧新增", None),
    ("需新增", "IDU→RTU", "disp*_vld", "3×1", "—（缺，内部有）", "—",
     "IDU 内部在 IS 派发级（ctrl_is_dis_inst*_vld），没往外引"),
    ("需新增", "IDU→RTU", "disp*_pc[31:0]", "3×32", "—（缺，内部有）", "—",
     "IDU 内部有（IFU 97 位包的 [63:32]）。⚠️ C910 也不送 pc（它靠 IU 里的 pcfifo）"),
    ("需新增", "IDU→RTU", "disp*_chk[24:0]", "3×25", "—（完全没有）", "—",
     "**IDU 完全没有这条路**：ifu2 的 chk 是独立旁路、不在 97 位包里 ⇒ 加输入口 + "
     "随指令锁到派遣点"),
    ("需新增", "IDU→RTU", "disp*_dst_lreg[4:0]", "3×5", "—（缺，内部有）", "—",
     "内部有 id_decd 的 dst_reg；A6d：不写寄存器时必须给 0"),
    ("需新增", "IDU→RTU", "disp*_rf_we", "3×1", "—（缺，内部有）", "—",
     "内部有 dst_vld；A6b：要与写回级同源（difftest 连 ena 都比）"),
    ("需新增", "IDU→RTU", "disp*_dst_preg[6:0]", "3×7", "—（缺，内部有）", "—",
     "内部有 ir_inst*_dst_preg（就是它从 RTU 拿到的号，6 位）"),
    ("需新增", "IDU→RTU", "disp*_old_preg[6:0]", "3×7", "—（缺，内部有）", "—",
     "内部有 RAT 读口 rt_dp_inst*_rel_preg"),
    ("需新增", "IDU→RTU", "disp*_src1_preg[6:0]", "3×7", "—（缺，内部有）", "—",
     "内部有 rt_dp_inst*_src1_data；**只有 CSR 指令有意义**"),
    ("需新增", "IDU→RTU", "disp*_csr_addr / _op / _imm", "12/3/5", "—（缺，内部有）", "—",
     "内部有（译码）；A6c：csr_op 要 **funct3 原样**（001/010/011 与 101/110/111）"),
    ("需新增", "IDU→RTU", "disp*_flags[6:0]", "3×7", "—（缺，内部有）", "—",
     "内部散在 inst_type[4:0] / ir_decd；要按 RTU_FLG_* 打包"
     "{is_jalr,is_jal,is_mret,is_csr,intmask,is_store,is_branch}"),
    ("需新增", "IDU→RTU", "disp*_sq_id[2:0]", "3×3", "—（缺，内部有类似的）", "—",
     "IDU 内部有 SDIQ 条目号，但那是**发射级**发给 LSU 的；RTU 要的是**派遣当拍**的槽号"),
    ("约束（非端口）", "IDU 侧", "—", "—", "—", "—",
     "A7：**一拍最多一条 CSR**（RTU 的 CSR 是单槽）；组内第二条要连同后面的指令截到下一拍"),

    ("## 冲刷 与 映射恢复", None),
    ("已有·直接接", "RTU→IDU", "rtu_ren_flush (+ rtu_backend_flush)", "1",
     "rtu_yy_xx_flush", "1",
     "两边都是 T+1 那拍。⚠️ **别接 rtu_core_redirect**（T 拍，早一拍）"),
    ("暂无对应", "RTU→(IDU)", "rtu_ren_recover_vld", "1", "—", "—",
     "IDU 的写使能就是 flush 本身（同拍组合写 RAT），没有单独的 vld 口 ⇒ 可省"),
    ("已有·需适配", "RTU→IDU", "rtu_ren_recover_map[223:0]", "224",
     "rtu_idu_rt_recover_preg[191:0]", "192",
     "两边都是\"32 个 lreg 的架构映射\"，但**布局不同**（32×7 vs 32×6 每槽切位）"
     " ⇒ 适配层逐槽重排，不是切低位"),
    ("暂无对应", "IDU→(RTU)", "—", "—", "idu_rtu_pst_preg_dealloc_mask[63:0]", "64",
     "RTU 侧没有对应输入：释放的所有权在 RTU（退休时按 old != dst）⇒ 可丢弃"
     "（先确认 IDU 不靠它做内部记账）"),
    ("需新增", "(适配层)", "复位极性", "—", "cpurst_b 低有效", "—",
     "IDU 是 cpurst_b 低有效异步 / RTU 是 cpu_rst 高有效 ⇒ 适配层反相"),

    ("## 先决条件（不是端口，但接之前必须先修）", None),
    ("约束（非端口）", "IDU 内部", "—", "—", "—", "—",
     "⚠️ 交付的 IDU 里 **RAT 表项没接时钟**（ct_idu_dep_reg_src2_entry 的 preg 挂在 "
     "write_clk 上，全目录无驱动；例化也没连 forever_cpuclk）⇒ 改名表一个字写不进去。"
     "这是接它之前必须先修的先决条件"),
]

# ============================== 表 2: RTU ↔ LSU ==============================
LSU = [
    ("## 完成回报（LSU → RTU）：走 §6.1 的完成口 5/6", None),
    ("已有·直接接", "LSU→RTU", "cmplt_vld5 / cmplt_iid5[6:0]", "1 / 7",
     "lsu_rtu_wb_pipe3_cmplt / _iid", "1 / 7",
     "口 5 = **LSU 读**（load 完成）。位宽/相位都对齐"),
    ("已有·直接接", "LSU→RTU", "cmplt_vld6 / cmplt_iid6[6:0]", "1 / 7",
     "lsu_rtu_wb_pipe4_cmplt / _iid", "1 / 7",
     "口 6 = **LSU 写**（store 完成）。D1.3 把这两路分开正是为它"),
    ("暂无对应", "LSU→(RTU)", "—", "—",
     "lsu_rtu_wb_pipe3_wb_preg_expand[95:0]", "96",
     "C910 的一热 preg 展开；我们是**按 iid 寻址**的（表项只存回绕位）⇒ 不用"),
    ("暂无对应", "LSU→(RTU)", "—", "—", "lsu_rtu_wb_pipe3_wb_preg_vld", "1",
     "同上：RTU 不需要\"写哪个 preg\"，它按 iid 找表项"),
    ("已有·需适配", "LSU→RTU", "lsu_replay_vld / lsu_replay_iid[6:0]", "1 / 7",
     "lsu_rtu_wb_pipe4_flush  +  lsu_rtu_wb_pipe4_spec_fail", "1 + 1",
     "store 投机写失败 ⇒ 要重放。**RTU 侧已加**（2026-10-08）：两个输入口 + ROB 表项的 "
     "`RTU_E_REPLAY` 位 + 第 5 类冲刷源 `RTU_FS_REPLAY`。适配层把 LSU 那两根**或**起来"
     "（对我们这条路径是同一个动作），iid 原样送。⚠️ 它跟完成**同拍**报 ⇒ RTU 里有一条"
     "同拍命中路径（否则那条 store 会在同一个边沿就退休、把内存写提交掉）"),

    ("## 提交 / 冲刷（RTU → LSU）", None),
    ("已有·直接接", "RTU→LSU", "rtu_backend_flush", "1", "rtu_yy_xx_flush", "1",
     "都是 T+1 单拍脉冲"),
    ("已有·直接接", "RTU→LSU", "rtu_yy_xx_commit0/1/2  +  _iid", "3 + 21",
     "rtu_yy_xx_commit0/1/2  +  _iid", "3 + 21",
     "**RTU 侧已加**（2026-10-08，照 C910 `ct_rtu_rob_rt.v:2723-2731`）：退休窗口 3 条 iid 广播 + "
     "**真的提交了**的脉冲（陷阱那条不发、被中断 squash 的不发）。两边都是寄存器输出、"
     "**成对锁存** —— 消费方必须同一个边沿成对采样"),
    ("已有·直接接", "RTU→LSU", "rtu_lsu_async_flush", "1",
     "rtu_lsu_async_flush", "1",
     "**RTU 侧已加**（2026-10-08），当前**恒 0**：C910 里它是**调试请求**的异步冲刷"
     "（`ct_rtu_retire.v:2005` 的 `async_flush = dbgreq_ack_jdbreq`），本核没有 debug 模块。"
     "LSU 拿它清 WMB/SQ（lsu_sq.sv:527、lsu_wmb_ce.sv:62）；将来接 debug 时接到这里即可"),
    ("暂无对应", "RTU→(LSU)", "rtu_store_vld0/1/2", "3×1", "—", "—",
     "我们 RTU §6.2 的 store 提交口；LSU 侧没有对应输入 ⇒ 若走\"iid 广播\"那套就不需要它"),
    ("暂无对应", "RTU→(LSU)", "rtu_store_sq_id0/1/2[2:0]", "3×3", "—", "—",
     "同上"),
    ("需新增", "LSU→RTU", "sq_rdy0/1/2  (RTU 已声明)", "3×1",
     "—（LSU 侧要产生）", "—",
     "【改 LSU 侧：产生这三根】RTU §6.1 已有这三个输入（\"这条 store 的数据就绪了吗\"），现在 mycpu.v 恒接 1"),
    ("需新增", "LSU→RTU", "sq_stall  (RTU 已声明)", "1",
     "—（LSU 侧要产生）", "—",
     "【改 LSU 侧：产生这一根】存储队列满/下游忙 ⇒ 压退休宽度；现在恒接 0"),

    ("## 约束（不是线，但接之前要知道）", None),
    ("约束（非端口）", "RTU→LSU", "(rtu_yy_xx_commit*_iid)", "7",
     "(LSU 内部表项里存的 iid)", "7",
     "⚠️ 广播出去的 iid 必须与 LSU 表项里存的**是同一个号**（那个号追到源头就是 RTU 在"
     "派遣那拍发的 `rtu_disp_iid*`）⇒ **不许在适配层重编码、也不许偏一拍**，"
     "否则\"段不匹配\"的后果是静默的：store 永远等不到提交、或提前提交"),
]

# ============================== 表 3: 汇总 ==============================
def counts(rows):
    d = {}
    for r in rows:
        if len(r) == 2:
            continue
        d[r[0]] = d.get(r[0], 0) + 1
    return d

ci, cl = counts(IDU), counts(LSU)
SUMMARY = [
    ["分类口径", "含义", "RTU↔IDU", "RTU↔LSU"],
    ["（\"改哪一侧\"写在最后一列开头；分类列只用四种规范值，便于筛选/计数）", "", "", ""],
    ["已有·直接接", "两侧端口都在，位宽/相位对得上 ⇒ 接线即可",
     str(ci.get("已有·直接接", 0)), str(cl.get("已有·直接接", 0))],
    ["已有·需适配", "两侧都在，但位宽/布局/极性/语义有差 ⇒ 适配层解决",
     str(ci.get("已有·需适配", 0)), str(cl.get("已有·需适配", 0))],
    ["需新增", "有一侧压根没有这个口 ⇒ 必须改 RTL（改哪一侧写在说明列开头）。⚠️ 这里计的是**条目/端口组**数，不是引脚数（派遣记录那 13 条 = 39 根引脚）",
     str(ci.get("需新增", 0)), str(cl.get("需新增", 0))],
    ["暂无对应", "一侧有、另一侧不需要（或我们的实现不走这条路）⇒ 记录，不接线",
     str(ci.get("暂无对应", 0)), str(cl.get("暂无对应", 0))],
    ["约束（非端口）", "写 RTL / 接线时要满足的硬约定，不是一根线",
     str(ci.get("约束（非端口）", 0)), str(cl.get("约束（非端口）", 0))],
    ["", "", "", ""],
    ["三条结论", "① RTU↔IDU 的\"新增\"全在 IDU 侧（派遣记录 39 根），且 `pc`/`chk` "
     "连 C910 都没有，是真·新增；RTU 侧一根端口都不用加", "", ""],
    ["", "② RTU↔LSU 的四项 RTU 侧改动**已于 2026-10-08 落地**（commit 广播口 / async_flush 占位 / "
     "store 重放输入 + 第 5 类冲刷源），剩 LSU 侧的 `sq_rdy*`/`sq_stall` 两根要它产生", "", ""],
    ["", "③ 两个交付物都带了\"我们没有的口\"：IDU 的 `dealloc_mask`、LSU 的 "
     "`preg_expand` —— 它们都是 C910 那套**按 preg 广播**的残留，而我们按 iid 寻址 ⇒ "
     "统一归到\"暂无对应\"，不接线", "", ""],
    ["", "", "", ""],
    ["引用", "详细论证：doc/idu_rtu_接口待办.txt（IDU 侧）、doc/rtu_plan_zh.md §6"
     "（契约）、doc/rtu_preg_size_config_zh.md（位数配置）", "", ""],
]


# ============================== xlsx 生成 ==============================
def esc(s):
    return (str(s).replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;"))


def col_letter(n):
    s = ""
    while n > 0:
        n, r = divmod(n - 1, 26)
        s = chr(65 + r) + s
    return s


def sheet_xml(title, hdr, rows):
    """一行一个 <row>; 首行表头 (style=1), 分节行 (style=2), 其余 (style=0)"""
    out = ['<?xml version="1.0" encoding="UTF-8" standalone="yes"?>',
           '<worksheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main">',
           '<sheetViews><sheetView workbookViewId="0">'
           '<pane ySplit="1" topLeftCell="A2" activePane="bottomLeft" state="frozen"/>'
           '</sheetView></sheetViews>',
           '<sheetFormatPr defaultRowHeight="15"/>']
    widths = {"RTU 端口": 34, "对方端口": 34, "说明 / 契约": 88, "分类": 22,
              "方向": 12, "宽": 9, "含义": 52}
    out.append("<cols>")
    for i, h in enumerate(hdr, start=1):
        out.append('<col min="%d" max="%d" width="%d" customWidth="1"/>'
                   % (i, i, widths.get(h, 14)))
    out.append("</cols><sheetData>")
    allrows = [hdr] + [[("" if c is None else c) for c in r] for r in rows]
    for ri, row in enumerate(allrows, start=1):
        style = 1 if ri == 1 else (2 if (len(row) == 2 and row[1] is None) else 0)
        cells = []
        for ci_, v in enumerate(row):
            if ri > 1 and len(row) == 2 and v is None:
                continue
            cells.append('<c r="%s%d" t="inlineStr" s="%d"><is><t xml:space="preserve">%s</t></is></c>'
                         % (col_letter(ci_ + 1), ri, style, esc(v)))
        out.append('<row r="%d">%s</row>' % (ri, "".join(cells)))
    out.append("</sheetData></worksheet>")
    return "".join(out)


STYLES = """<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<styleSheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main">
<fonts count="3">
  <font><sz val="11"/><name val="Calibri"/></font>
  <font><b/><sz val="11"/><name val="Calibri"/></font>
  <font><b/><sz val="11"/><color rgb="FF1F4E79"/><name val="Calibri"/></font>
</fonts>
<fills count="3">
  <fill><patternFill patternType="none"/></fill>
  <fill><patternFill patternType="gray125"/></fill>
  <fill><patternFill patternType="solid"><fgColor rgb="FFD9E1F2"/><bgColor indexed="64"/></patternFill></fill>
</fills>
<borders count="2">
  <border><left/><right/><top/><bottom/><diagonal/></border>
  <border><left style="thin"><color rgb="FFBFBFBF"/></left><right style="thin"><color rgb="FFBFBFBF"/></right>
          <top style="thin"><color rgb="FFBFBFBF"/></top><bottom style="thin"><color rgb="FFBFBFBF"/></bottom>
          <diagonal/></border>
</borders>
<cellStyleXfs count="1"><xf numFmtId="0" fontId="0" fillId="0" borderId="0"/></cellStyleXfs>
<cellXfs count="3">
  <xf numFmtId="0" fontId="0" fillId="0" borderId="1" xfId="0" applyBorder="1"><alignment vertical="top" wrapText="1"/></xf>
  <xf numFmtId="0" fontId="1" fillId="2" borderId="1" xfId="0" applyFont="1" applyFill="1" applyBorder="1"><alignment vertical="center" wrapText="1"/></xf>
  <xf numFmtId="0" fontId="2" fillId="2" borderId="1" xfId="0" applyFont="1" applyFill="1" applyBorder="1"><alignment vertical="center" wrapText="1"/></xf>
</cellXfs>
<cellStyles count="1"><cellStyle name="Normal" xfId="0" builtinId="0"/></cellStyles>
</styleSheet>"""


def write_xlsx(path, sheets):
    ct = ['<?xml version="1.0" encoding="UTF-8" standalone="yes"?>',
          '<Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">',
          '<Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>',
          '<Default Extension="xml" ContentType="application/xml"/>',
          '<Override PartName="/xl/workbook.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.sheet.main+xml"/>',
          '<Override PartName="/xl/styles.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.styles+xml"/>']
    for i in range(1, len(sheets) + 1):
        ct.append('<Override PartName="/xl/worksheets/sheet%d.xml" '
                  'ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml"/>' % i)
    ct.append("</Types>")

    wb = ['<?xml version="1.0" encoding="UTF-8" standalone="yes"?>',
          '<workbook xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main" '
          'xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships"><sheets>']
    for i, (t, _, _) in enumerate(sheets, start=1):
        wb.append('<sheet name="%s" sheetId="%d" r:id="rId%d"/>' % (esc(t), i, i))
    wb.append("</sheets></workbook>")

    rels = ['<?xml version="1.0" encoding="UTF-8" standalone="yes"?>',
            '<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">']
    for i in range(1, len(sheets) + 1):
        rels.append('<Relationship Id="rId%d" Type="http://schemas.openxmlformats.org/'
                    'officeDocument/2006/relationships/worksheet" Target="worksheets/sheet%d.xml"/>' % (i, i))
    rels.append('<Relationship Id="rIdStyles" Type="http://schemas.openxmlformats.org/'
                'officeDocument/2006/relationships/styles" Target="styles.xml"/>')
    rels.append("</Relationships>")

    root = ('<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
            '<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">'
            '<Relationship Id="rId1" Type="http://schemas.openxmlformats.org/'
            'officeDocument/2006/relationships/officeDocument" Target="xl/workbook.xml"/></Relationships>')

    with zipfile.ZipFile(path, "w", zipfile.ZIP_DEFLATED) as z:
        z.writestr("[Content_Types].xml", "".join(ct))
        z.writestr("_rels/.rels", root)
        z.writestr("xl/workbook.xml", "".join(wb))
        z.writestr("xl/_rels/workbook.xml.rels", "".join(rels))
        z.writestr("xl/styles.xml", STYLES)
        for i, (t, hdr, rows) in enumerate(sheets, start=1):
            z.writestr("xl/worksheets/sheet%d.xml" % i, sheet_xml(t, hdr, rows))


def write_csv(path, sheets):
    with open(path, "w", encoding="utf-8-sig", newline="") as f:
        w = csv.writer(f)
        for title, hdr, rows in sheets:
            w.writerow(["### " + title])
            w.writerow(hdr)
            for r in rows:
                w.writerow(["" if c is None else c for c in r])
            w.writerow([])


SHEETS = [
    ("RTU↔IDU", HDR, IDU),
    ("RTU↔LSU", HDR, LSU),
    ("汇总", SUMMARY[0], SUMMARY[1:]),
]

write_xlsx(os.path.join(DOC, BASE + ".xlsx"), SHEETS)
write_csv(os.path.join(DOC, BASE + ".csv"), SHEETS)
print("写了 %s.xlsx / .csv" % BASE)
