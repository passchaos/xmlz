# libxslt EXSLT regression suite

Copied from the libxslt repository (`tests/exslt`) so the EXSLT modules can
be checked against the reference implementation's own regression corpus.
Licensed under the MIT license; see `COPYING`.

Modules covered: `common`, `functions`, `math`, `sets`, and `strings`.
The `date`, `crypto`, `dynamic`, and `saxon` corpora are not vendored
because those modules are not implemented.

Run with:

```sh
zig build xslt-exslt-suite
```

`tools/libxslt_exslt_suite.py` tracks the currently known differences
explicitly; unexpected failures or newly fixed tests fail the gate until the
baseline is updated.
