module f_tar_gz.bin.read_db;

import core.stdc.stdio;
import core.stdc.string;
import core.sys.posix.unistd;
import core.sys.posix.fcntl;
import f_tar_gz.md5;
import f_tar_gz.tar_parser;
import f_tar_gz.zlib_state;
import f_tar_gz.cdef.sqlite3;

struct TarGzParser
{
	ZlibState      zs;
	ZlibResumeData rd;
	Db             db;
	ulong          targetBegin;
	ulong          targetEnd;
	bool           end;
	ulong          targetBytesOut;
	const(char)*   wantMd5;
	Md5            md5;

	bool initialize(
		const(char)* tar,
		const(char)* dat,
		ulong        offset,
		ulong        length,
		const(char)* wantMd5Arg)
	{
		targetBegin = offset;
		targetEnd = offset + length;
		wantMd5 = wantMd5Arg;

		if (!db.open(dat))
			return false;

		if (!db.getResumeDataFor(offset, rd))
			return false;

		// db can already be closed at this point
		db.close();

		if (rd.totalOut ? !zs.initialize(rd) : !zs.initialize())
			return false;

		if (wantMd5 && !md5.initialize())
			return false;

		return true;
	}

	void deinitialize()
	{
		db.close();
		zs.deinitialize();
	}

	bool putEndOfFile()
	{
		// should not happen
		// file ended before we output the desired file
		fprintf(stderr, "end of file unexpectedly reached\n");
		return false;
	}

	bool put(scope const(ubyte)[] buf)
	{
		__gshared static ubyte[128*1024] udbuf = void;

		while (buf.length)
		{
			bool ok = zs.feed(buf, udbuf[], &onZlibDataDecoded);

			// zlib or callback error
			if (!ok)
				return false;

			// call again with more data
			if (!buf.ptr)
				continue;

			// zlib stream finished, but this shouldn't happen
			fprintf(stderr, "zlib stream unexpectedly finished\n");
			return false;
		}

		// empty buffer
		return true;
	}

	bool onZlibDataDecoded(scope const(ubyte)[] data)
	{
		ulong curBegin = zs.totalOut - data.length;
		ulong curEnd = zs.totalOut;

		if (curEnd < targetBegin)
			return true;
		if (curBegin >= targetEnd)
			return false;

		if (curBegin < targetBegin)
		{
			size_t extraStart = cast(size_t)(targetBegin-curBegin);
			data = data[extraStart..$];
		}
		if (curEnd > targetEnd)
		{
			size_t extraEnd = cast(size_t)(curEnd-targetEnd);
			if (extraEnd)
				data = data[0..$-extraEnd];
		}

		if (write(1, data.ptr, data.length) != data.length)
		{
			fprintf(stderr, "write error\n");
			return false;
		}
		targetBytesOut += data.length;
		if (wantMd5)
		{
			if (!md5.put(data))
				return false;
		}

		if (targetBytesOut == targetEnd-targetBegin)
		{
			if (wantMd5)
			{
				if (!md5.finalize())
					return false;
				if (strcmp(wantMd5, md5.str.ptr))
				{
					fprintf(stderr, "md5 mismatch: expected %s, got %s\n", wantMd5, md5.str.ptr);
					return false;
				}
			}
			// goodbye!
			deinitialize();
			_exit(0);
		}

		if (curEnd >= targetEnd)
			return false;

		return true;
	}
}

struct Db
{
	sqlite3* db;

	sqlite3_stmt* stmtSelectResume;

	bool open(const(char)* path)
	{
		int res = sqlite3_open_v2(path, &db, SQLITE_OPEN_READONLY, null);
		if (res != SQLITE_OK)
		{
			fprintf(stderr, "%s(%d): %s\n", __FILE__.ptr, __LINE__, sqlite3_errstr(res));
			return false;
		}

		char *errmsg;
		res = sqlite3_exec(db, "
		PRAGMA hard_heap_limit=2000000;
		PRAGMA mmap_size=9223372036854775807;
		PRAGMA soft_heap_limit=9223372036854775807;
		PRAGMA temp_store=MEMORY;
		", null, null, &errmsg);
		if (res != SQLITE_OK)
		{
			fprintf(stderr, "%s(%d): %s\n", __FILE__.ptr, __LINE__, errmsg);
			return false;
		}

		res = sqlite3_prepare_v2(db, "
		SELECT dict, last_byte, bits_left, total_in, total_out
		FROM zlib_resume_data
		WHERE total_out <= ?
		ORDER BY total_out DESC
		LIMIT 1
		", -1, &stmtSelectResume, null);
		if (res != SQLITE_OK)
		{
			fprintf(stderr, "%s(%d): %s\n", __FILE__.ptr, __LINE__, sqlite3_errmsg(db));
			return false;
		}

		return true;
	}

	void close()
	{
		sqlite3_finalize(stmtSelectResume);
		stmtSelectResume = null;

		sqlite3_close(db);
		db = null;
	}

	bool getResumeDataFor(ulong offset, ref ZlibResumeData rd)
	{
		int res = SQLITE_OK;
		alias stmt = stmtSelectResume;

		//~ fprintf(stderr, "IN: offset=%llu\n", offset);

		if (res == SQLITE_OK)
			res = sqlite3_bind_int64(stmt, 1, offset);

		if (res != SQLITE_OK)
		{
			fprintf(stderr, "%s(%d): %s\n", __FILE__.ptr, __LINE__, sqlite3_errmsg(db));
			return false;
		}

		res = sqlite3_step(stmt);
		if (res != SQLITE_ROW)
		{
			if (res == SQLITE_DONE)
			{
				sqlite3_reset(stmt);
				return true;
			}
			fprintf(stderr, "%s(%d): %s\n", __FILE__.ptr, __LINE__, sqlite3_errmsg(db));
			return false;
		}

		// SELECT dict, last_byte, bits_left, total_in, total_out

		const(void)* dict = sqlite3_column_blob(stmt, 0);
		uint dictSize = sqlite3_column_bytes(stmt, 0);
		uint lastByte = sqlite3_column_int(stmt, 1);
		uint bitsLeft = sqlite3_column_int(stmt, 2);
		ulong totalIn = sqlite3_column_int64(stmt, 3);
		ulong totalOut = sqlite3_column_int64(stmt, 4);

		rd.dictionary[0..dictSize] = cast(ubyte[])dict[0..dictSize];
		rd.dictLength = cast(ushort)dictSize;
		rd.lastByte = cast(ubyte)lastByte;
		rd.bitsLeft = cast(ubyte)bitsLeft;
		rd.totalIn = totalIn;
		rd.totalOut = totalOut;

		//~ fprintf(stderr, "R: dictSize=%u\n", dictSize);
		//~ fprintf(stderr, "R: lastByte=%u\n", lastByte);
		//~ fprintf(stderr, "R: bitsLeft=%u\n", bitsLeft);
		//~ fprintf(stderr, "R: totalIn=%llu\n", totalIn);
		//~ fprintf(stderr, "R: totalOut=%llu\n", totalOut);

		res = sqlite3_reset(stmt);
		if (res != SQLITE_OK)
		{
			fprintf(stderr, "%s(%d): %s\n", __FILE__.ptr, __LINE__, sqlite3_errmsg(db));
			return false;
		}

		return true;
	}
}

extern(C) int main(int argc, char** argv)
{
	const(char)* tar;
	const(char)* db;
	const(char)* md5;
	ulong size = -1;
	ulong offset = -1;
	for (int i = 1; i < argc; i++)
	{
		if (!strncmp(argv[i], "-db=", 4))
		{
			db = argv[i]+4;
		}
		else if (!strncmp(argv[i], "-md5=", 5))
		{
			md5 = argv[i]+5;
		}
		else if (!strncmp(argv[i], "-offset=", 8))
		{
			int n;
			if (
				sscanf(argv[i]+8, "%llu%n", &offset, &n) != 1 ||
				n != strlen(argv[i]+8))
			{
				fprintf(stderr, "bad number '%s'\n", argv[i]+8);
				return 1;
			}
		}
		else if (!strncmp(argv[i], "-size=", 6))
		{
			int n;
			if (
				sscanf(argv[i]+6, "%llu%n", &size, &n) != 1 ||
				n != strlen(argv[i]+6))
			{
				fprintf(stderr, "bad number '%s'\n", argv[i]+6);
				return 1;
			}
		}
		else if (!strncmp(argv[i], "-tar=", 5))
		{
			tar = argv[i]+5;
		}
		else
		{
			fprintf(stderr, "unknown option '%s'\n", argv[i]);
			return 1;
		}
	}

	if (!tar || !db || offset == -1 || size == -1)
	{
		fprintf(stderr, "usage: read_db -tar=<path> -db=<path> -offset=<n> -size=<n> [-md5=<hex>]\n");
		return 1;
	}

	TarGzParser p;
	if (!p.initialize(tar, db, offset, size, md5))
		return 1;

	int f = open(tar, O_RDONLY);
	if (f < 0)
	{
		perror("open");
		p.deinitialize();
		return 1;
	}
	if (lseek(f, p.rd.totalIn, SEEK_SET) != p.rd.totalIn)
	{
		fprintf(stderr, "seek failed\n");
		p.deinitialize();
		return 1;
	}
	for (;;)
	{
		__gshared static ubyte[64*1024] buf = void;

		ssize_t rv = read(f, buf.ptr, buf.length);

		if (rv < 0)
		{
			perror("read");
			return 1;
		}

		if (rv && !p.put(buf[0..rv]))
			return 1;

		if (!rv)
		{
			if (!p.putEndOfFile())
				return 1;

			break;
		}
	}
	p.deinitialize();

	return 0;
}
