\*\*其中\*\*：



\- pcpc 为当前需要预测的分支指令的地址

\- h为一个全局分支历史寄存器，用于记录全局分支历史

\- T0表为使用 pcpc 直接索引的表项，每个表项对应一个 2 位的饱和计数器（即使用 pcpc 的 kbit 索引 2k个表项的 Pattern History Table）

\- T1−T4这4个表是使用 pcpc 与对应的全局分支历史部分 h\[0\\:L(i)]进行哈希索引的表项，其中 L(i)=(int)(ai−1∗L(1)+0.5)\*L\*(\*i\*)=(int)(\*ai\*−1∗\*L\*(1)+0.5)，a为几何级数的比例因子

\- Ti中每个条目包含 predpred、tagtag 和 u三个字段

&#x20; - pred为 3 位的饱和预测器，用于预测当前分支指令的方向

&#x20; - tag为 pcpc 和 h\[0\\:L(i)]的哈希值，用于检索对应的表项。其中生成索引的哈希函数和生成 tag的哈希函数应当是不同的（由此可见 TAGE 表的构建类似缓存的组相联映射）

&#x20; - u为宽度为 2 的 useful 计数器，用于表示当前项的使用率

\- prediction由具有优先级的数据选择器选择得出



1\.



\### \*\*预测结果的获取\*\*



将 pcpc 和 h\[0\\:L(i)]进行哈希运算得到 Ti的索引 index每个表的哈希函数可以设计各异）。根据 index读取每个表的表项，使用 tag判断是否命中。



\*\*当有多个命中时，使用\*\* L(i)\*\*最大的表项作为预测结果\*\*：如当 T1和 T3都命中时，则使用 T3的表项作为预测依据。由于 T0是使用 pcpc 直接索引的，因此 T0必定命中，可见当 T1∼TN都没命中时，将采用 T0作为结果。



需要注意的是，与 cache 的实现不同，\*\*TAGE 预测器的表项中只需要保证\*\* tag\*\*命中即可（\*\* tag\*\*与哈希值一致即为命中）\*\*，无需 valid 位作为是否有效的保证，具体原因在读完下文后应该可以想到



2\.



\### \*\*符号说明\*\*



\*\*下面给出三个概念\*\*：



\- provider component，pcpn：最终提供预测信息的\*\*表项\*\*

\- final prediction，fpred：最终提供的预测信息

\- alternate prediction，altpred：可供选择的预测信息\*\*表项\*\*。若命中的表项 ≥2，则 altpred为命中的次长历史长度表项（T0永远命中，且历史长度视为 0）：如当 T1和 T3都命中时，altpred 为 T1；若仅命中 T0，则 T0的预测表项也是 altpred。



3\.



\### \*\*fpred 生成策略\*\*



在符号说明节中提到了三个概念，其中 altpred和 pcpn均为提供预测信息的表项，而 fpredfpred 为最终提供的预测结果，可见 altpred和 pcpn两者 2 选 1 得到了 fpred。



这种 2 选 1 的设计是为了避免在某些情况下，当更长分支历史信息的表项的信心不足时，使用 altpred进行预测的成功率会更大。这种预测信心取决于设计时的定义，如将 3’b100 以及 3’b011 定义为弱信心，其他都为强信心；也可以定义仅 pred计数器饱和时为强信心，其他都为弱信心。



\#### \*\*静态策略\*\*



即fpred 生成策略介绍的，当 pcpn为强信心时 fpred选择 pcpn，弱信心时选择 altpred。



\#### \*\*动态策略\*\*



使用一个有符号的 USE\_SELUSE\_SEL 计数器来作为一个动态的阈值，来决定 pcpn信心不足时，最终预测结果的选择方式。USE\_SELUSE\_SEL 可以是单个计数器，也可以是一个计数器寄存器组，其使用分支指令的 pcpc 直接索引。



\- pcpn的预测信息不为弱且 USE\_SELUSE\_SEL 为负时，选择 pcpn，否则选择 altpred。

\- 当 altpred与最终的分支结果相同时，USE\_SELUSE\_SEL 递增，反之则递减（应当遵循饱和计算进行更新）。



4\.



\### \*\*useful 的更新\*\*



当 altpred的预测结果与 fpred不同时，需要更新 pcpn的 useful 计数器 u，即当 altpred根据\[生成策略](https://ciliphen.github.io/TAGE/#fpred-%E7%94%9F%E6%88%90%E7%AD%96%E7%95%A5)选择 pcpn且 altpred的值与 pcpn不同时才需进行更新：



\- 若 pcpn与最终的分支跳转结果相同时，则 pcpn.u递增 1

\- 若 pcpn与最终的分支跳转结果不同时，则 pcpn.u递减 1



需要注意，对 useful 计数器的更新操作遵循饱和计算，即若 u=3，则递增 1 无作用；若 u=0，则递减 1 无作用。



同时，useful 计数器 u还起到年龄计数器的作用，其 MSB（u\[1]）以及 LSB（u\[0]）会周期性的交替重置为 0。原文中的周期设置为每 256K 个分支指令进行一次重置操作。



上面的操作起到了类似 LSU 策略的效果。



5\.



\### \*\*预测正确的更新\*\*



如果 fpred与最终的分支跳转结果相同，则对应的 pcpn.pred根据最终的分支预测结果进行更新：



\- 若最终的分支跳转结果为 taken，则 pcpn.pred递增 1

\- 若最终的分支跳转结果为 not-taken，则 pcpn.pred递减 1



同样，对 pcpn.pred的更新遵循饱和计算操作。



6\.



\### \*\*错误预测的更新\*\*



如果 fpred与最终的分支跳转结果不同，则需要执行以下操作：



1\. 更新 pcpn.pred，其更新操作与预测正确时的更新操作相同

2\. 如果最终给出预测结果的表 Ti（pcpn对应的表）不是使用最长全局分支历史信息的表（即 i\\<M，M=表数目−1），则尝试往使用更长的全局分支历史信息的表上分配一个新的表项：

&#x20;  1. 首先，读取所有比 Ti使用更长全局分支历史信息表索引得到的表项的 u的值

&#x20;     - (A)分配优先级：

&#x20;       1. 如果存在 u的值为 0 的 Tk(i\\<k\\<M)，则将该表项分配使用

&#x20;       2. 如果不存在 u的值为 0 的 Tk(i\\<k\\<M)，则所有比 Ti使用更长的全局分支历史信息的表项的 u值递减 1（这一步起到了类似 LSU 策略的效果）

&#x20;     - (B)避免 ping-phenomenon：

&#x20;       1. 如果有 2 个或以上的表，如 Tj，Tk，其中 i\\<j\\<k\\<M即使用的全局分支历史长度都比 Ti表长，且其索引得到的表项的 u值都为 0，则优先分配全局分支历史长度短的表 Tj

&#x20;     - (C)初始化被分配的条目：

&#x20;       1. 即将对应条目填入当前 pc和对应长度全局分支历史使用标签哈希函数生成的 tag，将 pred初始化为对应的分支跳转结果，将 u保持 0 不变（即 strong not useful）



其中策略 B 和策略 C 保证了存在多个未被分配的表时永远选择使用全局分支历史长度短的表进行替换，这可以最小化一些偶发性或者与分支历史不甚相关的分支指令占据过多的表项的现象。将 u初始化为 0，能够保证该条目只有被多次访问具有准确预测结果时才能获得长时间不被替换的资格。这样也避免了乒乓替换的现象。



预测阶段：本质就是「多表并行查找 + 最长历史优先」



对于当前 pc：



```Plain

&#x20;                        ┌── T0: PC index ──→ pred0

&#x20;                        │

pc + h\[L1] ──hash──────→ T1 ──→ tag compare ──→ hit1 ──→ pred1

&#x20;                        │

pc + h\[L2] ──hash──────→ T2 ──→ tag compare ──→ hit2 ──→ pred2

&#x20;                        │

pc + h\[L3] ──hash──────→ T3 ──→ tag compare ──→ hit3 ──→ pred3

&#x20;                        │

pc + h\[L4] ──hash──────→ T4 ──→ tag compare ──→ hit4 ──→ pred4

```



然后：



```Plain

T4 hit ? pred4 :

T3 hit ? pred3 :

T2 hit ? pred2 :

T1 hit ? pred1 :

&#x20;            pred0

```



所以最核心的一句话就是：TAGE 的预测结果 = 所有命中的 tagged table 中，使用最长 global history 的那个 entry 的预测。



T0 是 fallback，因此不需要 tag，也不需要 hit 判断。



\*\*provider 是“最长历史给出的答案”\*\*，而 \*\*alternate 是“次长历史给出的备用答案”\*\*



\*\*u = “这个 entry 是否值得长期占据 TAGE 表空间”的信誉度。\*\*



\*\*TAGE 的 entry validity 不是靠 cache 式 valid bit 表达，而是通过 tagged entry 的生命周期和 replacement policy 隐式管理。\*\*



```Plain

&#x20;                PC

&#x20;                 │

&#x20;         Global History h

&#x20;                 │

&#x20;      ┌──────────┴──────────┐

&#x20;      │                     │

&#x20;      ▼                     ▼

&#x20;    T0 index          hash(PC,h\[L])

&#x20;      │                     │

&#x20;      │             ┌───────┼────────┐

&#x20;      │             ▼       ▼        ▼

&#x20;      │            T1      T2 ...   TN

&#x20;      │             │       │        │

&#x20;      │          tag cmp tag cmp   tag cmp

&#x20;      │             │       │        │

&#x20;      │             └───────┼────────┘

&#x20;      │                     │

&#x20;      │              find longest hit

&#x20;      │                     │

&#x20;      │             ┌───────┴───────┐

&#x20;      │             │               │

&#x20;      │         provider        alternate

&#x20;      │             │               │

&#x20;      │             └───────┬───────┘

&#x20;      │                     │

&#x20;      ▼                     ▼

&#x20;    T0 pred            USE\_SEL /

&#x20;                        confidence

&#x20;                            │

&#x20;                            ▼

&#x20;                         fpred

&#x20;                            │

&#x20;                            ▼

&#x20;                      branch outcome

&#x20;                            │

&#x20;             ┌──────────────┼──────────────┐

&#x20;             ▼              ▼              ▼

&#x20;         pred update     u update       allocation

&#x20;                                           │

&#x20;                                           ▼

&#x20;                                 longer-history table

```



7\.



\### History Hash / Index Generator



History Hash / Index Generator 用于根据当前分支指令的 pc 以及全局分支历史寄存器 h，分别生成 T1\\\~TN 的 \*\*index\*\* 和 \*\*tag\*\*。



对于每个 tagged table Ti，均需要生成：



\- index\_i：用于访问 Ti 的表项 

\- tag\_i：用于判断访问到的表项是否命中 



其中：



\*\*生成 index 和生成 tag 必须采用不同的 Hash 函数。\*\*



为降低硬件实现复杂度，Hash 运算不直接在预测阶段遍历完整的 global history，而采用 \*\*Folded Global History\*\* 对长历史进行预计算，并在每次 global history 更新时进行增量更新。



1\.



\#### Global History



设全局分支历史寄存器为：



```Plain

h\[0 : H-1]

```



其中：



\- H：Global History Register 的最大历史长度 

\- h\[0]：最新加入的分支历史 

\- h\[H-1]：最老的历史 

\- h 按照如下方式更新： 



```Plain

h\_new\[0]   = branch\_taken

h\_new\[j]   = h\_old\[j-1]       (1 <= j < H)

```



即每次得到一个新的分支结果后，将历史向高位方向移动，并将最新的分支结果写入 h\[0]。



对于 Ti，其使用的历史长度为 L(i)，因此：



```Plain

Ti 使用：

h\[0 : L(i)-1]

```



其中 L(i) 表示该表实际使用的 global history bit 数量。



> 为避免数组范围歧义，本文中的 L(i) 均表示历史长度，而不是最高 bit 下标。



2\.



\#### Folded Global History



由于 T1\\\~TN 的历史长度可能远大于对应 table 的 index/tag 位宽，因此不能直接使用完整的 global history 进行索引。



例如：



```Plain

L(4) = 128

index\_width = 10

tag\_width   = 12

```



如果直接使用：



```Plain

pc XOR h\[0:127]

```



不仅存在位宽不匹配的问题，也会产生较大的组合逻辑。



因此，对于每个 Ti，维护两组独立的 Folded History：



```Plain

FH\_IDX\[i]

FH\_TAG\[i]

```



分别用于 index 和 tag 的生成。



3\.



\#### Index Folded History



设 Ti 的 index 宽度为：



```Plain

IDX\_W(i)

```



\[image](https://my.feishu.cn/space/api/box/stream/download/asynccode/?code=ZjkxZmMwMTNlZTdkNDFjMDQyOWY4NDZjNjY2OWJmMmJfVDFZQlB6RHZZb012VzJmMnlERzZ3UFlJamxNN09IbGNfVG9rZW46UmNNRWJsOWJab0pNa254MDJxM2N3OUJjbnAyXzE3OTAzMjc5MjM6MTc5MDMzMTUyM19WNA\\\&add\_watermark=true\\\&scene\_type=CCM)



即：



> 将 h\[0\\:L(i)-1] 按 IDX\_W(i) 分组，对落在相同 bit position 的 history bit 进行 XOR。



例如：



```Plain

L(i) = 32

IDX\_W = 8

```



则：



```Plain

FH\_IDX\[0] = h\[0]  ^ h\[8]  ^ h\[16] ^ h\[24]

FH\_IDX\[1] = h\[1]  ^ h\[9]  ^ h\[17] ^ h\[25]

FH\_IDX\[2] = h\[2]  ^ h\[10] ^ h\[18] ^ h\[26]

...

FH\_IDX\[7] = h\[7]  ^ h\[15] ^ h\[23] ^ h\[31]

```



最终得到：



```Plain

FH\_IDX\[7:0]

```



4\.



\#### Tag Folded History



Tag 使用独立的 folded history：



\[image](https://my.feishu.cn/space/api/box/stream/download/asynccode/?code=ZTE5NGU0NGQ4YmI1NWU1ZjQxN2EyNGM0YTFiMzc0NTJfSkRvcWJOa3QxRlZ2NEsxbnRkcWEza2hUYlVoWHE4RXJfVG9rZW46Wk56TGJHYU5Kb3l2aUN4VW50eWNzTUgybldFXzE3OTAzMjc5MjM6MTc5MDMzMTUyM19WNA\\\&add\_watermark=true\\\&scene\_type=CCM)



但是，\*\*Tag Hash 不直接使用与 Index Hash 完全相同的计算形式\*\*。



为了使 index hash 与 tag hash 的映射不同，对 folded history 进行循环旋转：



\[image](https://my.feishu.cn/space/api/box/stream/download/asynccode/?code=NzBkZGFmZDU3MTAxOWU1MThhMzE1OTQ4Y2YyNDE4ZjNfT0xuR0lMa21IREhFWDA1OVZQUlBqV2tvY3dHTmwyclZfVG9rZW46SlowSWJuR2Nob1BsdW14UkNxTWNoYXVubjhnXzE3OTAzMjc5MjM6MTc5MDMzMTUyM19WNA\\\&add\_watermark=true\\\&scene\_type=CCM)



其中：



```Plain

R\_i = i mod TAG\_W(i)

```



因此：



```Plain

Index Hash：

PC + FH\_IDX



Tag Hash：

PC + ROTL(FH\_TAG, R\_i)

```



从而保证 index 与 tag 不使用完全相同的 Hash 映射。



5\.



\#### Index Generation



对于 Ti，最终 index 定义为：



\[image](https://my.feishu.cn/space/api/box/stream/download/asynccode/?code=YzY3ZTQyZGNjZTRkNzc0NTFjZTE0NGJmMjhkMTljZWZfSGNxMzBkNms5SzN3S2VTRzdUN3dTeHk2bWNOejlRRWJfVG9rZW46WEl5VmJxVFc1b0pxMjN4MzBDWGN5aFh5blFlXzE3OTAzMjc5MjM6MTc5MDMzMTUyM19WNA\\\&add\_watermark=true\\\&scene\_type=CCM)



其中：



\- PC\[IDX\_W-1:0] 为 PC 的低 IDX\_W 位 

\- FH\_IDX\_i 为对应历史长度的 folded history 



因此：



```Plain

&#x20;                    ┌──────────────┐

PC ─────────────────→│ PC\[IDX\_W-1:0]│

&#x20;                    └──────┬───────┘

&#x20;                           XOR

&#x20;                    ┌──────┴───────┐

&#x20;                    │  FH\_IDX\[i]   │

&#x20;                    └──────┬───────┘

&#x20;                           │

&#x20;                           ▼

&#x20;                        index\_i

```



6\.



\#### Tag Generation



对于 Ti，最终 tag 定义为：



\[image](https://my.feishu.cn/space/api/box/stream/download/asynccode/?code=MmFjNGI4ZDg2MDY0MmRiNzNmMGU2ODdlMDFmZDAwM2NfSXhzSXpqYzA0bmI5SUZBeUdRdmRqUDZUYlZ0VXNlUGpfVG9rZW46Q0dWWWJ0Wm1lb2lXVjh4SjVWdWNXRFdCbm1zXzE3OTAzMjc5MjM6MTc5MDMzMTUyM19WNA\\\&add\_watermark=true\\\&scene\_type=CCM)



即：



```Plain

PC

&#x20;│

&#x20;├──→ PC\[TAG\_W-1:0]

&#x20;│

&#x20;│          ┌──────────────┐

&#x20;└─────────→│      XOR     │────→ tag\_i

&#x20;           └──────▲───────┘

&#x20;                  │

&#x20;            ROTL(FH\_TAG,R\_i)

```



因此：



```Plain

index\_i = PC\_index XOR FH\_IDX

tag\_i   = PC\_tag   XOR ROTL(FH\_TAG,R\_i)

```



二者使用不同的 Hash 路径。



7\.



\#### Folded History 的增量更新



为了避免每次预测时重新计算：



```Plain

h\[0:L(i)-1]

```



的 XOR folding，每一个 Ti 均维护自己的：



```Plain

FH\_IDX\[i]

FH\_TAG\[i]

```



当 global history 更新一个 bit 时，不需要重新遍历整个 history，而只需要根据 folded history 的递推关系进行更新。



\[image](https://my.feishu.cn/space/api/box/stream/download/asynccode/?code=YWJiMjM4MmQ5ZTIxZWNlZDk0NTQ0NjRjN2Y1MzU1MjZfbk11RnNNdDBnMldSUkhubzBlYTlCeTRlb3FaZUdmNEpfVG9rZW46TGpLTGJsbWRnb09EdlF4QXcwSWM0NzkzbkdjXzE3OTAzMjc5MjM6MTc5MDMzMTUyM19WNA\\\&add\_watermark=true\\\&scene\_type=CCM)



即：



```Plain

&#x20;               ┌────────────────────┐

&#x20;               │                    │

&#x20;               ▼                    │

FH\_old\[W-1] ──→ XOR ──→ FH\_new\[0]    │

&#x20;                  ▲                 │

&#x20;                  │                 │

&#x20;             new\_history            │

&#x20;                                    │

FH\_old\[0] ─────────────────→ FH\_new\[1]

FH\_old\[1] ─────────────────→ FH\_new\[2]

...

FH\_old\[W-2] ────────────────→ FH\_new\[W-1]

```



因此，global history 更新时：



```Plain

FH\_IDX\[i]

FH\_TAG\[i]

```



均可以在 O(1) 的硬件逻辑中更新，而无需重新 XOR L(i) 个 history bit。



8\.



\#### 多个 TAGE Table 的 History Hash



对于：



```Plain

T1 \~ TN

```



分别维护：



```Plain

FH\_IDX\[1] \~ FH\_IDX\[N]

FH\_TAG\[1] \~ FH\_TAG\[N]

```



因此在一个预测周期内可以并行生成：



```Plain

&#x20;                   PC

&#x20;                    │

&#x20;       ┌────────────┼────────────┐

&#x20;       │            │            │

&#x20;       ▼            ▼            ▼

&#x20;      T1           T2           T3 ... TN

&#x20;       │            │            │

&#x20;  FH\_IDX\[1]     FH\_IDX\[2]     FH\_IDX\[3]

&#x20;  FH\_TAG\[1]     FH\_TAG\[2]     FH\_TAG\[3]

&#x20;       │            │            │

&#x20;       ▼            ▼            ▼

&#x20;    index1       index2       index3

&#x20;    tag1         tag2         tag3

```



从而 T1\\\~TN 可以同时进行 SRAM/RAM 访问。



\*\*最终的数据流：\*\*



```Plain

&#x20;                  PC

&#x20;                   │

&#x20;         ┌─────────┴─────────┐

&#x20;         │                   │

&#x20;         ▼                   ▼

&#x20;       T0 index          Global History

&#x20;         │                   │

&#x20;         │          ┌────────┴────────┐

&#x20;         │          │                 │

&#x20;         │       Fold IDX          Fold TAG

&#x20;         │          │                 │

&#x20;         │          ▼                 ▼

&#x20;         │       index\_i           tag\_i

&#x20;         │          │                 │

&#x20;         │          ▼                 ▼

&#x20;         │         T1/T2/T3/T4 Table Lookup

&#x20;         │                    │

&#x20;         └────────────────────┤

&#x20;                              ▼

&#x20;                        Hit Detection

&#x20;                              │

&#x20;                              ▼

&#x20;                   Provider / Alternate

&#x20;                              │

&#x20;                              ▼

&#x20;                         fpred / USE\_SEL

&#x20;                              │

&#x20;                              ▼

&#x20;                        Branch Outcome

&#x20;                              │

&#x20;                 ┌────────────┼────────────┐

&#x20;                 ▼            ▼            ▼

&#x20;              pred update   u update   allocation

```

