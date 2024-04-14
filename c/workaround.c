#include "workaround.h"

my_sqlite3_destructor_type sqliteTransientAsDestructor() {
  return (my_sqlite3_destructor_type)-1;
}
