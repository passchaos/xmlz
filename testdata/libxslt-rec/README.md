# libxslt REC regression suite

Copied from the libxslt repository (`tests/REC` and `tests/REC2`) so the XSLT
engine can be checked against the examples from the XSLT 1.0 specification
and their libxslt reference output. Licensed under the MIT license; see
`COPYING`.

Run with:

```sh
zig build xslt-rec-suite
```

`tools/libxslt_rec_suite.py` tracks the currently known differences
explicitly; unexpected failures or newly fixed tests fail the gate until the
baseline is updated.
