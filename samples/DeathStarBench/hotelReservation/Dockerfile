FROM golang:1.21 as builder

RUN useradd -m -s /bin/bash golanguser

WORKDIR /workspace

COPY --chown=golanguser:golanguser . .

COPY --chown=golanguser:golanguser go.sum go.sum
COPY --chown=golanguser:golanguser go.mod go.mod
COPY --chown=golanguser:golanguser vendor/ vendor/

COPY --chown=golanguser:golanguser cmd/ cmd/
COPY --chown=golanguser:golanguser dialer/ dialer/
COPY --chown=golanguser:golanguser registry/ registry/
COPY --chown=golanguser:golanguser services/ services/
COPY --chown=golanguser:golanguser tls/ tls/
COPY --chown=golanguser:golanguser tracing/ tracing/
COPY --chown=golanguser:golanguser tune/ tune/

COPY --chown=golanguser:golanguser x509/ x509/
COPY --chown=golanguser:golanguser config.json config.json

RUN CGO_ENABLED=0 GOOS=linux GO111MODULE=on go install -ldflags="" -mod=vendor ./cmd/...

USER golanguser
