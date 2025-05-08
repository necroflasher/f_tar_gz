module f_tar_gz.zlib_state;

import core.stdc.stdio;
import etc.c.zlib;

// The totals maintained by zlib are too short on platforms with 32-bit c_long.
// Duplicate their functionality using ulong on such platforms.
static if (
	z_stream.total_in.sizeof < ulong.sizeof ||
	z_stream.total_out.sizeof < ulong.sizeof)
{
	version = longTotals;
}

// From the D runtime.
version (D_BetterC)
private int inflateInit2(z_streamp strm, int windowBits)
{
	return inflateInit2_(strm, windowBits, zlibVersion(), z_stream.sizeof);
}

/**
 * Contains the state needed to resume decompression from an arbitrary point in
 * the stream.
 */
struct ZlibResumeData
{
	/**
	 * Current decompression dictionary. This contains the previous `dictLength`
	 * bytes of decompressed output.
	 */
	ubyte[32768] dictionary;

	/**
	 * Used length of `dictionary`.
	 */
	ushort dictLength;

	/**
	 * Yet-unused bits of the last byte that was fed as input to the
	 * decompressor. This is only used if `bitsLeft` is non-zero.
	 */
	ubyte lastByte;

	/**
	 * How many low bits of lastByte are yet to be used by the decompressor.
	 */
	ubyte bitsLeft;

	/**
	 * How many bytes of compressed input the decompressor has consumed.
	 * Alternatively, this can be thought of as the byte offset where the
	 * next data to decompress begins.
	 */
	ulong totalIn;

	/**
	 * How many bytes of decompressed output the decompressor has produced.
	 */
	ulong totalOut;
}

/**
 * Implements a zlib decompressor with the ability to save its state and resume
 * from the middle of a decompressed stream.
 * 
 * Limitations:
 *   - Resumed streams don't verify the checksum at the end of a zlib or gzip
 *     format stream. The checksum is normally used to detect streams that are
 *     corrupt. The footer in these streams won't be read by the decompressor
 *     and will be left as unused in the input buffer, so a user of the library
 *     could in theory verify it themselves provided that they calculated the
 *     appropriate checksum over the uncompressed data themselves.
 *   - In those gzip streams that contain multiple files, only the first file
 *     can be read. This matches the behavior of zlib's inflate API. This
 *     affects .gz files that were concatenated, but note that typical .tar.gz
 *     archives are not affected as they don't use this feature.
 *   - Streams in zlib format that require a user-supplied dictionary to
 *     decompress aren't supported. The API to do this simply isn't exposed.
 *   - Support for raw deflate streams without any headers or footers currently
 *     isn't implemented. It would require adding a new parameter to
 *     `initialize()`.
 * 
 * See_Also:
 *   - [zlib-state python package](https://pypi.org/project/zlib-state/)
 *   - zran.c example from the zlib library
 */
struct ZlibState
{
	z_stream zs;

	version (longTotals)
	{
		ulong longTotalIn;
		ulong longTotalOut;
	}

	/**
	 * Initialize a new decompressor.
	 * 
	 * The decompressor will be able to decompress data starting from the
	 * beginning of a compressed stream.
	 * 
	 * The stream to decompress can be in zlib or gzip format. Raw streams
	 * (i.e. those without any headers or footers) currently aren't supported.
	 * 
	 * Returns:
	 *   true on success, false on failure.
	 */
	bool initialize()
	{
		// 32: Add for automatic zlib and gzip header decoding.
		if (int err = inflateInit2(&zs, 32))
		{
			fprintf(stderr, "%s: inflateInit: %s\n", __FUNCTION__.ptr, zError(err));
			return false;
		}

		return true;
	}

	/**
	 * Initialize a decompressor from the given resume data.
	 * 
	 * The decompressor will be able to decompress data starting from byte
	 * offset `resume.totalIn` in the same stream as the decompressor that
	 * created the resume data. The output will begin at byte offset
	 * `resume.totalOut` in the uncompressed data.
	 * 
	 * Params:
	 *   resume = The resume data from an earlier call to `getState()`.
	 * Returns:
	 *   true on success, false if an error occurred or the resume data is
	 *   invalid.
	 */
	bool initialize(ref const(ZlibResumeData) resume)
	{
		if (
			resume.dictLength > resume.dictionary.length ||
			resume.bitsLeft > 7 ||
			!resume.bitsLeft && resume.lastByte ||
			!resume.totalIn)
		{
			fprintf(stderr, "%s: invalid resume data\n", __FUNCTION__.ptr);
			return false;
		}

		// -15: Maximum window bits. Negate for raw data, meaning it has no
		// headers.
		if (int err = inflateInit2(&zs, -15))
		{
			fprintf(stderr, "%s: inflateInit: %s\n", __FUNCTION__.ptr, zError(err));
			return false;
		}

		if (int err = inflatePrime(&zs, resume.bitsLeft, resume.lastByte))
		{
			fprintf(stderr, "%s: inflatePrime: %s\n", __FUNCTION__.ptr, zError(err));
			inflateEnd(&zs);
			return false;
		}

		if (int err = inflateSetDictionary(&zs, resume.dictionary.ptr, resume.dictLength))
		{
			fprintf(stderr, "%s: inflateSetDictionary: %s\n", __FUNCTION__.ptr, zError(err));
			inflateEnd(&zs);
			return false;
		}

		version (longTotals)
		{
			// The fields in zs are unused with this version identifier.
			longTotalIn = resume.totalIn;
			longTotalOut = resume.totalOut;
		}
		else
		{
			zs.total_in = resume.totalIn;
			zs.total_out = resume.totalOut;
		}

		return true;
	}

	/**
	 * Get the resume data from the current state of the decompressor.
	 * 
	 * Resume data can be created when the decompressor is at a zlib block
	 * boundary. It's recommended to call this function inside the callback
	 * passed to `feed()` because it's called each time there's such a boundary.
	 * 
	 * The resume data can be used to initialize a new decompressor that behaves
	 * like a copy of the current one. The new decompressor will be able to
	 * decompress data starting from byte offset `totalIn` (i.e. the current
	 * offset) in the input stream, producing output starting at byte offset
	 * `totalOut` in the uncompressed file.
	 * 
	 * Note: This function assumes that the input buffer pointer that was
	 * previously passed to `feed` is still valid and contains the same data as
	 * when `feed` was called.
	 * 
	 * Params:
	 *   resume = Pointer to the struct to fill. If this is null, the function
	 *            will only check if resume can be created at the current
	 *            position in the stream.
	 * Returns:
	 *   true on success, false if an error occurred or resume can't be created
	 *   at the current position.
	 * 
	 * Examples:
	 * ---
	 * //ZlibState zs;
	 * // This callback passed to feed() creates a save every 4 MiB of input.
	 * enum ulong saveIntervalBytes = 4*1024*1024;
	 * ZlibResumeData[] saves;
	 * ulong lastSaveBlock;
	 * scope cb = (scope ubyte[] udata)
	 * {
	 *     ZlibResumeData resume = void;
	 *     // Divide the input into "blocks" by the save interval. We want to
	 *     // create one save in each block.
	 *     ulong currentBlock = (zs.totalIn / saveIntervalBytes);
	 *     // If we're in a new block since the last save point was created, and
	 *     // we can get a new save point at this position...
	 *     if (currentBlock != lastSaveBlock && zs.getState(&resume))
	 *     {
	 *         saves ~= resume;
	 *         lastSaveBlock = currentBlock;
	 *     }
	 *     return true;
	 * };
	 * ---
	 */
	bool getState(ZlibResumeData* resume)
	{
		// Check if we're either at "the end of a header or a non-last deflate
		// block." (zran.c)
		if ((zs.data_type & 0xc0) != 0x80)
			return false;

		// This is accessed below, must be a valid pointer.
		assert(zs.next_in);

		// Caller only wants to know if we can get the state?
		if (!resume)
			return true;

		uint dictLength = resume.dictionary.length;
		if (int err = inflateGetDictionary(&zs, resume.dictionary.ptr, &dictLength))
		{
			fprintf(stderr, "%s: inflateGetDictionary: %s\n", __FUNCTION__.ptr, zError(err));
			return false;
		}
		assert(dictLength <= resume.dictionary.length);

		ubyte bitsLeft = (zs.data_type & 0x7);

		resume.dictionary[dictLength..$] = 0;
		resume.dictLength = cast(ushort)dictLength;
		resume.lastByte = (bitsLeft) ? (zs.next_in[-1] >> (8 - bitsLeft)) : 0;
		resume.bitsLeft = bitsLeft;
		version (longTotals)
		{
			resume.totalIn = longTotalIn;
			resume.totalOut = longTotalOut;
		}
		else
		{
			resume.totalIn = zs.total_in;
			resume.totalOut = zs.total_out;
		}

		return true;
	}

	/**
	 * Deinitialize the zlib state.
	 * 
	 * This frees the internal state of the zlib decompressor.
	 * 
	 * The function is safe to call more than once.
	 */
	void deinitialize()
	{
		if (int err = inflateEnd(&zs))
		{
			fprintf(stderr, "%s: inflateEnd: %s\n", __FUNCTION__.ptr, zError(err));
		}
	}

	/**
	 * How many bytes of compressed data the decompressor has consumed so far.
	 * 
	 * This value is purely informational and has no effect on decompression,
	 * but note that the value is copied to the resume data by `getState()`.
	 * 
	 * If the total size of the compressed stream is known, this can be used to
	 * estimate progress.
	 * 
	 * Examples:
	 * ---
	 * //ulong totalSize;
	 * printf("Progress: %.02f%%\n", (double(zs.totalIn) / totalSize) * 100.0);
	 * ---
	 */
	ref ulong totalIn()
	{
		version (longTotals)
			return longTotalIn;
		else
			return zs.total_in;
	}

	/**
	 * How many bytes of uncompressed data the decompressor has produced so far.
	 * 
	 * This value is purely informational and has no effect on decompression,
	 * but note that the value is copied to the resume data by `getState()`.
	 * 
	 * In the callback passed to `feed()`, this is the uncompressed byte offset
	 * of the **end** of the buffer passed to the callback. To get the byte
	 * offset of its beginning, subtract the buffer's length from this value.
	 * 
	 * Examples:
	 * ---
	 * // Callback passed to feed().
	 * scope cb = (scope ubyte[] ubuf)
	 * {
	 *     ulong start = (zs.totalOut - ubuf.length);
	 *     ulong end = zs.totalOut;
	 *     printf("Got slice 'udata[%llu..%llu]' of the uncompressed file\n", start, end);
	 *     return true;
	 * };
	 * ---
	 */
	ref ulong totalOut()
	{
		version (longTotals)
			return longTotalOut;
		else
			return zs.total_out;
	}

	/**
	 * Feed data to the decompressor.
	 * 
	 * Params:
	 *   inbuf  = Input slice to read compressed data from. The slice will be
	 *            updated to skip data that has been decompressed from its
	 *            beginning. If the decompressor is expecting more data after
	 *            this call to continue decompression, the slice's pointer will
	 *            be set to null.
	 *   outbuf = Output buffer to temporarily store decompressed data in.
	 *            Slices from this will be passed to the provided callback.
	 *   cb     = Callback to receive decompressed data. Should return true on
	 *            success (continue decompressing) or false to make this
	 *            function return early. The callback can be called zero or more
	 *            times.
	 * 
	 * Returns:
	 *   Generally, true on success and false on failure. There are four
	 *   different cases:
	 *   1. Success, finished: If the entire compressed stream has been
	 *      decompressed and there will be no more output, returns true. Note
	 *      that there might be data left in inbuf when this happens. If inbuf
	 *      is a chunk of a larger source (e.g. a file), then remember that the
	 *      source might also have data remaining.
	 *   2. Success, more data needed: If all of the given input buffer has been
	 *      decompressed but the decompressor is still expecting more data,
	 *      returns true and assigns null to inbuf. The caller can detect this
	 *      by checking if the slice's pointer has become null.
	 *   3. Failure, decompression error: If an error occurred while
	 *      decompressing, returns false.
	 *   4. Failure, callback error: If the callback returned false, this
	 *      function also returns false. If decompression ended early, then
	 *      inbuf will contain any remaining data that wasn't yet decompressed.
	 *   To tell which of the two success cases a true return represents, check
	 *   whether the pointer of the input slice is null. It's null if more data
	 *   is needed to continue decompression, non-null if decompression is
	 *   finished and the slice contains any left-over input data that wasn't
	 *   used.
	 * 
	 * Examples:
	 * ---
	 * //ZlibState zs;
	 * for (;;)
	 * {
	 *     ubyte[] inbuf = read();
	 *     ubyte[16*1024] outbuf = void;
	 *     bool ok = zs.feed(inbuf, outbuf[], (scope ubyte[] data) {
	 *         write(data);
	 *         return true;
	 *     });
	 *     if (!ok)
	 *     {
	 *         printf("Something happened :(\n");
	 *         printf("Callback returned false or zlib had an error.\n");
	 *         // This case can also partially consume the input.
	 *         // Unlike in the success case, the pointer won't be set to null.
	 *         printf("%zu bytes of the input were left unused.\n", inbuf.length);
	 *         break;
	 *     }
	 *     if (inbuf.ptr)
	 *     {
	 *         printf("Decompression finished.\n");
	 *         printf("%zu bytes of the input were left unused.\n", inbuf.length);
	 *         // Note that the source being read from might also have unused bytes remaining.
	 *         break;
	 *     }
	 *     else
	 *     {
	 *         printf("OK: Entire input consumed, decompressor wants more data.\n");
	 *         continue;
	 *     }
	 * }
	 * ---
	 */
	bool feed(
		scope ref const(ubyte)[]                inbuf,
		scope ubyte[]                           outbuf,
		scope bool delegate(scope ubyte[] data) cb)
	{
		assert(inbuf.length);
		assert(outbuf.length);
		assert(cb);

		for (;;)
		{
			zs.next_out = outbuf.ptr;
			zs.avail_out = cast(uint)outbuf.length;

			if (outbuf.length > uint.max)
				zs.avail_out = uint.max;

			zs.next_in = inbuf.ptr;
			zs.avail_in = cast(uint)inbuf.length;

			if (inbuf.length > uint.max)
				zs.avail_in = uint.max;

			int err = inflate(&zs, /* flush */ Z_BLOCK);

			size_t inlen = (zs.next_in - inbuf.ptr);
			size_t outlen = (zs.next_out - outbuf.ptr);

			version (longTotals)
			{
				longTotalIn += inlen;
				longTotalOut += outlen;
			}

			inbuf = inbuf[inlen..$];

			if (!inbuf.length && err == Z_OK)
				inbuf = null;

			// Cancelled?
			// Skip the call if we made no progress (probably had an error.)
			if ((inlen || outlen) && !cb(outbuf[0..outlen]))
				return false;

			// Error?
			if (err != Z_OK && err != Z_STREAM_END)
			{
				fprintf(stderr, "%s: inflate: %s\n", __FUNCTION__.ptr, zError(err));
				return false;
			}

			// End of output?
			if (err == Z_STREAM_END)
			{
				// Note: There might still be a zlib or gzip footer in the file
				// being decompressed. This might leave some unused bytes in the
				// buffer.
				return true;
			}

			// End of input? (need more data)
			if (!inbuf.length)
				return true;

			// The call made some progress in either direction.
			assert(inlen || outlen);
		}
	}
}

/*
 * Basic test.
 */
unittest
{
	// Print some stuff.
	enum PRINT = 0;

	static ubyte[] createUncompressedData()
	{
		enum byteLength = 64*1024;
		ulong[] numbers;
		foreach (i; 0..byteLength/ulong.sizeof)
		{
			numbers ~= i;
		}
		return cast(ubyte[])numbers;
	}

	static ubyte[] compressData(const(ubyte)[] udata)
	{
		ubyte[] cdata;

		z_stream zs;

		if (deflateInit2(
			&zs,
			/* level      */ Z_BEST_SPEED,
			/* method     */ Z_DEFLATED,
			/* windowBits */ 15 + 16,
			/* memLevel   */ 9,
			/* strategy   */ Z_HUFFMAN_ONLY))
		{
			assert(0);
		}

		const(ubyte)[] rem = udata;
		ubyte[16*1024] outbuf = void;
		enum chunkMax = 32*1024;
		for (;;)
		{
			zs.next_out = outbuf.ptr;
			zs.avail_out = outbuf.length;
			zs.next_in = rem.ptr;
			zs.avail_in = cast(uint)rem.length;
			if (zs.avail_in > chunkMax)
				zs.avail_in = chunkMax;
			// Use sync flush to get more save points.
			//int err = deflate(&zs, (rem.length) ? Z_NO_FLUSH : Z_FINISH);
			int err = deflate(&zs, (rem.length) ? Z_SYNC_FLUSH : Z_FINISH);
			if (err && err != Z_STREAM_END)
				assert(0);
			size_t inlen = (zs.next_in - rem.ptr);
			size_t outlen = (zs.next_out - outbuf.ptr);
			cdata ~= outbuf[0..outlen];
			if (!inlen && !outlen)
				break;
			rem = rem[inlen..$];
		}

		if (deflateEnd(&zs))
			assert(0);

		return cdata;
	}

	static struct SavePoint
	{
		ZlibResumeData resume;
		uint crc;
	}

	static struct FirstPassData
	{
		SavePoint[] savePoints;
		SavePoint[ulong] savePointsByInputPos;
		uint finalCrc;
		ulong finalTotalIn;
		ulong finalTotalOut;
	}

	/**
	 * Do a first pass through the compressed data.
	 * 
	 * This collects all save points and saves the crc and total sizes.
	 */
	static FirstPassData doFirstPass(const(ubyte)[] udata, const(ubyte)[] cdata)
	{
		FirstPassData fpd;
		ZlibState zs;

		if (!zs.initialize())
			assert(0);

		uint crc;
		scope cb = (scope ubyte[] decomp)
		{
			crc = crc32_z(crc, decomp.ptr, decomp.length);

			SavePoint save = void;
			save.crc = crc;

			if (zs.getState(&save.resume))
			{
				assert(save.resume.totalIn !in fpd.savePointsByInputPos);
				fpd.savePoints ~= save;
				fpd.savePointsByInputPos[save.resume.totalIn] = save;
				if (PRINT)
				{
					printf("create save point:\n");
					printf("  dictLength=%u\n", save.resume.dictLength);
					printf("  lastByte=0x%02hhx\n", save.resume.lastByte);
					printf("  bitsLeft=%u\n", save.resume.bitsLeft);
					printf("  totalIn=%llu\n", save.resume.totalIn);
					printf("  totalOut=%llu\n", save.resume.totalOut);
				}
			}

			// Original data matches.
			const(ubyte)[] orig = udata[cast(size_t)zs.totalOut-decomp.length..cast(size_t)zs.totalOut];
			assert(orig == decomp);

			return true;
		};

		const(ubyte)[] tmp = cdata;
		ubyte[16*1024] tmpout;
		bool ok = zs.feed(tmp, tmpout[], cb);
		if (!ok)
			assert(0);
		if (!tmp.ptr) // expecting more data
			assert(0);
		if (tmp.length) // has unused data
			assert(0);

		fpd.finalCrc = crc;
		fpd.finalTotalIn = zs.totalIn;
		fpd.finalTotalOut = zs.totalOut;

		zs.deinitialize();

		return fpd;
	}

	/**
	 * Test all save points in the first pass data.
	 */
	static void testSavePoints(const FirstPassData fpd, const(ubyte)[] udata, const(ubyte)[] cdata)
	{
		foreach (ref const(SavePoint) sp; fpd.savePoints)
		{
			size_t idx = (&sp - fpd.savePoints.ptr);

			//~ printf("test sp %zu/%zu - totalIn=%llu totalOut=%llu\n", idx+1, fpd.savePoints.length, sp.resume.totalIn, sp.resume.totalOut);

			ZlibState zs;

			if (!zs.initialize(sp.resume))
				assert(0);

			uint crc = sp.crc;
			size_t savePointsTested;
			scope cb = (scope ubyte[] ubuf)
			{
				crc = crc32_z(crc, ubuf.ptr, ubuf.length);

				ZlibResumeData myResume = void;
				if (zs.getState(&myResume))
				{
					const(SavePoint)* sp = (zs.totalIn in fpd.savePointsByInputPos);
					assert(sp);
					assert(sp.crc == crc);
					assert(sp.resume.dictionary == myResume.dictionary);
					assert(sp.resume.dictLength == myResume.dictLength);
					assert(sp.resume.lastByte == myResume.lastByte);
					assert(sp.resume.totalOut == myResume.totalOut);
					assert(sp.resume.bitsLeft == myResume.bitsLeft);
					assert(sp.resume.totalIn == myResume.totalIn);
					savePointsTested++;
				}
				else
				{
					// No save point here.
					assert(zs.totalIn !in fpd.savePointsByInputPos);
				}

				// Original data matches.
				const(ubyte)[] orig = udata[cast(size_t)zs.totalOut-ubuf.length..cast(size_t)zs.totalOut];
				assert(orig == ubuf);

				return true;
			};

			const(ubyte)[] inbuf = cdata[cast(size_t)sp.resume.totalIn..$];
			ubyte[16*1024] outbuf = void;
			bool ok = zs.feed(inbuf, outbuf[], cb);
			if (!ok)
				assert(0);
			if (!inbuf.ptr) // expecting more data
				assert(0);

			// The callback should've been able to get all the same save points.
			assert(savePointsTested == (fpd.savePoints.length-(idx+1)));

			if (zs.totalOut != fpd.finalTotalOut)
				assert(0);
			if (crc != fpd.finalCrc)
				assert(0);

			// The gzip footer is left in the buffer.
			assert(inbuf.length == 8);
			assert(inbuf == cdata[$-8..$]);

			zs.deinitialize();
		}
	}

	/**
	 * Check that there are enough save points for the test to be useful.
	 */
	static void checkDataAdequate(const FirstPassData fpd)
	{
		size_t numZeroBits;
		size_t numNonZeroBits;
		bool ok;
		foreach (ref const(SavePoint) sp; fpd.savePoints)
		{
			if (sp.resume.bitsLeft)
				numNonZeroBits++;
			else
				numZeroBits++;
			if (numZeroBits >= 3 && numNonZeroBits >= 3)
			{
				ok = true;
				break;
			}
		}
		if (!ok)
			assert(0, "too few save points");
	}

	ubyte[] udata = createUncompressedData();

	ubyte[] cdata = compressData(udata);

	FirstPassData fpd = doFirstPass(udata, cdata);

	checkDataAdequate(fpd);

	testSavePoints(fpd, udata, cdata);
}

/*
 * Test that we can create and use a save point beyond 4 GiB.
 * 
 * TODO: This test is too slow.
 */
static if (0)
unittest
{
	z_stream zsComp;
	ZlibState zsDecomp;
	ZlibState zsResume;
	bool zsResumeCreated;

	if (deflateInit2(
		&zsComp,
		/* level      */ Z_NO_COMPRESSION,
		/* method     */ Z_DEFLATED,
		/* windowBits */ 15 + 16,
		/* memLevel   */ 9,
		/* strategy   */ Z_HUFFMAN_ONLY))
	{
		assert(0);
	}

	zsDecomp.initialize();

	enum ulong bigNumber = uint.max;
	//enum ulong bigNumber = 1*1024*1024;

	const ubyte[128*1024] zeros;
	ubyte[128*1024] cdata;
	ubyte[128*1024] dcdata;
	ulong totalCompressed;
	bool wantCreateResume;
	bool wantFlushAndExit;
	bool decompReachedEnd;
	bool resumeReachedEnd;
	ulong resumeSkipBytes;
	for (;;)
	{
		zsComp.next_in = zeros.ptr;
		zsComp.avail_in = wantFlushAndExit ? 0 : zeros.length;
		zsComp.next_out = cdata.ptr;
		zsComp.avail_out = cdata.length;

		int err = deflate(&zsComp, wantFlushAndExit ? Z_FINISH : Z_NO_FLUSH);
		if (err && err != Z_STREAM_END)
			assert(0);

		size_t inlen = (zsComp.next_in - zeros.ptr);
		size_t outlen = (zsComp.next_out - cdata.ptr);

		totalCompressed += (zsComp.next_out - cdata.ptr);

		if (outlen)
		{
			const(ubyte)[] inbuf = cdata[0..outlen];
			ulong callOffset = zsDecomp.totalIn;
			bool ok = zsDecomp.feed(inbuf, dcdata[], (scope ubyte[] _) {
				ZlibResumeData resume = void;
				if (wantCreateResume && zsDecomp.getState(&resume))
				{
					if (!zsResume.initialize(resume))
						assert(0);
					assert(zsResume.totalIn == zsDecomp.totalIn);
					assert(zsResume.totalOut == zsDecomp.totalOut);
					wantCreateResume = false;
					zsResumeCreated = true;
					// The resume state needs to skip the amount of bytes that
					// this instance already processed before creating the
					// resume state.
					resumeSkipBytes = (zsDecomp.totalIn - callOffset);
				}
				return true;
			});
			if (!ok)
				assert(0);
			if (!inbuf.ptr)
			{
				// need more data
			}
			else
			{
				// no more
				assert(!inbuf.length); // no excess
				assert(!decompReachedEnd);
				decompReachedEnd = true;
			}
		}
		if (outlen && zsResumeCreated)
		{
			const(ubyte)[] inbuf = cdata[0..outlen];
			if (resumeSkipBytes)
			{
				ulong skip = resumeSkipBytes;
				if (skip > inbuf.length)
					skip = inbuf.length;
				inbuf = inbuf[cast(size_t)skip..$];
				resumeSkipBytes -= skip;
			}
			if (inbuf.length)
			{
				bool ok = zsResume.feed(inbuf, dcdata[], (scope ubyte[] udata) {
					if (udata.length)
						wantFlushAndExit = true;
					return true;
				});
				if (!ok)
					assert(0);
				if (!inbuf.ptr)
				{
					// need more data
				}
				else
				{
					// no more
					assert(inbuf.length == 8); // gzip footer
					assert(!resumeReachedEnd);
					resumeReachedEnd = true;
				}
			}
		}

		assert(zsDecomp.totalIn == totalCompressed);

		if (totalCompressed > bigNumber && !zsResumeCreated)
			wantCreateResume = true;

		if (wantFlushAndExit && !inlen && !outlen)
			break;
	}

	assert(decompReachedEnd);
	assert(resumeReachedEnd);

	assert(zsResume.totalIn == zsDecomp.totalIn-8); // gzip footer
	assert(zsResume.totalOut == zsDecomp.totalOut);

	zsDecomp.deinitialize();

	if (deflateEnd(&zsComp))
		assert(0);
}

unittest
{
	ZlibState zs;
	if (zs.getState(null))
		assert(0);
	if (!zs.initialize())
		assert(0);
	if (zs.getState(null))
		assert(0);
	zs.deinitialize();
}
