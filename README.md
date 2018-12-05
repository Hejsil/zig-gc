# zig-bench

A simple Garbage Collector in Zig. This GC is pretty bad, and mostly just a proof of concept.

## Benchmarks

```
Benchmark                              Arg             Mean(ns)
---------------------------------------------------------------
DirectAllocator                          0                 9867
DirectAllocator                          1                20578
DirectAllocator                          2                37061
DirectAllocator                          3                10285
DirectAllocator                          4                19847
DirectAllocator                          5                35768
DirectAllocator                          6                 9291
DirectAllocator                          7                18095
DirectAllocator                          8                35587
Arena_DirectAllocator                    0                 5796
Arena_DirectAllocator                    1                 8054
Arena_DirectAllocator                    2                10330
Arena_DirectAllocator                    3                 9932
Arena_DirectAllocator                    4                12132
Arena_DirectAllocator                    5                14381
Arena_DirectAllocator                    6                10039
Arena_DirectAllocator                    7                12176
Arena_DirectAllocator                    8                14335
GcAllocator_DirectAllocator              0                23010
GcAllocator_DirectAllocator              1                53555
GcAllocator_DirectAllocator              2                96861
GcAllocator_DirectAllocator              3                28409
GcAllocator_DirectAllocator              4                70079
GcAllocator_DirectAllocator              5               127971
GcAllocator_DirectAllocator              6                41809
GcAllocator_DirectAllocator              7               113122
GcAllocator_DirectAllocator              8               212150
FixedBufferAllocator                     0                  118
FixedBufferAllocator                     1                  198
FixedBufferAllocator                     2                  338
FixedBufferAllocator                     3                   98
FixedBufferAllocator                     4                  190
FixedBufferAllocator                     5                  353
FixedBufferAllocator                     6                   97
FixedBufferAllocator                     7                  177
FixedBufferAllocator                     8                  340
Arena_FixedBufferAllocator               0                  125
Arena_FixedBufferAllocator               1                  220
Arena_FixedBufferAllocator               2                  436
Arena_FixedBufferAllocator               3                  145
Arena_FixedBufferAllocator               4                  232
Arena_FixedBufferAllocator               5                  401
Arena_FixedBufferAllocator               6                  144
Arena_FixedBufferAllocator               7                  248
Arena_FixedBufferAllocator               8                  491
GcAllocator_FixedBufferAllocator         0                23160
GcAllocator_FixedBufferAllocator         1                69917
GcAllocator_FixedBufferAllocator         2               198616
GcAllocator_FixedBufferAllocator         3                85539
GcAllocator_FixedBufferAllocator         4               352586
GcAllocator_FixedBufferAllocator         5              1849736
GcAllocator_FixedBufferAllocator         6               269965
GcAllocator_FixedBufferAllocator         7              1691938
GcAllocator_FixedBufferAllocator         8              3105935
OK
All tests passed.
```
