id: nj8usqhaks6kkewaj3pbp0arfh4281me25bl7tf9das1vbqv
name: sqlite
main: sqlite.zig
license: MIT
description: Thin SQLite wrapper
c_include_dirs:
  - c
c_source_files:
  - c/workaround.c
dependencies:
- src: http https://sqlite.org/2025/sqlite-amalgamation-3480000.zip sha256-d9a15a42db7c78f88fe3d3c5945acce2f4bfe9e4da9f685cd19f6ea1d40aa884
  c_include_dirs:
    - sqlite-amalgamation-3480000
  c_source_files:
    - sqlite-amalgamation-3480000/sqlite3.c
