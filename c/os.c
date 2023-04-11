
#include "sqlite3.h"

extern sqlite3_vfs *sqlite3_demovfs(void);

int sqlite3_os_init()
{
    sqlite3_vfs_register(sqlite3_demovfs(), 0);
    return 0;
}

int sqlite3_os_end()
{
    return 0;
}

