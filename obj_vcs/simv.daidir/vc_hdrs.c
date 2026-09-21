#ifndef _GNU_SOURCE
#define _GNU_SOURCE
#endif
#include <stdio.h>
#include <dlfcn.h>
#include "svdpi.h"

#ifdef __cplusplus
extern "C" {
#endif

/* VCS error reporting routine */
extern void vcsMsgReport1(const char *, const char *, int, void *, void*, const char *);

#ifndef _VC_TYPES_
#define _VC_TYPES_
/* common definitions shared with DirectC.h */

typedef unsigned int U;
typedef unsigned char UB;
typedef unsigned char scalar;
typedef struct { U c; U d;} vec32;

#define scalar_0 0
#define scalar_1 1
#define scalar_z 2
#define scalar_x 3

extern long long int ConvUP2LLI(U* a);
extern void ConvLLI2UP(long long int a1, U* a2);
extern long long int GetLLIresult();
extern void StoreLLIresult(const unsigned int* data);
typedef struct VeriC_Descriptor *vc_handle;

#ifndef SV_3_COMPATIBILITY
#define SV_STRING const char*
#else
#define SV_STRING char*
#endif

#endif /* _VC_TYPES_ */

#ifndef __VCS_IMPORT_DPI_STUB_gm_init
#define __VCS_IMPORT_DPI_STUB_gm_init
__attribute__((weak)) void gm_init(/* INPUT */const char* A_1)
{
    static int _vcs_dpi_stub_initialized_ = 0;
    static void (*_vcs_dpi_fp_)(/* INPUT */const char* A_1) = NULL;
    if (!_vcs_dpi_stub_initialized_) {
        _vcs_dpi_fp_ = (void (*)(const char* A_1)) dlsym(RTLD_NEXT, "gm_init");
        _vcs_dpi_stub_initialized_ = 1;
    }
    if (_vcs_dpi_fp_) {
        _vcs_dpi_fp_(A_1);
    } else {
        const char *fileName;
        int lineNumber;
        svGetCallerInfo(&fileName, &lineNumber);
        vcsMsgReport1("DPI-DIFNF", fileName, lineNumber, 0, 0, "gm_init");
    }
}
#endif /* __VCS_IMPORT_DPI_STUB_gm_init */

#ifndef __VCS_IMPORT_DPI_STUB_gm_check_step
#define __VCS_IMPORT_DPI_STUB_gm_check_step
__attribute__((weak)) int gm_check_step(/* INPUT */int A_1, /* INPUT */int A_2, /* INPUT */int A_3, /* INPUT */int A_4, /* INPUT */int A_5, /* INPUT */int A_6)
{
    static int _vcs_dpi_stub_initialized_ = 0;
    static int (*_vcs_dpi_fp_)(/* INPUT */int A_1, /* INPUT */int A_2, /* INPUT */int A_3, /* INPUT */int A_4, /* INPUT */int A_5, /* INPUT */int A_6) = NULL;
    if (!_vcs_dpi_stub_initialized_) {
        _vcs_dpi_fp_ = (int (*)(int A_1, int A_2, int A_3, int A_4, int A_5, int A_6)) dlsym(RTLD_NEXT, "gm_check_step");
        _vcs_dpi_stub_initialized_ = 1;
    }
    if (_vcs_dpi_fp_) {
        return _vcs_dpi_fp_(A_1, A_2, A_3, A_4, A_5, A_6);
    } else {
        const char *fileName;
        int lineNumber;
        svGetCallerInfo(&fileName, &lineNumber);
        vcsMsgReport1("DPI-DIFNF", fileName, lineNumber, 0, 0, "gm_check_step");
        return 0;
    }
}
#endif /* __VCS_IMPORT_DPI_STUB_gm_check_step */

#ifndef __VCS_IMPORT_DPI_STUB_gm_halted
#define __VCS_IMPORT_DPI_STUB_gm_halted
__attribute__((weak)) int gm_halted()
{
    static int _vcs_dpi_stub_initialized_ = 0;
    static int (*_vcs_dpi_fp_)() = NULL;
    if (!_vcs_dpi_stub_initialized_) {
        _vcs_dpi_fp_ = (int (*)()) dlsym(RTLD_NEXT, "gm_halted");
        _vcs_dpi_stub_initialized_ = 1;
    }
    if (_vcs_dpi_fp_) {
        return _vcs_dpi_fp_();
    } else {
        const char *fileName;
        int lineNumber;
        svGetCallerInfo(&fileName, &lineNumber);
        vcsMsgReport1("DPI-DIFNF", fileName, lineNumber, 0, 0, "gm_halted");
        return 0;
    }
}
#endif /* __VCS_IMPORT_DPI_STUB_gm_halted */

#ifndef __VCS_IMPORT_DPI_STUB_gm_exit_code
#define __VCS_IMPORT_DPI_STUB_gm_exit_code
__attribute__((weak)) int gm_exit_code()
{
    static int _vcs_dpi_stub_initialized_ = 0;
    static int (*_vcs_dpi_fp_)() = NULL;
    if (!_vcs_dpi_stub_initialized_) {
        _vcs_dpi_fp_ = (int (*)()) dlsym(RTLD_NEXT, "gm_exit_code");
        _vcs_dpi_stub_initialized_ = 1;
    }
    if (_vcs_dpi_fp_) {
        return _vcs_dpi_fp_();
    } else {
        const char *fileName;
        int lineNumber;
        svGetCallerInfo(&fileName, &lineNumber);
        vcsMsgReport1("DPI-DIFNF", fileName, lineNumber, 0, 0, "gm_exit_code");
        return 0;
    }
}
#endif /* __VCS_IMPORT_DPI_STUB_gm_exit_code */

#ifndef __VCS_IMPORT_DPI_STUB_gm_set_cycle
#define __VCS_IMPORT_DPI_STUB_gm_set_cycle
__attribute__((weak)) void gm_set_cycle(/* INPUT */int A_1)
{
    static int _vcs_dpi_stub_initialized_ = 0;
    static void (*_vcs_dpi_fp_)(/* INPUT */int A_1) = NULL;
    if (!_vcs_dpi_stub_initialized_) {
        _vcs_dpi_fp_ = (void (*)(int A_1)) dlsym(RTLD_NEXT, "gm_set_cycle");
        _vcs_dpi_stub_initialized_ = 1;
    }
    if (_vcs_dpi_fp_) {
        _vcs_dpi_fp_(A_1);
    } else {
        const char *fileName;
        int lineNumber;
        svGetCallerInfo(&fileName, &lineNumber);
        vcsMsgReport1("DPI-DIFNF", fileName, lineNumber, 0, 0, "gm_set_cycle");
    }
}
#endif /* __VCS_IMPORT_DPI_STUB_gm_set_cycle */

#ifndef __VCS_IMPORT_DPI_STUB_gm_set_timer
#define __VCS_IMPORT_DPI_STUB_gm_set_timer
__attribute__((weak)) void gm_set_timer(/* INPUT */int A_1, /* INPUT */int A_2)
{
    static int _vcs_dpi_stub_initialized_ = 0;
    static void (*_vcs_dpi_fp_)(/* INPUT */int A_1, /* INPUT */int A_2) = NULL;
    if (!_vcs_dpi_stub_initialized_) {
        _vcs_dpi_fp_ = (void (*)(int A_1, int A_2)) dlsym(RTLD_NEXT, "gm_set_timer");
        _vcs_dpi_stub_initialized_ = 1;
    }
    if (_vcs_dpi_fp_) {
        _vcs_dpi_fp_(A_1, A_2);
    } else {
        const char *fileName;
        int lineNumber;
        svGetCallerInfo(&fileName, &lineNumber);
        vcsMsgReport1("DPI-DIFNF", fileName, lineNumber, 0, 0, "gm_set_timer");
    }
}
#endif /* __VCS_IMPORT_DPI_STUB_gm_set_timer */

#ifndef __VCS_IMPORT_DPI_STUB_gm_set_irq
#define __VCS_IMPORT_DPI_STUB_gm_set_irq
__attribute__((weak)) void gm_set_irq(/* INPUT */int A_1)
{
    static int _vcs_dpi_stub_initialized_ = 0;
    static void (*_vcs_dpi_fp_)(/* INPUT */int A_1) = NULL;
    if (!_vcs_dpi_stub_initialized_) {
        _vcs_dpi_fp_ = (void (*)(int A_1)) dlsym(RTLD_NEXT, "gm_set_irq");
        _vcs_dpi_stub_initialized_ = 1;
    }
    if (_vcs_dpi_fp_) {
        _vcs_dpi_fp_(A_1);
    } else {
        const char *fileName;
        int lineNumber;
        svGetCallerInfo(&fileName, &lineNumber);
        vcsMsgReport1("DPI-DIFNF", fileName, lineNumber, 0, 0, "gm_set_irq");
    }
}
#endif /* __VCS_IMPORT_DPI_STUB_gm_set_irq */

#ifndef __VCS_IMPORT_DPI_STUB_gm_check_csr
#define __VCS_IMPORT_DPI_STUB_gm_check_csr
__attribute__((weak)) int gm_check_csr(/* INPUT */int A_1, /* INPUT */int A_2, /* INPUT */int A_3, /* INPUT */int A_4, /* INPUT */int A_5, /* INPUT */int A_6, /* INPUT */int A_7, /* INPUT */int A_8)
{
    static int _vcs_dpi_stub_initialized_ = 0;
    static int (*_vcs_dpi_fp_)(/* INPUT */int A_1, /* INPUT */int A_2, /* INPUT */int A_3, /* INPUT */int A_4, /* INPUT */int A_5, /* INPUT */int A_6, /* INPUT */int A_7, /* INPUT */int A_8) = NULL;
    if (!_vcs_dpi_stub_initialized_) {
        _vcs_dpi_fp_ = (int (*)(int A_1, int A_2, int A_3, int A_4, int A_5, int A_6, int A_7, int A_8)) dlsym(RTLD_NEXT, "gm_check_csr");
        _vcs_dpi_stub_initialized_ = 1;
    }
    if (_vcs_dpi_fp_) {
        return _vcs_dpi_fp_(A_1, A_2, A_3, A_4, A_5, A_6, A_7, A_8);
    } else {
        const char *fileName;
        int lineNumber;
        svGetCallerInfo(&fileName, &lineNumber);
        vcsMsgReport1("DPI-DIFNF", fileName, lineNumber, 0, 0, "gm_check_csr");
        return 0;
    }
}
#endif /* __VCS_IMPORT_DPI_STUB_gm_check_csr */


#ifdef __cplusplus
}
#endif

