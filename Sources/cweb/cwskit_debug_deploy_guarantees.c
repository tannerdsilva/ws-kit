#include "cwskit_debug_deploy_guarantees.h"
#include <stdatomic.h>

bool _cwskit_can_issue_continuation(const _cwskit_datachainpair_deploy_guarantees_ptr_t deploys) {
	if (atomic_load_explicit(&deploys->is_continuation_issued, memory_order_acquire) == false) {
		atomic_store_explicit(&deploys->is_continuation_issued, true, memory_order_release);
		return true;
	} else {
		return false;
	}
}
bool _cwskit_can_issue_consumer(const _cwskit_datachainpair_deploy_guarantees_ptr_t deploys) {
	if (atomic_load_explicit(&deploys->is_consumer_issued, memory_order_acquire) == false) {
		atomic_store_explicit(&deploys->is_consumer_issued, true, memory_order_release);
		return true;
	} else {
		return false;
	}
}
