use libc::{clock_gettime, timespec, CLOCK_BOOTTIME, CLOCK_REALTIME};
use opentelemetry::trace::Link;
use opentelemetry::trace::{
    SamplingDecision, SamplingResult, SpanKind, TraceId,
    TraceState,
};
use opentelemetry::KeyValue;
use opentelemetry::{global, Context};
use opentelemetry_otlp::{Protocol, WithExportConfig};
use opentelemetry_sdk::logs::{BatchConfigBuilder, BatchLogProcessor, SdkLoggerProvider};
use opentelemetry_sdk::trace::{BatchSpanProcessor, RandomIdGenerator, Sampler, ShouldSample};
use opentelemetry_sdk::Resource;

use std::{env, io};
use std::time::Duration;

use opentelemetry_appender_tracing::layer::OpenTelemetryTracingBridge;
use tracing::Level;
use tracing_subscriber::{layer::SubscriberExt, util::SubscriberInitExt, EnvFilter};

use crate::DEBUG;

#[derive(Clone, Debug)]
struct CustomSampler {
    default_sampler: Box<dyn ShouldSample>,
}

impl CustomSampler {
    fn new(default_sampler: Box<dyn ShouldSample>) -> Self {
        Self { default_sampler }
    }
}

impl ShouldSample for CustomSampler {
    fn should_sample(
        &self,
        parent_context: Option<&Context>,
        trace_id: TraceId,
        name: &str,
        span_kind: &SpanKind,
        attributes: &[KeyValue],
        links: &[Link],
    ) -> SamplingResult {
        if name == "noop" {
            if *DEBUG {
                println!("drop noop span");
            }
            SamplingResult {
                decision: SamplingDecision::Drop,
                trace_state: TraceState::default(),
                attributes: Vec::new(),
            }
        } else {
            if *DEBUG {
                println!("sample span");
            }
            self.default_sampler.should_sample(
                parent_context,
                trace_id,
                name,
                span_kind,
                attributes,
                links,
            )
        }
    }
}

pub fn get_clock_offset() -> io::Result<Duration> {
    let mut t1_array: [timespec; 5] = [timespec {
        tv_sec: 0,
        tv_nsec: 0,
    }; 5];
    let mut t2_array: [timespec; 5] = [timespec {
        tv_sec: 0,
        tv_nsec: 0,
    }; 5];
    let mut t3_array: [timespec; 5] = [timespec {
        tv_sec: 0,
        tv_nsec: 0,
    }; 5];

    for i in 0..5 {
        unsafe {
            clock_gettime(CLOCK_REALTIME, &mut t1_array[i]);
            clock_gettime(CLOCK_BOOTTIME, &mut t2_array[i]);
            clock_gettime(CLOCK_REALTIME, &mut t3_array[i]);
        }
    }

    let mut min_delta = Duration::from_secs(u64::MAX).as_nanos();
    let mut offset = 0;

    for i in 0..5 {
        //println!("t1: {:?}, t2: {:?}, t3: {:?}", t1_array[i], t2_array[i], t3_array[i]);
        let t1_ns = Duration::new(t1_array[i].tv_sec as u64, t1_array[i].tv_nsec as u32).as_nanos();
        let t2_ns = Duration::new(t2_array[i].tv_sec as u64, t2_array[i].tv_nsec as u32).as_nanos();
        let t3_ns = Duration::new(t3_array[i].tv_sec as u64, t3_array[i].tv_nsec as u32).as_nanos();

        let delta = t3_ns - t1_ns;

        if delta < min_delta {
            min_delta = delta;
            offset = (t3_ns + t1_ns) / 2 - t2_ns;
            println!("offset: {:?}", offset);
        }
    }

    Ok(Duration::from_nanos(offset as u64))
}
    
pub fn init_global_tracer() {
    let collector_ip = env::var("CONTROLLER_PORT_4317_TCP_ADDR").unwrap_or_default();
    let sampler = CustomSampler::new(Box::new(Sampler::AlwaysOn));
    // let sampler = Sampler::AlwaysOn;
    println!("collector ip: {}",collector_ip);
    // let exporter = opentelemetry_stdout::SpanExporter::default();
    let exporter = opentelemetry_otlp::SpanExporter::builder()
    .with_http()
    .with_protocol(Protocol::HttpJson)
        .with_endpoint(format!("http://{}:4318/v1/traces",collector_ip))
        .with_timeout(Duration::from_secs(3))
        .build().unwrap();
    
    let processor = BatchSpanProcessor::builder(exporter)
    .with_batch_config(
        opentelemetry_sdk::trace::BatchConfigBuilder::default()
            .with_max_queue_size(2097152)
            .with_max_export_batch_size(16384)
            .with_scheduled_delay(Duration::from_secs(1))
            .build(),
    )
    .build();
    
    let tracer_provider = opentelemetry_sdk::trace::SdkTracerProvider::builder()
        .with_span_processor(processor)
        .with_sampler(sampler)
        .with_id_generator(RandomIdGenerator::default())
        .with_max_events_per_span(64)
        .with_max_attributes_per_span(16)
        .with_resource(Resource::builder_empty().with_attributes([KeyValue::new("data.source", "chain-scope")]).build())
        .build();
    global::set_tracer_provider(tracer_provider.clone());
}
pub fn init_global_logger() {
    let collector_ip = env::var("CONTROLLER_PORT_4317_TCP_ADDR").unwrap_or_default();
    let exporter = opentelemetry_otlp::LogExporter::builder()
    .with_http()
    .with_protocol(Protocol::HttpJson)
        .with_endpoint(format!("http://{}:4318/v1/logs",collector_ip))
        .with_timeout(Duration::from_secs(1000))
        .build().unwrap();


    let processor = BatchLogProcessor::builder(exporter)
    .with_batch_config(
        BatchConfigBuilder::default()
            .with_max_queue_size(2097152)
            .with_max_export_batch_size(16384)
            .with_scheduled_delay(Duration::from_secs(1))
            .build(),
    ).build();

    let logger_provider = SdkLoggerProvider::builder()
        .with_log_processor(processor)
        .build();

    let otel_tracing_bridge = OpenTelemetryTracingBridge::new(&logger_provider);
    // 配置 tracing-subscriber 以使用 OpenTelemetry 桥接器
    tracing_subscriber::registry()
       .with(EnvFilter::from_default_env().add_directive(Level::INFO.into()))
       .with(otel_tracing_bridge)
       .init();
}
