module f_tar_gz.bin.create_db;

import core.stdc.stdio;
import core.stdc.string;
import core.sys.posix.fcntl;
import core.sys.posix.unistd;
import f_tar_gz.md5;
import f_tar_gz.tar_parser;
import f_tar_gz.zlib_state;
import f_tar_gz.cdef.sqlite3;

struct TarGzParser
{
	TarParser      tar;
	ZlibState      zs;
	Md5            md5;
	bool           end;
	ZlibResumeData rd;
	Db             db;

	bool initialize(const(char)* dat)
	{
		tar.cb.fileBegin = &onTarFileBegin;
		tar.cb.fileData = &onTarFileData;
		tar.cb.fileEnd = &onTarFileEnd;

		if (!db.open(dat))
			return false;

		if (!zs.initialize())
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
		if (!end)
		{
			fprintf(stderr, "%s: zlib stream not yet ended\n", __FUNCTION__.ptr);
			return false;
		}

		return true;
	}

	bool put(scope const(ubyte)[] buf)
	{
		__gshared static ubyte[128*1024] udbuf = void;

		if (end)
		{
			fprintf(stderr, "extra data after zlib stream (2)\n");
			return false;
		}

		while (buf.length)
		{
			bool ok = zs.feed(buf, udbuf[], &onZlibDataDecoded);

			// zlib or callback error
			if (!ok)
				return false;

			if (buf.ptr)
			{
				if (buf.length)
				{
					fprintf(stderr, "extra data after zlib stream (1)\n");
					return false;
				}

				if (!tar.putEndOfFile())
					return false;

				end = true;

				return true;
			}
			else
			{
				// call again with more data
				continue;
			}
		}

		// empty buffer
		return true;
	}

	bool onZlibDataDecoded(scope const(ubyte)[] data)
	{
		bool ok = tar.put(data);

		// state is past the current data, get it for the next call
		if (ok)
			zs.getState(&rd);

		return ok;
	}

	bool onTarFileBegin()
	{
		if (!md5.initialize())
			return false;

		return true;
	}

	bool onTarFileData(scope const(ubyte)[] buf, ulong offset)
	{
		if (!md5.put(buf))
			return false;

		// beginning of file, have a meaningful save point
		if (!offset && rd.totalOut)
		{
			if (!db.addResumeDataIfNotExists(rd))
				return false;
		}

		return true;
	}

	bool onTarFileEnd()
	{
		if (!md5.finalize())
			return false;

		Db.InsertFile fi = {
			offset:   tar.current.dataBeginOffset,
			md5:      md5.hash,
			filesize: tar.current.filesize,
			filename: tar.current.filename,
		};
		if (!db.addFileIfNotExists(fi))
			return false;

		return true;
	}
}

struct Db
{
	sqlite3* db;

	sqlite3_stmt* stmtInsertIntoResume;
	sqlite3_stmt* stmtInsertIntoFiles;

	bool open(const(char)* path)
	{
		int res = sqlite3_open_v2(path, &db, SQLITE_OPEN_READWRITE|SQLITE_OPEN_CREATE, null);
		if (res != SQLITE_OK)
		{
			fprintf(stderr, "%s(%d): %s\n", __FILE__.ptr, __LINE__, sqlite3_errstr(res));
			return false;
		}

		char *errmsg;
		res = sqlite3_exec(db, "
		PRAGMA journal_mode=WAL;
		CREATE TABLE IF NOT EXISTS files (
			offset   INTEGER PRIMARY KEY NOT NULL CHECK(offset >= 0),
			md5      BLOB                NOT NULL CHECK(LENGTH(md5) = 16),
			filesize INTEGER             NOT NULL CHECK(filesize >= 0),
			filename TEXT                NOT NULL CHECK(filename <> '')
		) STRICT;
		CREATE TABLE IF NOT EXISTS zlib_resume_data (
			dict      BLOB                NOT NULL CHECK(LENGTH(dict) BETWEEN 1 AND 32768),
			last_byte INTEGER             NOT NULL CHECK(last_byte BETWEEN 0 AND 127),
			bits_left INTEGER             NOT NULL CHECK(bits_left BETWEEN 0 AND 7),
			total_in  INTEGER             NOT NULL CHECK(total_in >= 0),
			total_out INTEGER PRIMARY KEY NOT NULL CHECK(total_out >= 0)
		) STRICT;
		CREATE INDEX IF NOT EXISTS files_filename ON files(filename);
		", null, null, &errmsg);
		if (res != SQLITE_OK)
		{
			fprintf(stderr, "%s(%d): %s\n", __FILE__.ptr, __LINE__, errmsg);
			return false;
		}

		// replace instead of ignore, this doesn't ignore CHECK()
		res = sqlite3_prepare_v2(db, "
		INSERT OR REPLACE INTO files(offset, md5, filesize, filename)
		VALUES (?, ?, ?, ?)
		", -1, &stmtInsertIntoFiles, null);
		if (res != SQLITE_OK)
		{
			fprintf(stderr, "%s(%d): %s\n", __FILE__.ptr, __LINE__, sqlite3_errmsg(db));
			return false;
		}

		// replace instead of ignore, this doesn't ignore CHECK()
		res = sqlite3_prepare_v2(db, "
		INSERT OR REPLACE INTO zlib_resume_data(dict, last_byte, bits_left, total_in, total_out)
		VALUES (?, ?, ?, ?, ?)
		", -1, &stmtInsertIntoResume, null);
		if (res != SQLITE_OK)
		{
			fprintf(stderr, "%s(%d): %s\n", __FILE__.ptr, __LINE__, sqlite3_errmsg(db));
			return false;
		}

		return true;
	}

	void close()
	{
		if (db)
		{
			char *errmsg;
			int res = sqlite3_exec(db, "
			ANALYZE;
			", null, null, &errmsg);
			if (res != SQLITE_OK)
				fprintf(stderr, "%s(%d): %s\n", __FILE__.ptr, __LINE__, errmsg);
		}

		sqlite3_finalize(stmtInsertIntoResume);
		stmtInsertIntoResume = null;

		sqlite3_finalize(stmtInsertIntoFiles);
		stmtInsertIntoFiles = null;

		sqlite3_close(db);
		db = null;
	}

	bool addResumeDataIfNotExists(ref ZlibResumeData zr)
	{
		int res = SQLITE_OK;
		alias stmt = stmtInsertIntoResume;

		//~ fprintf(stderr, "R: dictLength=%u\n", zr.dictLength);
		//~ fprintf(stderr, "R: lastByte=%u\n", zr.lastByte);
		//~ fprintf(stderr, "R: bitsLeft=%u\n", zr.bitsLeft);
		//~ fprintf(stderr, "R: totalIn=%llu\n", zr.totalIn);
		//~ fprintf(stderr, "R: totalOut=%llu\n", zr.totalOut);

		// INSERT INTO zlib_resume_data(dict, last_byte, bits_left, total_in, total_out)
		if (res == SQLITE_OK)
			res = sqlite3_bind_blob(stmt, 1, zr.dictionary.ptr, zr.dictLength, SQLITE_TRANSIENT);
		if (res == SQLITE_OK)
			res = sqlite3_bind_int(stmt, 2, zr.lastByte);
		if (res == SQLITE_OK)
			res = sqlite3_bind_int(stmt, 3, zr.bitsLeft);
		if (res == SQLITE_OK)
			res = sqlite3_bind_int64(stmt, 4, zr.totalIn);
		if (res == SQLITE_OK)
			res = sqlite3_bind_int64(stmt, 5, zr.totalOut);

		if (res != SQLITE_OK)
		{
			fprintf(stderr, "%s(%d): %s\n", __FILE__.ptr, __LINE__, sqlite3_errmsg(db));
			return false;
		}

		res = sqlite3_step(stmt);
		if (res != SQLITE_DONE)
		{
			fprintf(stderr, "%s(%d): %s\n", __FILE__.ptr, __LINE__, sqlite3_errmsg(db));
			return false;
		}

		res = sqlite3_reset(stmt);
		if (res != SQLITE_OK)
		{
			fprintf(stderr, "%s(%d): %s\n", __FILE__.ptr, __LINE__, sqlite3_errmsg(db));
			return false;
		}

		return true;
	}

	struct InsertFile
	{
		ulong        offset;
		ubyte[]      md5;
		ulong        filesize;
		const(char)* filename;
	}

	bool addFileIfNotExists(ref InsertFile fi)
	{
		int res = SQLITE_OK;
		alias stmt = stmtInsertIntoFiles;

		// INSERT INTO files(offset, md5, filesize, filename)
		if (res == SQLITE_OK)
			res = sqlite3_bind_int64(stmt, 1, fi.offset);
		if (res == SQLITE_OK)
			res = sqlite3_bind_blob(stmt, 2, fi.md5.ptr, cast(uint)fi.md5.length, SQLITE_TRANSIENT);
		if (res == SQLITE_OK)
			res = sqlite3_bind_int64(stmt, 3, fi.filesize);
		if (res == SQLITE_OK)
			res = sqlite3_bind_text(stmt, 4, fi.filename, -1, SQLITE_TRANSIENT);

		if (res != SQLITE_OK)
		{
			fprintf(stderr, "%s(%d): %s\n", __FILE__.ptr, __LINE__, sqlite3_errmsg(db));
			return false;
		}

		res = sqlite3_step(stmt);
		if (res != SQLITE_DONE)
		{
			fprintf(stderr, "%s(%d): %s\n", __FILE__.ptr, __LINE__, sqlite3_errmsg(db));
			return false;
		}

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
	for (int i = 1; i < argc; i++)
	{
		if (!strncmp(argv[i], "-db=", 4))
		{
			db = argv[i]+4;
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
	if (!tar || !db)
	{
		fprintf(stderr, "usage: create_db -tar=<path> -db=<path>\n");
		return 1;
	}

	TarGzParser p;
	if (!p.initialize(db))
		return 1;

	int f = open(tar, O_RDONLY);
	if (f < 0)
	{
		perror("open");
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
