FROM ubuntu:24.04 AS build

RUN DEBIAN_FRONTEND=noninteractive


RUN apt-get update \
    && apt install -y tzdata \
    && apt-get install -y curl pkg-config make llvm clang libssl-dev libbpf-dev protobuf-compiler

RUN echo quit | openssl s_client $([ -n "$HTTP_PROXY" ] && echo "-proxy ${HTTP_PROXY#http://}") -showcerts -servername static.rust-lang.org -connect static.rust-lang.org:443 > cacert.crt
# RUN echo quit | openssl s_client  -showcerts -servername static.rust-lang.org -connect static.rust-lang.org:443 > cacert.crt
RUN cp cacert.crt /usr/local/share/ca-certificates/cacert.crt
RUN update-ca-certificates
RUN curl -k https://sh.rustup.rs -sSf | sh -s -- -y
ENV PATH="/root/.cargo/bin:$PATH"
RUN cargo install libbpf-cargo
RUN cargo install cargo-chef

WORKDIR /app


FROM build AS planner
COPY . .
RUN cargo chef prepare --recipe-path recipe.json

FROM build AS builder
COPY --from=planner /app/recipe.json recipe.json

RUN cargo chef cook --release --recipe-path recipe.json

COPY . .

ARG DEBUG_LEVEL=1
ARG EXPORT_EVENTS_AT_TCP=1
ARG EXPORT_SPANS=1
ARG COROUTINE_EXTENSION_SUPPORT=0
ARG COROUTINE_INKERNEL_SUPPORT=0
ARG GRPC_IP_TAGGING=0
ARG GRPC_IP_TAGGING_WITH_REDISTRIBUTE=0

RUN sed -i "s/^#define DEBUG_LEVEL .*/#define DEBUG_LEVEL ${DEBUG_LEVEL}/" src/bpf/common/config.h
RUN sed -i "s/^#define EXPORT_EVENTS_AT_TCP .*/#define EXPORT_EVENTS_AT_TCP ${EXPORT_EVENTS_AT_TCP}/" src/bpf/common/config.h
RUN sed -i "s/^#define EXPORT_SPANS .*/#define EXPORT_SPANS ${EXPORT_SPANS}/" src/bpf/common/config.h
RUN sed -i "s/^#define COROUTINE_EXTENSION_SUPPORT .*/#define COROUTINE_EXTENSION_SUPPORT ${COROUTINE_EXTENSION_SUPPORT}/" src/bpf/common/config.h
RUN sed -i "s/^#define COROUTINE_INKERNEL_SUPPORT .*/#define COROUTINE_INKERNEL_SUPPORT ${COROUTINE_INKERNEL_SUPPORT}/" src/bpf/common/config.h
RUN sed -i "s/^#define GRPC_IP_TAGGING .*/#define GRPC_IP_TAGGING ${GRPC_IP_TAGGING}/" src/bpf/common/config.h
RUN sed -i "s/^#define GRPC_IP_TAGGING_WITH_REDISTRIBUTE .*/#define GRPC_IP_TAGGING_WITH_REDISTRIBUTE ${GRPC_IP_TAGGING_WITH_REDISTRIBUTE}/" src/bpf/common/config.h

# print env
RUN echo "DEBUG_LEVEL: ${DEBUG_LEVEL}"
RUN echo "EXPORT_EVENTS_AT_TCP: ${EXPORT_EVENTS_AT_TCP}"
RUN echo "EXPORT_SPANS: ${EXPORT_SPANS}"
RUN echo "COROUTINE_EXTENSION_SUPPORT: ${COROUTINE_EXTENSION_SUPPORT}"
RUN echo "COROUTINE_INKERNEL_SUPPORT: ${COROUTINE_INKERNEL_SUPPORT}"
RUN echo "GRPC_IP_TAGGING: ${GRPC_IP_TAGGING}"
RUN echo "GRPC_IP_TAGGING_WITH_REDISTRIBUTE: ${GRPC_IP_TAGGING_WITH_REDISTRIBUTE}"

#RUN cargo clean
RUN cargo build -r

FROM ubuntu:24.04 AS main

RUN apt-get update \
    && apt-get install -y libbpf-dev libssl-dev bpftrace iproute2 \
    && apt-get clean

WORKDIR /app
COPY --from=builder /app/target/release/chain_scope .

ENTRYPOINT ["./chain_scope"]
