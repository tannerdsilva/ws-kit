#ifndef _WSKIT_DEBUG_DEPLOY_GUARANTEES
#define _WSKIT_DEBUG_DEPLOY_GUARANTEES

#include <stdbool.h>

// this is a struct that helps guard against improper deployment of continuations and consumers. this is optional and as such, is detached from the main datachain structure.
typedef struct _cwskit_datachainpair_deploy_guarantees {
	/// atomic boolean flag indicating whether a continuation has been issued for the chain.
	_Atomic bool is_continuation_issued;
	/// atomic boolean flag indicating whether a consumer has been issued for the chain.
	_Atomic bool is_consumer_issued;
} _cwskit_datachainpair_deploy_guarantees_t;

typedef _cwskit_datachainpair_deploy_guarantees_t*_Nonnull _cwskit_datachainpair_deploy_guarantees_ptr_t;

/// a function that should be called before a continuation is issued to the chain.
/// @return true if a continuation can be issued; false if a continuation is already issued.
bool _cwskit_can_issue_continuation(const _cwskit_datachainpair_deploy_guarantees_ptr_t deploys);

/// a function that should be called before a consumer is issued to the chain.
/// @return true if a consumer can be issued; false if a consumer is already issued.
bool _cwskit_can_issue_consumer(const _cwskit_datachainpair_deploy_guarantees_ptr_t deploys);

#endif