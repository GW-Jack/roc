// The COFF build-time boundary must keep both ordinary strong definitions and
// LLVM/MSVC COMDAT constants private to the shim object.
__declspec(selectany) const int compiler_private_constant = 42;
int compiler_private_helper(void) { return compiler_private_constant; }
void *roc_shim_get_ops(void) { return (void *)&compiler_private_helper; }
void roc_entrypoint(void) {}
void roc_shim_default_main(void) {}
// A `Tasks` platform's host drives its tasks through these shim exports.
unsigned roc_task_resume(void *task) { (void)task; return 1; }
void roc_task_wake(void *task) { (void)task; }
void roc_task_free(void *task) { (void)task; }
void roc_builtins_task_cancel(void *task, void (*abort)(void *)) { (void)task; (void)abort; }
