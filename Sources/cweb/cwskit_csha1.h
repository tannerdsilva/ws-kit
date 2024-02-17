// (c) tanner silva 2024. all rights reserved.
// material for this file was sourced from the apple/swift-nio project.

#ifndef _CRYPTO_SHA1_H_
#define _CRYPTO_SHA1_H_
#include <stdint.h>
#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

struct sha1_ctxt {
	union {
		uint8_t		b8[20];
		uint32_t	b32[5];
	} h;
	union {
		uint8_t		b8[8];
		uint64_t	b64[1];
	} c;
	union {
		uint8_t		b8[64];
		uint32_t	b32[16];
	} m;
	uint8_t	count;
};
typedef struct sha1_ctxt SHA1_CTX;

#define	SHA1_RESULTLEN	(160/8)

#ifdef __cplusplus
#define __min_size(x)	(x)
#else
#define __min_size(x)	static (x)
#endif

extern void wskit_sha1_init(struct sha1_ctxt *);
extern void wskit_sha1_pad(struct sha1_ctxt *);
extern void wskit_sha1_loop(struct sha1_ctxt *, const uint8_t *, size_t);
extern void wskit_sha1_result(struct sha1_ctxt *, char[__min_size(SHA1_RESULTLEN)]);

/* compatibilty with other SHA1 source codes */
#define SHA1Init(x)		wskit_sha1_init((x))
#define SHA1Update(x, y, z)	wskit_sha1_loop((x), (y), (z))
#define SHA1Final(x, y)		wskit_sha1_result((y), (x))

#ifdef __cplusplus
} /* extern "C" */
#endif

#endif /*_CRYPTO_SHA1_H_*/