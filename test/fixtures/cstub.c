#define CAML_NAME_SPACE
#include <caml/mlvalues.h>
#include <caml/memory.h>
#include <caml/alloc.h>
#include <caml/callback.h>
#include <caml/fail.h>

CAMLprim value zcaml_add_mul(value a, value b, value c) {
    CAMLparam3(a, b, c);
    intnat res = (Long_val(a) + Long_val(b)) * Long_val(c);
    CAMLreturn(Val_long(res));
}

CAMLprim value zcaml_call_ocaml_closure(value fn, value arg) {
    CAMLparam2(fn, arg);
    CAMLlocal1(res);
    res = caml_callback(fn, arg);
    CAMLreturn(res);
}
