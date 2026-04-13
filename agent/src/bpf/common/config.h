#pragma once

// agent config
#define DEFAULT_SAMPLING_INTERVAL 1
#define SENDPAGE_SUPPORT 0
#define THREADPOOL_SUPPORT 0
/**
 * Disable all the processing inside all hooks
 */
#define IDLE 0

// debug features
#define DEBUG_IP 
#define DEBUG_TCP
#define DEBUG_EVENT
#define DEBUG_GRPC
#define DEBUG_TRACE_INFO
#define DEBUG_HTTP
#define DEBUG_LEVEL 0
#define REPORT_ALL_EVENTS 0
#define MEASURE_EXECUTION_TIME 0
#define KEEP_SYMBOLS 0
#define GROUND_TRUTH 0

#define EXPORT_EVENTS_AT_TCP 1
#define EXPORT_SPANS 0
#define UPROBE_OPTIMIZE_SUPPORT 0

#define NIC_NAME "ens3"

#define COROUTINE_INKERNEL_SUPPORT 0

#define COROUTINE_EXTENSION_SUPPORT 1

// when testing the GRPC, the coroutine extension must be enabled
// when GRPC_IP_TAGGING is enabled, the grpc tracer will use the ip option to tag the grpc request, otherwise it will use the grpc header to tag the grpc request
#define GRPC_IP_TAGGING 1
// GRPC_IP_TAGGING must be enabled when GRPC_IP_TAGGING_WITH_REDISTRIBUTE is enabled
// when GRPC_IP_TAGGING_WITH_REDISTRIBUTE is enabled, traceinfo will be redistributed to several ip options
#define GRPC_IP_TAGGING_WITH_REDISTRIBUTE 0


// test cases combination
// 1. GRPC_IP_TAGGING 0  GRPC_INKERNEL_SUPPORT 1 GRPC_IP_TAGGING_WITH_REDISTRIBUTE 0 // test overhead and accuracy of different grpc tracing
// 2. GRPC_IP_TAGGING 1 GRPC_INKERNEL_SUPPORT 1 GRPC_IP_TAGGING_WITH_REDISTRIBUTE 0 
// 3. GRPC_IP_TAGGING 1 GRPC_INKERNEL_SUPPORT 1  GRPC_IP_TAGGING_WITH_REDISTRIBUTE 1

// 4. GRPC_IP_TAGGING 0 GRPC_INKERNEL_SUPPORT 0 // test overhead of different goroutine support
// 5. GRPC_IP_TAGGING 0 GRPC_INKERNEL_SUPPORT 1

// always on
#define ENABLE_VETH_GSO 1