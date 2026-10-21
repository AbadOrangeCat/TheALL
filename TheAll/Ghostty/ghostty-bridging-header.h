#ifndef ghostty_bridging_header_h
#define ghostty_bridging_header_h
// 走 HEADER_SEARCH_PATHS 定义的 $(PROJECT_DIR)/Vendor/ghostty/include，
// 不依赖相对路径 —— 否则 SourceKit 索引进程在非 SRCROOT 工作目录下会解析失败，
// 编辑器里出一堆 "Cannot find type ghostty_surface_t in scope" 的假阳性。
#include <ghostty.h>
#endif
