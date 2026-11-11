// wcslen for the Windows host build, which links no CRT (only kernel32, like
// upstream's `-nostdlib` mingw recipe). clang emits a wcslen call for the UTF-16
// scans; Zig's compiler-rt supplies memset/memcpy but not wcslen, and mingw's
// libmingwex is what upstream's recipe gets it from. This is the whole shim.
//
// This is free and unencumbered software released into the public domain.

typedef unsigned short char16_t;
typedef __SIZE_TYPE__ size_t;

size_t wcslen(const char16_t *s)
{
    const char16_t *p = s;
    while (*p) {
        p++;
    }
    return (size_t)(p - s);
}
