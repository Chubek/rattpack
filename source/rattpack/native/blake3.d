module rattpack.native.blake3;

extern (C) @nogc nothrow
{
    struct Blake3Chunk
    {
        uint[8] cv;
        ulong counter;
        ubyte[64] buffer;
        ubyte length;
        ubyte blocks;
        ubyte flags;
    }

    struct Blake3Hasher
    {
        uint[8] key;
        Blake3Chunk chunk;
        ubyte stackLength;
        ubyte[55 * 32] stack;
    }

    void blake3_hasher_init(Blake3Hasher*);
    void blake3_hasher_update(Blake3Hasher*, const(void)*, size_t);
    void blake3_hasher_finalize(const(Blake3Hasher)*, ubyte*, size_t);
}
