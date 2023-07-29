
/* ----- header.c ----- */

//#include <stdlib.h>
#include <stdio.h>
//#include <string.h>
#include <ctype.h>
#include <errno.h>
#include <stdarg.h>

#include <signal.h>
#include <unistd.h>
#include <sys/prctl.h>
#include <pty.h>
#include <fcntl.h>
#include <fnmatch.h>
#include <dirent.h>
#include <libgen.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <sys/wait.h>
#include <sys/sysinfo.h>



// link with -lutil

// list all <header> files in use
//egrep -ro '^\s*#\s*include\s+<(.*)>' src/ | sed -e 's/^.*<\(.*\)>.*$/\1/'



#define PP_ARG_N(_1, _2, _3, _4, _5, _6, _7, _8, _9, _10, _11, _12, _13, _14, _15, _16, _17, _18, _19, _20, _21, _22, _23, _24, _25, _26, _27, _28, _29, _30, _31, _32, _33, _34, _35, _36, _37, _38, _39, _40, _41, _42, _43, _44, _45, _46, _47, _48, _49, _50, _51, _52, _53, _54, _55, _56, _57, _58, _59, _60, _61, _62, _63, N, ...) N
#define PP_RSEQ_N() 63, 62, 61, 60, 59, 58, 57, 56, 55, 54, 53, 52, 51, 50, 49, 48, 47, 46, 45, 44, 43, 42, 41, 40, 39, 38, 37, 36, 35, 34, 33, 32, 31, 30, 29, 28, 27, 26, 25, 24, 23, 22, 21, 20, 19, 18, 17, 16, 15, 14, 13, 12, 11, 10, 9, 8, 7, 6, 5, 4, 3, 2, 1, 0
#define PP_NARG_(...) PP_ARG_N(__VA_ARGS__)
#define PP_NARG(...)  PP_NARG_(__VA_ARGS__, PP_RSEQ_N())




char** g_gcc_opts_list;
char* g_gcc_opts_flat;
char* g_gcc_include;
char* g_gcc_libs;

int g_nprocs;

struct strlist;

typedef struct objfile {
	// user config
	char** sources;

	char** debug_cflags;
	char** release_cflags;
	char** profiling_cflags;
	char** common_cflags;
	char** libs_needed;
	char** lib_headers_needed;
	char** ld_add;
	
	char* source_dir;// "src"
	char* exe_path; // the executable name
	char* base_build_dir; //  = "build";
	
	// returns a dup'd string with the full, raw command to execute
	char* (*compile_source_cmd)(char* src_path, char* obj_path, struct objfile* obj);
	
	char mode_debug;
	char mode_profiling;
	char mode_release;
	char clean_first;
	
	char verbose;
	
	// internally calculated
	char** gcc_opts_list;
	char* gcc_opts_flat;
	char* gcc_include;
	char* gcc_libs;
	
	char* build_dir; // full build path, including debug/release options
	char* build_subdir;
	
	strlist objs; // .o's to be created
	strlist compile_cache; // list of compile commands to run
	
	char* archive_path; // temporary .a during build process
} objfile;





/* -END- header.c ----- */
