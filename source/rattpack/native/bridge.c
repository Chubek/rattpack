#include <git2.h>
#include <lzma.h>
#include <zlib.h>
#include <stdlib.h>
#include <stdio.h>
#include <string.h>
#include <limits.h>

/* Keep native object ownership entirely inside the C API boundary. */
int ratt_git_checkout(const char *url, const char *directory, const char *revision,
                      char *commit_hash, char *error, size_t error_size)
{
    git_repository *repository = NULL;
    git_object *object = NULL, *commit = NULL;
    int result;
    git_libgit2_init();
    result = git_clone(&repository, url, directory, NULL);
    if (!result) result = git_revparse_single(&object, repository, revision);
    if (!result) result = git_object_peel(&commit, object, GIT_OBJECT_COMMIT);
    if (!result) {
        git_checkout_options options = GIT_CHECKOUT_OPTIONS_INIT;
        options.checkout_strategy = GIT_CHECKOUT_FORCE;
        result = git_checkout_tree(repository, commit, &options);
    }
    if (!result) result = git_repository_set_head_detached(repository, git_object_id(commit));
    if (!result) git_oid_tostr(commit_hash, GIT_OID_SHA1_HEXSIZE + 1, git_object_id(commit));
    else {
        const git_error *last = git_error_last();
        snprintf(error, error_size, "%s", last ? last->message : "git operation failed");
    }
    git_object_free(commit);
    git_object_free(object);
    git_repository_free(repository);
    git_libgit2_shutdown();
    return result;
}

/* Decompress archives with a bounded allocation (1 GiB maximum). */
int ratt_decompress(const unsigned char *input, size_t input_size, int xz,
                    unsigned char **output, size_t *output_size)
{
    size_t capacity = input_size < 65536 ? 65536 : input_size;
    while (capacity <= ((size_t)1 << 30)) {
        unsigned char *buffer = malloc(capacity);
        if (!buffer) return -1;
        if (xz) {
            uint64_t limit = (uint64_t)1 << 30;
            size_t in_pos = 0, out_pos = 0;
            lzma_ret result = lzma_stream_buffer_decode(&limit, 0, NULL, input,
                &in_pos, input_size, buffer, &out_pos, capacity);
            if (result == LZMA_OK && in_pos == input_size) {
                *output = buffer; *output_size = out_pos; return 0;
            }
            free(buffer);
            if (result != LZMA_BUF_ERROR) return -2;
        } else {
            z_stream stream;
            memset(&stream, 0, sizeof(stream));
            if (input_size > UINT_MAX || capacity > UINT_MAX) { free(buffer); return -3; }
            stream.next_in = (Bytef *)input; stream.avail_in = (uInt)input_size;
            stream.next_out = buffer; stream.avail_out = (uInt)capacity;
            if (inflateInit2(&stream, 15 + 32) != Z_OK) { free(buffer); return -4; }
            int result = inflate(&stream, Z_FINISH);
            size_t size = stream.total_out;
            inflateEnd(&stream);
            if (result == Z_STREAM_END) { *output = buffer; *output_size = size; return 0; }
            free(buffer);
            if (result != Z_BUF_ERROR) return -5;
        }
        capacity *= 2;
    }
    return -6;
}

void ratt_native_free(void *pointer) { free(pointer); }
