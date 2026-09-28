#ifndef TC_CONTROLLER_H
#define TC_CONTROLLER_H

#include "tc_input.h"

/* SDL3 controller backend. Call on the main thread, serialized with other tc_input calls.
 * Poll before tc_input_publish. Returns 1 with a controller, 0 without one,
 * or -1 for an initialization/input error. Missing controls and disconnected devices release
 * their buttons and stick axes; action bindings and physical keyboard state are preserved.
 * The host must call tc_input_release_all when losing application focus.
 */
int tc_controller_poll(tc_input *input);
/* Release SDL3 devices/subsystems on the main thread at host shutdown. */
void tc_controller_close(void);

#endif
