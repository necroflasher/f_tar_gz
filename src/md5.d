module f_tar_gz.md5;

import core.stdc.stdio;

struct Md5
{
	MD5_CTX   ctx;
	ubyte[16] hash;
	char[33]  str = 0;

	bool initialize()
	{
		if (!MD5_Init(&ctx))
		{
			fprintf(stderr, "%s: MD5_Init failed\n", __FUNCTION__.ptr);
			return false;
		}

		return true;
	}

	bool put(const(ubyte)[] data)
	{
		if (!MD5_Update(&ctx, data.ptr, data.length))
		{
			fprintf(stderr, "%s: MD5_Update failed\n", __FUNCTION__.ptr);
			return false;
		}

		return true;
	}

	bool finalize()
	{
		if (!MD5_Final(&hash[0], &ctx))
		{
			fprintf(stderr, "%s: MD5_Final failed\n", __FUNCTION__.ptr);
			return false;
		}

		enum alef = "0123456789abcdef";
		foreach (i, b; hash)
		{
			str[i*2+0] = alef[b>>4];
			str[i*2+1] = alef[b&15];
		}

		return true;
	}
}

private:

struct MD5_CTX
{
	uint a, b, c, d;
	uint nl, nh;
	uint[16] data;
	uint num;
}

extern(C) int MD5_Init(MD5_CTX* c);
extern(C) int MD5_Update(MD5_CTX* c, const(void)* data, size_t len);
extern(C) int MD5_Final(ubyte* md, MD5_CTX* c);
