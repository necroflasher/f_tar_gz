
create_db_SRCS = \
	src/bin/create_db.d \
	src/cdef/sqlite3.d \
	src/md5.d \
	src/tar_parser.d \
	src/zlib_state.d \

read_db_SRCS = \
	src/bin/read_db.d \
	src/cdef/sqlite3.d \
	src/md5.d \
	src/tar_parser.d \
	src/zlib_state.d \

all: create_db read_db

# apt install gdc make libz-dev libssl-dev libsqlite3-dev

GDC      = gdc -fPIC
GDCFLAGS = -O2 -g -mcpu=native -Wno-deprecated -fno-druntime
GDCLIBS  = -lz -lcrypto -lsqlite3

create_db: $(create_db_SRCS)
	$(GDC) $(GDCFLAGS) -o $@ $^ $(GDCLIBS)

read_db: $(read_db_SRCS)
	$(GDC) $(GDCFLAGS) -o $@ $^ $(GDCLIBS)
