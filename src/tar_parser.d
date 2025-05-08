module f_tar_gz.tar_parser;

import core.stdc.stdio;

struct CurrentFileInfo
{
	const(char)* filename;
	ulong        filesize;
	ulong        headerOffset;
	ulong        dataBeginOffset;
	ulong        dataEndOffset;
}

struct TarParser
{
	TarParserCallbacks cb;
	CurrentFileInfo    current;

	private HeaderBuffer header;
	private ulong        readPos;
	private ulong        curFileBegin;
	private ulong        curFileEnd;

	bool inFile()
	{
		return readPos < curFileEnd;
	}

	bool putEndOfFile()
	{
		if (header.used % 512)
		{
			fprintf(stderr, "%s: header incomplete\n", __FUNCTION__.ptr);
			return false;
		}

		if (inFile)
		{
			fprintf(stderr, "%s: file incomplete\n", __FUNCTION__.ptr);
			return false;
		}

		return true;
	}

	bool put(scope const(ubyte)[] buf)
	{
		while (buf.length)
		{
			if (inFile)
			{
				size_t amount = saturatingCastToSize(curFileEnd - readPos);
				if (amount > buf.length)
					amount = buf.length;

				ulong fileOffset = readPos-curFileBegin;

				bool ok = cb.fileData(buf[0..amount], fileOffset);
				buf = buf[amount..$];
				readPos += amount;

				if (!inFile)
				{
					if (ok && !cb.fileEnd())
						ok = false;

					header.clear();
				}

				if (!ok)
					return false;

				continue;
			}

			if (readPos % 512)
			{
				size_t amount = 512 - cast(size_t)(readPos % 512);
				if (amount > buf.length)
					amount = buf.length;

				buf = buf[amount..$];
				readPos += amount;

				continue;
			}

			header.appendFromRef(buf);
			if (!header.isFull)
			{
				// just need some more data to complete a header
				assert(!buf.length);
				break;
			}

			readPos += 512;
			ubyte typeflag = header.data[156];
			if (typeflag == '0')
			{
				// file
				ulong filesize;

				if (!verifyHeaderChecksum(header.data))
				{
					fprintf(stderr, "%s: bad checksum\n", __FUNCTION__.ptr);
					return false;
				}
				if (!parseHeaderFilesize(header.data[124..136], &filesize))
				{
					fprintf(stderr, "%s: bad filesize\n", __FUNCTION__.ptr);
					return false;
				}

				curFileBegin = readPos;
				curFileEnd = readPos + filesize;

				current.filename = cast(char*)&header.data[0];
				current.filesize = filesize;
				current.headerOffset = readPos - 512;
				current.dataBeginOffset = readPos;
				current.dataEndOffset = curFileEnd;

				if (!cb.fileBegin())
					return false;
			}
			else if (typeflag == '5')
			{
				// directory
				if (!verifyHeaderChecksum(header.data))
				{
					fprintf(stderr, "%s: bad checksum\n", __FUNCTION__.ptr);
					return false;
				}
				header.clear();
			}
			else if (typeflag == 0)
			{
				// zero record (padding)
				if (!verifyZeroRecord(header.data))
				{
					fprintf(stderr, "%s: invalid zero record\n", __FUNCTION__.ptr);
					return false;
				}
				header.clear();
			}
			else
			{
				fprintf(stderr, "%s: unknown record type\n", __FUNCTION__.ptr);
				return false;
			}
		}

		return true;
	}
}

struct TarParserCallbacks
{
	bool delegate() fileBegin;
	bool delegate(scope const(ubyte)[] buf, ulong offset) fileData;
	bool delegate() fileEnd;
}

private:

struct HeaderBuffer
{
	ubyte[512] data;
	ubyte      nul;
	size_t     used;

	void appendFromRef(ref scope const(ubyte)[] s)
	{
		size_t amount = data.length-used;
		if (amount > s.length)
			amount = s.length;

		data[used..used+amount] = s[0..amount];

		s = s[amount..$];

		used += amount;
	}

	bool isFull()
	{
		return used == data.length;
	}

	void clear()
	{
		used = 0;
	}
}

bool parseHeaderFilesize(ubyte[] str, ulong* filesizeOut)
{
	ulong rv;
	foreach (b; str)
	{
		if (!b) break;
		if (!(b >= '0' && b <= '7')) return false;
		rv = rv*8 + b-'0';
	}
	*filesizeOut = rv;
	return true;
}

size_t saturatingCastToSize(ulong v)
{
	if (v > cast(ulong)size_t.max)
		return size_t.max;
	else
		return cast(size_t)v;
}

bool verifyHeaderChecksum(ref const(ubyte)[512] header)
{
	/*
	 * 0..148    header data
	 * 148..156  checksum in null-terinated octal
	 * 156..512  header data
	 * 
	 * checksum is sum of header data mod 256
	 */

	uint sum;
	foreach (b; header[0..148]) sum += b;
	foreach (b; header[156..512]) sum += b;

	uint exp;
	foreach (b; header[148..156])
	{
		if (b)
		{
			if (b >= '0' && b <= '7')
				exp = exp*8 + b-'0';
			else
				return false;
		}
		else
		{
			break;
		}
	}

	return sum % 256 == exp % 256;
}

bool verifyZeroRecord(ref const(ubyte)[512] header)
{
	foreach (b; header) if (b) return false;
	return true;
}
