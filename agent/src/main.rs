pub mod k8s;
pub mod otel;

#[macro_use]
extern crate lazy_static;
use libbpf_rs::TC_INGRESS;
use opentelemetry::global;
use opentelemetry::global::BoxedTracer;
use opentelemetry::trace::Span;
use opentelemetry::trace::SpanKind;
use opentelemetry::trace::TraceContextExt;
use opentelemetry::trace::Tracer;
use opentelemetry::Context;
use opentelemetry::KeyValue;
use opentelemetry::SpanId;
use opentelemetry::TraceId;
use otel::get_clock_offset;
use otel::init_global_logger;
use otel::init_global_tracer;
use serde::Serialize;
use anyhow::Ok;
use crossbeam::channel::unbounded;
use crossbeam::channel::Sender;
use crossbeam::channel::Receiver;
use libbpf_rs::Link;
use libbpf_rs::TcHook;
use libbpf_rs::TcHookBuilder;
use libbpf_rs::UprobeOpts;
use libbpf_rs::TC_EGRESS;
use tokio::sync::mpsc::UnboundedReceiver;
use tokio::sync::mpsc::UnboundedSender;
use std::ffi::CStr;
use std::os::fd::AsFd;
use std::time::SystemTime;
use anyhow::{bail, Result};
use libbpf_rs::skel::{OpenSkel, Skel, SkelBuilder};
use libbpf_rs::{MapCore, MapFlags, MapHandle};
use plain::Plain;
use std::collections::HashMap;
use std::mem::MaybeUninit;
use std::os::fd::AsRawFd;
use std::path::Path;
use std::sync::{Arc, Mutex};
use std::time::Duration;
use std::{env, fmt, fs};
use k8s::K8sInfo;
use warp::Filter;
use pnet::datalink;
use tokio::sync::mpsc;
use std::str::FromStr;

mod hooks {
    include!("bpf/.output/hooks.skel.rs");
}

use hooks::*;

unsafe impl Plain for hooks::types::tcp_event {}
unsafe impl Plain for hooks::types::tcp_event_with_streamid {}

impl fmt::Display for hooks::types::event_type {
    fn fmt(&self, f: &mut fmt::Formatter) -> fmt::Result {
        let s = match self.0 {
            0 => "SYS_RECVFROM",
            1 => "SYS_RECVMSG",
            2 => "SYS_SENDTO",
            3 => "SYS_SENDMSG",
            4 => "SYS_READ",
            5 => "SYS_WRITE",
            6 => "TCP_SENDMSG",
            7 => "TCP_SENDPAGE",
            8 => "TCP_RECVMSG_FROM_OUTSIDE",
            9 => "TCP_READ_SOCK",
            10 => "TCP_RECV_FROM_SKB",
            _ => "UNKNOWN",
        };
        write!(f, "{s}")
    }
}

impl fmt::Display for hooks::types::skb_event_type {
    fn fmt(&self, f: &mut fmt::Formatter) -> fmt::Result {
        write!(f, "{:?}", self)
    }
}
unsafe impl Plain for hooks::types::skb_event {}
// impl fmt::Display for hooks::types::controll_event_type {
//     fn fmt(&self, f: &mut fmt::Formatter) -> fmt::Result {
//         write!(f, "{:?}", self)
//     }
// }

unsafe impl Plain for hooks::types::context_type {}
impl fmt::Display for hooks::types::context_type {
    fn fmt(&self, f: &mut fmt::Formatter) -> fmt::Result {
        write!(f, "{:?}", self)
    }
}

unsafe impl Plain for hooks::types::socket_data_event {}
unsafe impl Plain for hooks::types::grpc_headers_event {}
unsafe impl Plain for hooks::types::buf_type {}
impl fmt::Display for hooks::types::buf_type {
    fn fmt(&self, f: &mut fmt::Formatter) -> fmt::Result {
        write!(f, "{:?}", self)
    }
}

unsafe impl Plain for hooks::types::spaninfo_t {}
unsafe impl Plain for hooks::types::span_type {}
impl fmt::Display for hooks::types::span_type {
    fn fmt(&self, f: &mut fmt::Formatter) -> fmt::Result {
        write!(f, "{:?}", self)
    }
}


lazy_static! {
    /*
    // Define prometheus metrics
    pub static ref TCP_EVENT: IntGaugeVec = IntGaugeVec::new(Opts::new("tcp_event", "TCP Event"),
                                                             &["ts", "pid", "tgid", "family", "event",
                                                               "src_ip", "src_port", "dst_ip", "dst_port",
                                                               "recv_next", "send_next",
                                                               "src_pod", "src_namespace", "src_service", "src_service_v", "src_node",
                                                               "dst_pod", "dst_namespace", "dst_service", "dst_service_v", "dst_node",
                                                               "node", "rid", "seq"]).unwrap();
    */
    static ref EVENTS_CTR: Mutex<u64> = Mutex::new(0u64);
    // State
    pub static ref PODS_LIST: Mutex<HashMap<String, HashMap<&'static str, String>>> = Mutex::new(HashMap::new());
    pub static ref SERVICES_LIST: Mutex<HashMap<String, HashMap<&'static str, String>>> = Mutex::new(HashMap::new());

    // Kubernetes config
    static ref NODE_NAME: String = env::var("NODE_NAME").unwrap_or_default();
    static ref KUBERNETES_SERVICE_HOST: String = env::var("KUBERNETES_SERVICE_HOST").unwrap_or_default();
    static ref KUBERNETES_PORT_443_TCP_PORT: String = env::var("KUBERNETES_PORT_443_TCP_PORT").unwrap_or_default();
    static ref SERVING_NAMESPACES: Vec<String> = env::var("SERVING_NAMESPACES").unwrap_or_default().split(",").map(|s| s.to_string()).collect();

    // Agent config
    pub static ref DEBUG: bool = match env::var("DEBUG") { Result::Ok(val) => val == "true" || val == "True", Err(_) => false };
    pub static ref KUBE_POLL_INTERVAL: u64 = env::var("KUBE_POLL_INTERVAL").ok().and_then(|v| v.parse::<u64>().ok()).unwrap_or(10);
    pub static ref EVENT_WITH_LOG: bool = match env::var("EVENT_WITH_LOG") { Result::Ok(val) => val == "true" || val == "True", Err(_) => false };
    static ref API_PORT: String = env::var("API_PORT").unwrap_or("9898".to_string());
    static ref NIC_NAME: String = env::var("NIC_NAME").unwrap_or("ens3".to_string());
    static ref GRPC_BEYLA_INJECTION: bool = match env::var("GRPC_BEYLA_INJECTION") {
        Result::Ok(val) => val == "true" || val == "True",
        Err(_) => false,
    };
    static ref GOROUTINES_INKERNEL_SUPPORT: bool = match env::var("GOROUTINES_INKERNEL_SUPPORT") {
        Result::Ok(val) => val == "true" || val == "True",
        Err(_) => false,
    };
    static ref TEST_GOROUTINE: bool = match env::var("TEST_GOROUTINE") {
        Result::Ok(val) => val == "true" || val == "True",
        Err(_) => false,
    };
}



fn handle_spaninfo(data: &[u8], tracer: &BoxedTracer, clock_offset: Duration) -> i32 {
    let mut evt = hooks::types::spaninfo_t::default();
    plain::copy_from_bytes(&mut evt, data).expect("Data buffer was too short");

    let traceid = evt.traceid;
    let spanid = evt.spanid;
    let parent_spanid = evt.parent_spanid;
    let start_ts = evt.start_ts;
    let end_ts = evt.end_ts;
    let span_type = evt.span_type;

    // if *DEBUG {
    //     println!("traceid: {} spanid: {} parent_spanid: {} start_ts: {} end_ts: {} evtype: {}",
    //              traceid,
    //              spanid,
    //              parent_spanid,
    //              start_ts,
    //              end_ts,
    //              span_type);
    // }
    
    let span_info = SpanInfo {
        traceid: traceid,
        spanid: spanid,
        parent_spanid: parent_spanid,
        start_time: start_ts,
        end_time: end_ts,
        span_type: span_type,
    };

    let start_systemtime = SystemTime::UNIX_EPOCH + clock_offset +Duration::from_nanos(span_info.start_time);
     let end_systemtime = SystemTime::UNIX_EPOCH + clock_offset + Duration::from_nanos(span_info.end_time);
    if *DEBUG {
        println!("new span {:?}", span_info);
    }
    if span_info.parent_spanid == 0 {
        // produce a root span
        // turn u32 to hex str
        let traceid_hex_str = format!("{:016x}", span_info.traceid);
        let spanid_hex_str = format!("{:016x}", span_info.spanid);
        let root_span_builder = tracer.span_builder("chain-scope-root-span")
        .with_trace_id(TraceId::from_hex(traceid_hex_str.as_str()).unwrap())
        .with_span_id(SpanId::from_hex(spanid_hex_str.as_str()).unwrap())
        .with_start_time(start_systemtime)
        .with_kind(SpanKind::Server);
    
        let _ = tracer.build(root_span_builder).end_with_timestamp(end_systemtime);
    } else {
        // produce a child span
        let traceid_hex_str = format!("{:016x}", span_info.traceid);
        let parent_spanid_hex_str = format!("{:016x}", span_info.parent_spanid);
        let spanid_hex_str = format!("{:016x}", span_info.spanid);
        let traceid = TraceId::from_hex(traceid_hex_str.as_str()).unwrap();
        let spanid = SpanId::from_hex(spanid_hex_str.as_str()).unwrap();
        let parent_spanid = SpanId::from_hex(parent_spanid_hex_str.as_str()).unwrap();
        let spankind = match span_info.span_type {
            hooks::types::span_type::SERVER_SPAN => SpanKind::Server,
            hooks::types::span_type::CLIENT_SPAN => SpanKind::Client,
            _ => SpanKind::Server,
            };
        let parent_noopspan_builder = tracer
        .span_builder("noop")
        .with_trace_id(traceid)
        .with_span_id(parent_spanid);
    
        let parent_span = tracer.build(parent_noopspan_builder);
        let parent_context = Context::current_with_span(parent_span);
    
        let child_span_builder = tracer.span_builder("chain-scope-span")
            .with_trace_id(traceid)
            .with_span_id(spanid)
            .with_start_time(start_systemtime)
            .with_kind(spankind);
    
        let mut child_span = tracer.build_with_context(child_span_builder,&parent_context);
        let  _ = child_span.end_with_timestamp(end_systemtime);
    }

    0
}
fn handle_tcp_event_with_streamid(data: &[u8]) -> i32 {
    let mut evt = hooks::types::tcp_event_with_streamid::default();
    plain::copy_from_bytes(&mut evt, data).expect("Data buffer was too short");


    let pid = evt.pid_tgid & ((1 << 32) - 1);
    let tgid = evt.pid_tgid >> 32;

    let ev_type = evt.evtype;
    let traceid = evt.traceid;
    let spanid = evt.spanid;
    let bytes = evt.bytes;
    let skb_seq = evt.skb_seq;

    let family = u32::from(evt.family);
    let mut ip_src = u32::from_be(evt.saddr);
    let mut ip_dst = u32::from_be(evt.daddr);
    let mut port_src = evt.sport;
    let mut port_dst = u16::from_be(evt.dport);
    if ev_type == hooks::types::event_type::TCP_RECVMSG_FROM_OUTSIDE || ev_type == hooks::types::event_type::TCP_RECV_FROM_SKB {
        (ip_src, ip_dst) = (ip_dst, ip_src);
        (port_src, port_dst) = (port_dst, port_src);
    }


    if *DEBUG {
        println!("execution_unit_info: pid {} tgid {} context_type: {} execution_context: {} --- type {} traceid {} spanid {} skb_seq {} bytes {} --- family {} src {}:{} dst {}:{} sk {:x}",
                 pid,
                 tgid,
                 0,
                 0,
                 ev_type,
                 traceid,
                 spanid,
                 skb_seq,
                 bytes,
                 family,
                 ip_src,
                 port_src,
                 ip_dst,
                 port_dst,
                 evt.sk
        );
    }
    let streamid_count =evt.stream_count as usize;
    for i in 0..streamid_count {
        let streamid = evt.streamids[i];
        if *DEBUG {
            println!("streamid {}", streamid);
        }
    }

    let event = EventInfo {
        event_type: "tcp_event_with_streamid".to_string(),
        merged: false,
        new_trace_flag: evt.new_trace_flag == 1,

        traceid: traceid,

        direction: ev_type == hooks::types::event_type::TCP_SENDMSG,
        socketid: evt.sk,

        pid: pid as u32,
        tgid: tgid as u32,
        timestamp: evt.end_ts,

        tcp_seq: evt.skb_seq,

        ip_src: ip_src,
        ip_dst: ip_dst,
        port_src: port_src,
        port_dst: port_dst,
        protocol: family,

        nodename: NODE_NAME.to_string(),

        streamids: Option::Some(evt.streamids.to_vec()),
        old_streamids: Option::None,
        old_traceid: Option::None,
        old_tcp_seq: Option::None,
    };

    let json = serde_json::to_string(&event).unwrap();
    tracing::error!("{}", json);

    return 0;
}
fn handle_tcp_event(data: &[u8],tracer: &BoxedTracer) -> i32 {
    let mut evt = hooks::types::tcp_event::default();
    plain::copy_from_bytes(&mut evt, data).expect("Data buffer was too short");
    // TODO: zero-copy
    // let evt: &hooks::types::tcp_event = unsafe {
    //     assert_eq!(data.len(), std::mem::size_of::<hooks::types::tcp_event>());
    //     &*(data.as_ptr() as *const hooks::types::tcp_event)
    // };
    /* fetch info from eBPF map */
    // let st = evt.start_ts;
    // let et = evt.end_ts;
    //let t = SystemTime::now().duration_since(UNIX_EPOCH).expect("Time went backwards").as_micros();
    let pid = evt.pid_tgid & ((1 << 32) - 1);
    let tgid = evt.pid_tgid >> 32;

    let ev_type = evt.evtype;
    let traceid = evt.traceid;
    let spanid = evt.spanid;
    let bytes = evt.bytes;
    let skb_seq = evt.skb_seq;
    let gt = evt.ground_truth;

    let family = u32::from(evt.family);
    let mut ip_src = u32::from_be(evt.saddr);
    let mut ip_dst = u32::from_be(evt.daddr);
    let mut port_src = evt.sport;
    let mut port_dst = u16::from_be(evt.dport);
    if ev_type == hooks::types::event_type::TCP_RECVMSG_FROM_OUTSIDE || ev_type == hooks::types::event_type::TCP_RECV_FROM_SKB {
        (ip_src, ip_dst) = (ip_dst, ip_src);
        (port_src, port_dst) = (port_dst, port_src);
    }
    if *DEBUG {
        println!("execution_unit_info: pid {} tgid {} context_type: {} execution_context: {} --- type {} gt {} traceid {} spanid {} skb_seq {} bytes {} --- family {} src {}:{} dst {}:{} sk {:x}",
                 pid,
                 tgid,
                 0,
                 0,
                 ev_type,
                 gt,
                 traceid,
                 spanid,
                 skb_seq,
                 bytes,
                 family,
                 ip_src,
                 port_src,
                 ip_dst,
                 port_dst,
                 evt.sk
        );
    }

    let event = EventInfo {
        event_type: "tcp_event".to_string(),
        merged: false,
        new_trace_flag: evt.new_trace_flag == 1,

        traceid: traceid,

        direction: ev_type == hooks::types::event_type::TCP_SENDMSG,
        socketid: evt.sk,

        pid: pid as u32,
        tgid: tgid as u32,
        timestamp: evt.end_ts,

        tcp_seq: evt.skb_seq,

        ip_src: ip_src,
        ip_dst: ip_dst,
        port_src: port_src,
        port_dst: port_dst,
        protocol: family,

        nodename: NODE_NAME.to_string(),

        streamids: Option::None,
        old_streamids: Option::None,
        old_traceid: Option::None,
        old_tcp_seq: Option::None,
    };

    if *EVENT_WITH_LOG {
        let json = serde_json::to_string(&event).unwrap();
        tracing::info!("{}", json);
    }else{
        let mut attributes = Vec::new();
        attributes.push(KeyValue::new("merged", event.merged));
        attributes.push(KeyValue::new("new_trace_flag", event.new_trace_flag));
        attributes.push(KeyValue::new("traceid", event.traceid as i64));
        attributes.push(KeyValue::new("direction", event.direction));
        attributes.push(KeyValue::new("socketid", event.socketid as i64));
        attributes.push(KeyValue::new("pid", event.pid as i64));
        attributes.push(KeyValue::new("tgid", event.tgid as i64));
        attributes.push(KeyValue::new("timestamp", event.timestamp as i64));
        attributes.push(KeyValue::new("tcp_seq", event.tcp_seq as i64));
        attributes.push(KeyValue::new("nodename", event.nodename.clone()));
        // attributes.push(KeyValue::new("ip_src", event.ip_src as i64));
        // attributes.push(KeyValue::new("ip_dst", event.ip_dst as i64));
        // attributes.push(KeyValue::new("port_src", event.port_src as i64));
        // attributes.push(KeyValue::new("port_dst", event.port_dst as i64));
        // attributes.push(KeyValue::new("protocol", event.protocol as i64));

        // produce a child span
        let traceid_hex_str = format!("{:016x}", evt.traceid);
        let traceid = TraceId::from_hex(traceid_hex_str.as_str()).unwrap();
        let span_builder = tracer
            .span_builder("event-op")
            .with_trace_id(traceid)
            .with_attributes(attributes);
        tracer.build(span_builder).end();
    }

    let mut ctr = EVENTS_CTR.lock().unwrap();
    *ctr = *ctr + 1;
    
    return 0;
}

fn handle_socket_data_event(data: &[u8]) -> i32 {
    let mut evt = hooks::types::socket_data_event::default();
    plain::copy_from_bytes(&mut evt, data).expect("Data buffer was too short");
    // print pretty
    let buf_type = evt.buf_type;
    let traceid = evt.traceid;
    if *DEBUG {
        println!(
            "buf_type: {} traceid:{} {:?}",
            buf_type,
            traceid,
            evt.socket_data
        );
    }

    let len =  evt.socket_data.len();
    let cstr = CStr::from_bytes_until_nul(&evt.socket_data[..len]).unwrap();
    if *DEBUG {
        println!("buf_type: {} traceid:{} {}", buf_type, traceid, cstr.to_string_lossy());
    }
    0
}

fn handle_grpc_headers_event(data: &[u8]) -> i32 {
    let mut evt = hooks::types::grpc_headers_event::default();
    plain::copy_from_bytes(&mut evt, data).expect("Data buffer was too short");

    if *DEBUG {
        let header_count = evt.header_count;
        println!("grpc_headers_event: traceid: {} header_count: {}", evt.traceid, header_count);
    }
    0
}


fn handle_skb_event(data: &[u8]) -> i32 {
    let mut evt = hooks::types::skb_event::default();
    plain::copy_from_bytes(&mut evt, data).expect("Data buffer was too short");
    // print pretty
    let ev_type = evt.evtype;
    if ev_type == hooks::types::skb_event_type::SKB_RENAME {
        //rename event means we need to move the sub tree that is associated with the current traceid spanid into original traceid spanid
        let orig_traceid = evt.old_traceid;
        let orig_tcp_seq = evt.old_tcp_seq;
        let target_traceid = evt.new_traceid;
        let target_tcp_seq = evt.new_tcp_seq;
        let streams_count = evt.stream_count;
        if *DEBUG {
            println!("rename event: traceid: {}, tcp_seq: {}, target traceid: {}, target tcp_seq: {}, streams:", orig_traceid, orig_tcp_seq, target_traceid, target_tcp_seq);
            for i in 0..streams_count {
                print!(" {}", evt.streamids[i as usize]);
            }
            println!("");
        }

        let event = EventInfo {
            event_type: "rename_event".to_string(),
            merged: false,
            new_trace_flag: false,

            traceid: evt.new_traceid,

            direction: false,
            socketid: 0,

            pid: 0,
            tgid: 0,
            timestamp: evt.ts,

            tcp_seq: target_tcp_seq,

            ip_src: 0,
            ip_dst: 0,
            port_src: 0,
            port_dst: 0,
            protocol: 0,

            nodename: NODE_NAME.to_string(),

            streamids: Option::Some(evt.streamids.to_vec()),
            old_streamids: Option::None,
            old_traceid: Option::Some(orig_traceid),
            old_tcp_seq: Option::Some(orig_tcp_seq),
        };
        // target: "tcp_event_with_streamid", 
        let json = serde_json::to_string(&event).unwrap();
        tracing::error!("{}", json);

    } 

    0
}

#[derive(serde::Deserialize)]
struct IntervalHttpRequest {
    sampling_interval: Option<u32>,
}

#[derive(serde::Deserialize)]
struct IpHttpRequest {
    ip: Option<String>,
}

async fn set_sampling_interval(req: IntervalHttpRequest) -> Result<impl warp::Reply, warp::Rejection> {
    if let Some(interval) = req.sampling_interval {
        println!("Updating sampling rate to one every {}...", interval);
        let path = "/sys/fs/bpf/fullstacktracer/sample_interval_map";
        let handler = MapHandle::from_pinned_path(path).unwrap();
        let key = [0u8; 4];
        let value = interval.to_le_bytes();
        handler.update(&key, &value, MapFlags::ANY).unwrap();
    }
    Result::Ok(warp::reply())
}

async fn add_unmonitored_ip(req: IpHttpRequest) -> Result<impl warp::Reply, warp::Rejection> {
    if let Some(ip) = req.ip {
        println!("[not implemented] request to add {} to the list of unmonitored addresses...", ip);
    }
    Result::Ok(warp::reply())
}

#[derive(Debug)]
struct LockError;
impl warp::reject::Reject for LockError {}

pub async fn get_services() -> Result<impl warp::Reply, warp::Rejection> {
    let response = SERVICES_LIST
        .lock()
        .map_err(|_| warp::reject::custom(LockError))?;

    Result::Ok(warp::reply::json(&*response))
}

fn bump_memlock_rlimit() -> Result<()> {
    let rlimit = libc::rlimit {
        rlim_cur: 128 << 20,
        rlim_max: 128 << 20,
    };

    if unsafe { libc::setrlimit(libc::RLIMIT_MEMLOCK, &rlimit) } != 0 {
        bail!("Failed to increase rlimit");
    }

    Ok(())
}


#[derive(PartialEq,Debug)]
pub enum ProbeType {
    NoProbe,
    IpOptionTc,
    GoGrpcClient,
    GoGrpcServer,
    GoGrpcBoth,
    Envoy,
    Traefik,
}
pub struct ProbeAttachInfo{
    pub pid: i32,
    pub probe_type: ProbeType,
}

#[derive(PartialEq,Debug)]
pub struct SpanInfo{
    pub traceid: u32,
    pub spanid: u32,
    pub parent_spanid: u32,
    start_time: u64,
    end_time: u64,
    span_type: hooks::types::span_type,
}

#[derive(PartialEq,Debug,Serialize)]
pub struct EventInfo{
    pub event_type: String,
    pub merged: bool,
    pub new_trace_flag: bool,

    pub traceid: u32,
    // to construct span
    pub direction: bool, // false for ingress, true for egress
    pub socketid: u64,
    // intra-service propogate
    pub pid: u32,
    pub tgid: u32,
    pub timestamp: u64,
    // inter-service propogate
    pub tcp_seq: u32,

    pub nodename: String,
    // for stream multiplexing protocol
    pub streamids: Option<Vec<u32>>,
    pub old_traceid: Option<u32>,
    pub old_streamids: Option<Vec<u32>>,
    pub old_tcp_seq: Option<u32>,

    // correlate with k8s metadata
    pub ip_src: u32,
    pub ip_dst: u32,
    pub port_src: u16,
    pub port_dst: u16,
    pub protocol: u32, 
}
 
fn main() {
    bump_memlock_rlimit().unwrap();
    let debug = match env::var("DEBUG") {
        std::result::Result::Ok(val) => val == "true" || val == "True",
        Err(_) => true,         // TODO: 这里默认设置为true, 之后可能需要根据需求再改
    };
    let mut handle = LibbpfHandle::new();

    // open, load and auto attach bpf prog
    let mut skel_builder = hooks::HooksSkelBuilder::default();
    skel_builder.obj_builder.debug(debug);
    let mut open_object = MaybeUninit::uninit();
    let mut open = skel_builder
        .open(&mut open_object)
        .expect("Failed to open BPF skeleton");
    
    if let Some(ref mut bss_data) = open.maps.bss_data {
        let interfaces = datalink::interfaces();
        for interface in &interfaces {
            println!("interface: {:?}", interface);
            if interface.name == *NIC_NAME {
                bss_data.pnic_ifindex = interface.index as u32;
                println!("pnic_ifindex: {}", bss_data.pnic_ifindex);
            } else if interface.name == "veth-gso" {
                bss_data.veth_gso_ifindex = interface.index as u32;
                println!("veth_gso_ifindex: {}", bss_data.veth_gso_ifindex);
            } else {
                continue;
            }
        }

    }
    // let sampling_rate_init = env::var("SAMPLING_INTERVAL").unwrap().parse::<u32>().unwrap();
    let sampling_rate_init = match env::var("SAMPLING_INTERVAL") {
        Result::Ok(val) => val.parse::<u32>().unwrap(),
        Err(_) => 1,
    };

    if let Some(ref mut data) = open.maps.data_data {
        data.sampling_interval = sampling_rate_init;
        println!("sampling_interval: {}", data.sampling_interval);
    }
    //warp the skel into Arc<Mutex>
    let mut loaded_skel = open.load().expect("Failed to load BPF skeleton");
    if*TEST_GOROUTINE{
        handle.add_bpf_link(loaded_skel.progs.test_tcp_recvmsg_exit.attach_kprobe(false,"tcp_recvmsg").expect("Failed to attach kprobe"));
        handle.add_bpf_link(loaded_skel.progs.test_tcp_sendmsg_locked_enter.attach_kprobe(false,"tcp_sendmsg_locked").expect("Failed to attach kprobe"));
    }else{
        loaded_skel.attach().expect("Failed to auto attach bpf program");
    }

    let key = [0u8; 4];
    let value = sampling_rate_init.to_le_bytes();
    // handler.update(&key, &value, MapFlags::ANY).unwrap();
    loaded_skel.maps.sample_interval_map.update(&key, &value, MapFlags::ANY).unwrap();

    // $ mount | grep cgroup2
    // cgroup2 on /sys/fs/cgroup/unified type cgroup2 (rw,nosuid,nodev,noexec,relatime,nsdelegate)
    let output = std::process::Command::new("mount")
    .output()
    .expect("Failed to execute command");
    let mount_output = String::from_utf8_lossy(&output.stdout);
    let cgroup_mount_path =  mount_output
        .lines()
        .find(|line| line.contains("cgroup2"))
        .and_then(|line| line.split_whitespace().nth(2))
        .unwrap_or("/sys/fs/cgroup");
    println!("cgroup mount path: {}", cgroup_mount_path);
    let f = fs::OpenOptions::new()
        .read(true)
        .write(false)
        .open(cgroup_mount_path)
        .expect("Error in reading cgroup file");
    let cgroup_fd = f.as_raw_fd();
    println!("cgroup_fd {}", cgroup_fd);

    let (sender,receiver): (Sender<ProbeAttachInfo>, Receiver<ProbeAttachInfo>) = unbounded();
    let (span_sender,span_receiver): (UnboundedSender<SpanInfo>, UnboundedReceiver<SpanInfo>) = mpsc::unbounded_channel::<SpanInfo>();
    let (event_sender,event_receiver): (UnboundedSender<EventInfo>, UnboundedReceiver<EventInfo>) = mpsc::unbounded_channel::<EventInfo>();
    k8s::init_maps(&mut loaded_skel);

    std::thread::spawn(move || {
        let request_route =
            warp::path!("config" / "rate" / "sampling")
                .and(warp::body::json())
                .and_then(set_sampling_interval)
            .or(warp::path!("config" / "ip-filter")
                .and(warp::body::json())
                .and_then(add_unmonitored_ip))
            .or(warp::path!("services")
                .and(warp::get())
                .and_then(get_services));
        let routes = request_route;
        let k8s_info = Arc::new(tokio::sync::Mutex::new(K8sInfo {
            pods_list: HashMap::new(),
            services_list: HashMap::new(),
            kubernetes_service_host: KUBERNETES_SERVICE_HOST.to_string(),
            kubernetes_port_443_tcp_port: KUBERNETES_PORT_443_TCP_PORT.to_string(),
            node_name: NODE_NAME.to_string(),
            debug: *DEBUG,
            serving_namespaces: SERVING_NAMESPACES.clone(),
        }));

        tokio::runtime::Builder::new_multi_thread()
            .worker_threads(8)
            .enable_all()
            .build()
            .unwrap()
            .block_on(
                async move {
                    tokio::join!(
                        k8s::kube_poll(k8s_info.clone(),sender.clone()),
                        warp::serve(routes).run(([0, 0, 0, 0], u16::from_str(API_PORT.as_str()).unwrap())),
                        // otel::produce_span_to_otel(span_receiver),
                        // otel::produce_event_to_otel(event_receiver),
                    );
            });
    });

    init_global_logger();
    init_global_tracer();

    let progs = loaded_skel.progs;
    let mut builder = libbpf_rs::RingBufferBuilder::new();
    let tcp_event_rb = loaded_skel.maps.event_ringbuf;
    let tracer = global::tracer("chain-scope");
    let clock_offset = get_clock_offset().unwrap();

    builder
        .add(&tcp_event_rb, move |data| {
            let data_len = data.len();
            let tcp_event_size = std::mem::size_of::<hooks::types::tcp_event>();
            if data_len == tcp_event_size {
                handle_tcp_event(data,&tracer)
            } else if data_len == std::mem::size_of::<hooks::types::tcp_event_with_streamid>() {
                handle_tcp_event_with_streamid(data)
            } else if data_len == std::mem::size_of::<hooks::types::socket_data_event>() {
                handle_socket_data_event(data)
            } else if data_len == std::mem::size_of::<hooks::types::skb_event>() {
                handle_skb_event(data)
            } else if data_len == std::mem::size_of::<hooks::types::spaninfo_t>() {
                handle_spaninfo(data, &tracer, clock_offset)
            } else if data_len == std::mem::size_of::<hooks::types::grpc_headers_event>() {
                handle_grpc_headers_event(data)
            } else {
                println!("no handler for data~");
                return 0;
            }
            // handle_tcp_event(data,k8s_info.clone())
        })
        .unwrap();
    let ringbuf = builder.build().unwrap();
    std::thread::Builder::new()
    .name("ebpf-ringbuf-poller".to_string())
    .spawn(move || {
        // let mut k8s_info = k8s_info.lock().unwrap();
        // update_service_ip(k8s_info.clone());
        println!("Started polling eBPF data event ringbuffer");
        while ringbuf.poll(Duration::MAX).is_ok() {
            std::thread::sleep(Duration::from_millis(10));
        }
    }).unwrap();
    if!*TEST_GOROUTINE{
        let _ = try_attach_pnic_tc(&progs,&mut handle);
    }
    loop {
        println!("wating data from queue");
        let attach_info = receiver.recv().unwrap();
        if attach_info.probe_type == ProbeType::NoProbe {
            continue;
        }
        // print pid and probe type
        println!("pid: {} probe_type: {:#?}", attach_info.pid, attach_info.probe_type);
        if attach_info.probe_type == ProbeType::IpOptionTc {
            try_attach_tc_probe(&attach_info, &progs, &mut handle);
        }
        if attach_info.probe_type == ProbeType::GoGrpcClient {
            try_attach_grpc_client_probe(&attach_info, &progs,&mut handle);
        }
        if attach_info.probe_type == ProbeType::GoGrpcServer || attach_info.probe_type == ProbeType::GoGrpcBoth {
            try_attach_grpc_server_probe(&attach_info, &progs,&mut handle);
        }
        if attach_info.probe_type == ProbeType::Traefik {
            try_attach_traefik_probe(&attach_info, &progs,&mut handle);
        }
        println!("Received {} events so far.", *EVENTS_CTR.lock().unwrap());
    }
}

struct LibbpfHandle {
    tchook_vec: Vec<TcHook>,
    bpf_link_vec: Vec<Link>,
}

impl LibbpfHandle {
    fn new() -> Self {
        LibbpfHandle {
            tchook_vec: Vec::new(),
            bpf_link_vec: Vec::new(),
        }
    }

    fn add_tchook(&mut self, tchook: TcHook) {
        self.tchook_vec.push(tchook);
    }

    fn add_bpf_link(&mut self, link: Link) {
        self.bpf_link_vec.push(link);
    }
}

impl Drop for LibbpfHandle {
    // 实现 Drop trait
    fn drop(&mut self) {
        println!("Drop LibbpfHandle");
        // 执行 detach 操作
        for mut tchook in self.tchook_vec.drain(..) {
            tchook.detach().unwrap();
        }
        for link in self.bpf_link_vec.drain(..) {
            link.detach().unwrap();
        }
    }
}

fn try_attach_traefik_probe(attach_info: &ProbeAttachInfo, progs: &HooksProgs,libbpf_handle: &mut LibbpfHandle) {
}

fn try_attach_grpc_server_probe(attach_info: &ProbeAttachInfo, progs: &HooksProgs,libbpf_handle: &mut LibbpfHandle) {
    let path_str = format!("/proc/{}/exe",attach_info.pid);
    let path = Path::new(&path_str);
    if !*TEST_GOROUTINE {
       let opts2 = UprobeOpts {
            ref_ctr_offset: 0,
            cookie: 0,
            retprobe: false,
            func_name: Some("google.golang.org/grpc/internal/transport.(*http2Server).operateHeaders".to_string()),
            _non_exhaustive: Default::default(),
        };
        let uprobe2 = progs.grpc_operate_headers.attach_uprobe_with_opts(attach_info.pid, path, 0,opts2).expect("failed to attach uprobe");
        libbpf_handle.add_bpf_link(uprobe2);
        let path_str = format!("/proc/{}/exe",attach_info.pid);
        let path = Path::new(&path_str);
        let opts5 = UprobeOpts {
            ref_ctr_offset: 0,
            cookie: 0,
            retprobe: false,
            func_name: Some("google.golang.org/grpc/internal/transport.(*controlBuffer).executeAndPut".to_string()),
            _non_exhaustive: Default::default(),
        };
        let uprobe5 = progs.grpc_control_buffer_execute_and_put.attach_uprobe_with_opts(attach_info.pid, path, 0,opts5).expect("failed to attach uprobe");
        libbpf_handle.add_bpf_link(uprobe5);
        let opts6 = UprobeOpts {
            ref_ctr_offset: 0,
            cookie: 0,
            retprobe: false,
            func_name: Some("google.golang.org/grpc/internal/transport.(*loopyWriter).headerHandler".to_string()),
            _non_exhaustive: Default::default(),
        };
        let uprobe6 = progs.grpc_internal_transport_loopyWriter_headerHandler.attach_uprobe_with_opts(attach_info.pid, path, 0,opts6).expect("failed to attach uprobe");
        libbpf_handle.add_bpf_link(uprobe6);
        let opts1 = UprobeOpts {
            ref_ctr_offset: 0,
            cookie: 0,
            retprobe: false,
            func_name: Some("runtime.goexit1".to_string()),
            _non_exhaustive: Default::default(),    
        };
        let uprobe1 = progs.runtime_goexit1.attach_uprobe_with_opts(attach_info.pid, path, 0, opts1).unwrap();
        libbpf_handle.add_bpf_link(uprobe1);
        let opts2 = UprobeOpts {
            ref_ctr_offset: 0,
            cookie: 0,
            retprobe: false,
            func_name: Some("runtime.newproc1".to_string()),
            _non_exhaustive: Default::default(),    
        };
        let uprobe2 = progs.runtime_newproc1_exit.attach_uprobe_with_opts(attach_info.pid,path,0x351,opts2).expect("failed to attach uprobe");
        libbpf_handle.add_bpf_link(uprobe2);
        if *GRPC_BEYLA_INJECTION {
            let opts3 = UprobeOpts {
                ref_ctr_offset: 0,
                cookie: 0,
                retprobe: false,
                func_name: Some("golang.org/x/net/http2.(*Framer).WriteHeaders".to_string()),
                _non_exhaustive: Default::default(),
            };
            let uprobe3 = progs.framer_WriteHeaders.attach_uprobe_with_opts(attach_info.pid, path, 0,opts3).expect("failed to attach uprobe");
            libbpf_handle.add_bpf_link(uprobe3);
            let opts4 = UprobeOpts {
                ref_ctr_offset: 0,
                cookie: 0,
                retprobe: false,
                func_name: Some("golang.org/x/net/http2.(*Framer).WriteHeaders".to_string()),
                _non_exhaustive: Default::default(),
            };
            let uprobe4 = progs.framer_WriteHeaders_return.attach_uprobe_with_opts(attach_info.pid, path, 0x493,opts4).expect("failed to attach uprobe");
            libbpf_handle.add_bpf_link(uprobe4);
            println!("Attached uprobe writeHeaders_return to {:?}", path);
        }
    }

}

fn try_attach_grpc_client_probe(attach_info: &ProbeAttachInfo, progs: &HooksProgs,libbpf_handle: &mut LibbpfHandle) {
    let path_str = format!("/proc/{}/exe",attach_info.pid);
    let path = Path::new(&path_str);
    if !*TEST_GOROUTINE {
        let opts5 = UprobeOpts {
            ref_ctr_offset: 0,
            cookie: 0,
            retprobe: false,
            func_name: Some("google.golang.org/grpc/internal/transport.(*controlBuffer).executeAndPut".to_string()),
            _non_exhaustive: Default::default(),
        };
        let uprobe5 = progs.grpc_control_buffer_execute_and_put.attach_uprobe_with_opts(attach_info.pid, path, 0,opts5).expect("failed to attach uprobe");
        libbpf_handle.add_bpf_link(uprobe5);
        let opts6 = UprobeOpts {
            ref_ctr_offset: 0,
            cookie: 0,
            retprobe: false,
            func_name: Some("google.golang.org/grpc/internal/transport.(*loopyWriter).headerHandler".to_string()),
            _non_exhaustive: Default::default(),
        };
        let uprobe6 = progs.grpc_internal_transport_loopyWriter_headerHandler.attach_uprobe_with_opts(attach_info.pid, path, 0,opts6).expect("failed to attach uprobe");
        libbpf_handle.add_bpf_link(uprobe6);
        let opts1 = UprobeOpts {
            ref_ctr_offset: 0,
            cookie: 0,
            retprobe: false,
            func_name: Some("runtime.goexit1".to_string()),
            _non_exhaustive: Default::default(),    
        };
        let uprobe1 = progs.runtime_goexit1.attach_uprobe_with_opts(attach_info.pid, path, 0, opts1).unwrap();
        libbpf_handle.add_bpf_link(uprobe1);
        let opts2 = UprobeOpts {
            ref_ctr_offset: 0,
            cookie: 0,
            retprobe: false,
            func_name: Some("runtime.newproc1".to_string()),
            _non_exhaustive: Default::default(),    
        };
        let uprobe2 = progs.runtime_newproc1_exit.attach_uprobe_with_opts(attach_info.pid,path,0x351,opts2).expect("failed to attach uprobe");
        libbpf_handle.add_bpf_link(uprobe2);
        if *GRPC_BEYLA_INJECTION {
            let opts3 = UprobeOpts {
                ref_ctr_offset: 0,
                cookie: 0,
                retprobe: false,
                func_name: Some("golang.org/x/net/http2.(*Framer).WriteHeaders".to_string()),
                _non_exhaustive: Default::default(),
            };
            let uprobe3 = progs.framer_WriteHeaders.attach_uprobe_with_opts(attach_info.pid, path, 0,opts3).expect("failed to attach uprobe");
            libbpf_handle.add_bpf_link(uprobe3);
            let opts4 = UprobeOpts {
                ref_ctr_offset: 0,
                cookie: 0,
                retprobe: false,
                func_name: Some("golang.org/x/net/http2.(*Framer).WriteHeaders".to_string()),
                _non_exhaustive: Default::default(),
            };
            let uprobe4 = progs.framer_WriteHeaders_return.attach_uprobe_with_opts(attach_info.pid, path, 0x493,opts4).expect("failed to attach uprobe");
            libbpf_handle.add_bpf_link(uprobe4);
            println!("Attached uprobe writeHeaders_return to {:?}", path);
        }
    }else{
        if !*GOROUTINES_INKERNEL_SUPPORT {
            let opts5 = UprobeOpts {
                ref_ctr_offset: 0,
                cookie: 0,
                retprobe: false,
                func_name: Some("runtime.execute".to_string()),
                _non_exhaustive: Default::default(),
            };
            let uprobe5 = progs.runtime_execute.attach_uprobe_with_opts(attach_info.pid,path,0, opts5).expect("Failed to attach uprobe");
            libbpf_handle.add_bpf_link(uprobe5);
            println!("Attached uprobe to runtime.execute");
        }
    }
}

fn try_attach_tc_probe(attach_info: &ProbeAttachInfo,progs:&HooksProgs<'_>,libbpf_handle: &mut LibbpfHandle) {
    // let pid = attach_info.pid as u32;
    // unsafe {
    //     let current_ns_path = Path::new("/proc/self/ns/net");
    //     let current_ns_link = std::fs::read_link(current_ns_path).unwrap();
    //     println!("current_ns_path: {:?} current_ns_link: {:?}", current_ns_path, current_ns_link);
    //     let file = fs::File::open(current_ns_path).unwrap();
    //     let current_ns = file.as_fd();
    //     let target_ns_path = format!("/proc/{}/ns/net", pid);
    //     println!("target_ns_path: {:?}", target_ns_path);
    //     if !Path::new(target_ns_path.as_str()).exists() {
    //         println!("target_ns_path: {:?} not exists", target_ns_path);
    //         return;
    //     }
    //     let target_ns_link = std::fs::read_link(target_ns_path.as_str());
    //     if target_ns_link.is_err() {
    //         println!("target_ns_link: {:?} is not exists", target_ns_link);
    //         return;
    //     }
    //     let target_ns_link = target_ns_link.unwrap();
    //     if current_ns_link == target_ns_link {
    //         println!("current_ns_link: {:?} == target_ns_link: {:?}", current_ns_link, target_ns_link);
    //         return;
    //     }
    //     let target_file = fs::File::open(target_ns_path.as_str()).unwrap();
    //     let target_ns = target_file.as_fd();
    //     // 切换到目标进程的网络命名空间
    //     println!("enter target pid {} network namespace", pid);
    //     setns(target_ns.as_raw_fd(), nix::libc::CLONE_NEWNET);

    //     let tc_egress_prog = &progs.tc_egress_func;

    //     let interfaces = datalink::interfaces();
    //     for interface in &interfaces {
    //         println!("interface: {:?}", interface);
    //         let ifindex = interface.index;
    //         let mut tc_builder = TcHookBuilder::new(tc_egress_prog.as_fd());
    //         tc_builder
    //             .ifindex(ifindex as i32)
    //             .replace(true)
    //             .handle(1)
    //             .priority(1);
    //         let mut tc_egress = tc_builder.hook(TC_EGRESS);
    //         tc_egress.create().unwrap();
    //         tc_egress.attach().unwrap();
    //         libbpf_handle.add_tchook(tc_egress);
    //     }
    //     // Restore back to the original network namespace if needed
    //     setns(current_ns.as_raw_fd(), nix::libc::CLONE_NEWNET);
    // }

    return;

}

fn try_attach_pnic_tc(progs: &HooksProgs<'_>, libbpf_handle: &mut LibbpfHandle) -> Result<()> {
    let interfaces = datalink::interfaces();
    for interface in &interfaces {
        let ifindex = interface.index;
        if interface.name == *NIC_NAME {
            println!("Found {} interface with index: {}", interface.name, ifindex);
            let mut tc_builder = TcHookBuilder::new(progs.pnic_egress_ip_tagging.as_fd());
            tc_builder
                .ifindex(ifindex as i32)
                .replace(true)
                .handle(1)
                .priority(1);
            let mut tc_egress = tc_builder.hook(TC_EGRESS);
            tc_egress.create().unwrap();
            tc_egress.attach().unwrap();
            libbpf_handle.add_tchook(tc_egress);
        } else if interface.name == "veth-return" {
            println!("veth-return interface found, attaching tc hook");
            let mut tc_builder = TcHookBuilder::new(progs.veth_return_ingress.as_fd());
            tc_builder
                .ifindex(ifindex as i32)
                .replace(true)
                .handle(1)
                .priority(1);
            let mut tc_ingress = tc_builder.hook(TC_INGRESS);
            tc_ingress.create().unwrap();
            tc_ingress.attach().unwrap();
            libbpf_handle.add_tchook(tc_ingress);
        } else {
            continue;
        }
    }
    Ok(())
}