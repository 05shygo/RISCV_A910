# Address Conflict Check Granularity Changes

## Overview
Updated all address conflict checking in MSHR, VB, LFB, and WMB to use dcache set granularity instead of hardcoded bit ranges. This ensures proper scalability across different dcache configurations (1KB/2KB/4KB).

## Changes Made

### 1. lsu_wmb.sv
**Added LFB/VB address inputs for conflict detection:**
- `input logic [26:0] lfb_vb_addr_tto5` - LFB address being sent to VB
- `input logic lfb_vb_create_vld` - LFB creating VB request
- `input logic [31:0] vb_biu_aw_addr` - VB BIU AW address
- `input logic vb_biu_aw_req` - VB BIU AW request valid

**Added conflict check logic (lines 487-497):**
```systemverilog
// Conflict check: WMB can only issue BIU AW if no conflict with LFB/VB at set granularity
logic wmb_lfb_conflict;
logic wmb_vb_conflict;

assign wmb_lfb_conflict = lfb_vb_create_vld
                        && (wmb_write_req_addr[INDEX_MSB:INDEX_LSB] == lfb_vb_addr_tto5[INDEX_WIDTH-1:0]);

assign wmb_vb_conflict = vb_biu_aw_req
                       && (wmb_write_req_addr[INDEX_MSB:INDEX_LSB] == vb_biu_aw_addr[INDEX_MSB:INDEX_LSB]);

assign wmb_biu_aw_req = wmb_write_biu_req_unmask && !wmb_lfb_conflict && !wmb_vb_conflict;
```

**Behavior:**
- WMB only issues BIU AW request when there's no address conflict at dcache set level
- Checks against both LFB (creating VB request) and VB (issuing writeback)
- Uses parameterized INDEX_MSB:INDEX_LSB range that adapts to dcache size

### 2. lsu_wmb_entry.sv
**Updated dcache line matching (line 423):**
```systemverilog
// OLD: assign wmb_entry_hit_sq_pop_dcache_line = wmb_entry_hit_sq_pop_addr_tto6 && wmb_entry_vld;
// NEW:
assign wmb_entry_hit_sq_pop_dcache_line = (wmb_entry_addr[INDEX_MSB:INDEX_LSB] == sq_pop_addr[INDEX_MSB:INDEX_LSB])
                                        && wmb_entry_vld;
```

**Updated dependency check address comparison (lines 466-471):**
```systemverilog
// OLD: Hardcoded [11:4] range
assign wmb_entry_depd_addr_tto12_hit = (wmb_entry_addr[PA_WIDTH-1:12] == ld_dc_addr0[PA_WIDTH-1:12]);
assign wmb_entry_depd_addr_11to4_hit = (wmb_entry_addr[11:4] == ld_dc_addr0[11:4]);
assign wmb_entry_depd_addr1_11to4_hit = (wmb_entry_addr[11:4] == ld_dc_addr1_11to4[7:0]);

// NEW: Parameterized INDEX_MSB range
assign wmb_entry_depd_addr_tto12_hit = (wmb_entry_addr[PA_WIDTH-1:INDEX_MSB+1] == ld_dc_addr0[PA_WIDTH-1:INDEX_MSB+1]);
assign wmb_entry_depd_addr_11to4_hit = (wmb_entry_addr[INDEX_MSB:4] == ld_dc_addr0[INDEX_MSB:4]);
assign wmb_entry_depd_addr1_11to4_hit = (wmb_entry_addr[INDEX_MSB:4] == ld_dc_addr1_11to4[INDEX_MSB-4:0]);
```

### 3. Already Parameterized Modules
The following modules were already using dcache set granularity correctly:

**lsu_mshr_entry.sv (lines 658-685):**
- Uses `INDEX_MSB:INDEX_LSB` for all hit checks
- Checks: ld_da_hit_idx, st_da_hit_idx, sq_pop_hit_idx, wmb_ce_hit_idx

**lsu_lfb_addr_entry.sv (lines 212-242):**
- Uses `INDEX_MSB:INDEX_LSB` for all address comparisons
- Checks: ld_da_hit_idx, st_da_hit_idx, rb_biu_req_hit_idx, wmb_read/write_req_hit_idx

**lsu_vb.sv (line 190):**
- Uses `INDEX_WIDTH-1:0` for LFB hit detection
- `assign vb_lfb_vb_req_hit_idx = vb_vld && (vb_addr_tto5[INDEX_WIDTH-1:0] == lfb_vb_addr_tto5[INDEX_WIDTH-1:0]);`

## Granularity Mapping

| DCACHE_SIZE | INDEX_WIDTH | Set Bits | Granularity |
|-------------|-------------|----------|-------------|
| 1KB         | 4           | [8:5]    | 16 sets     |
| 2KB         | 5           | [9:5]    | 32 sets     |
| 4KB         | 6           | [10:5]   | 64 sets     |

## Verification Checklist

- [x] WMB checks LFB/VB conflicts before issuing BIU AW
- [x] WMB entry uses set granularity for dcache line matching
- [x] WMB entry uses set granularity for dependency checks
- [x] MSHR uses set granularity (already implemented)
- [x] LFB uses set granularity (already implemented)
- [x] VB uses set granularity (already implemented)
- [x] All hardcoded [11:5]/[11:4] ranges removed
- [x] Parameterized with INDEX_MSB/INDEX_LSB/INDEX_WIDTH

## Integration Notes

When instantiating lsu_wmb, the parent module must now connect:
```systemverilog
lsu_wmb #(
  .DCACHE_SIZE(DCACHE_SIZE)
) u_wmb (
  // ... existing connections ...
  .lfb_vb_addr_tto5(lfb_vb_addr_tto5),
  .lfb_vb_create_vld(lfb_vb_create_vld),
  .vb_biu_aw_addr(vb_biu_aw_addr),
  .vb_biu_aw_req(vb_biu_aw_req),
  // ...
);
```

## Testing Recommendations

1. Test with DCACHE_SIZE = 1024, 2048, 4096
2. Verify WMB blocks when LFB creates VB request to same set
3. Verify WMB blocks when VB issues writeback to same set
4. Verify dependency forwarding works at correct granularity
5. Verify no false conflicts from tag bits above INDEX_MSB
