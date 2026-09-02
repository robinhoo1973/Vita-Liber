// Minimal stub for MSVC's <specstrings.h> so ORT's C API header compiles under Clang on Linux.
// All SAL annotations are no-ops here; they only carry meaning for MSVC static analysis.
#ifndef SPECSTRINGS_H
#define SPECSTRINGS_H

#define _In_
#define _Out_
#define _Inout_
#define _In_opt_
#define _Out_opt_
#define _Inout_opt_
#define _In_z_
#define _Out_z_
#define _Inout_z_
#define _In_opt_z_
#define _Out_opt_z_
#define _In_reads_(x)
#define _In_reads_opt_(x)
#define _Inout_updates_(x)
#define _Inout_updates_all_(x)
#define _Out_writes_(x)
#define _Out_writes_opt_(x)
#define _Out_writes_all_(x)
#define _Out_writes_bytes_all_(x)
#define _Outptr_result_buffer_maybenull_(x)
#define _Return_type_success_(x)
#define _Success_(x)
#define _Check_return_
#define _Post_equal_to_(x)
#define _Pre_notnull_
#define _Pre_maybenull_
#define _Post_notnull_
#define _Post_maybenull_
#define _Deref_out_
#define _Deref_post_notnull_

#endif /* SPECSTRINGS_H */
