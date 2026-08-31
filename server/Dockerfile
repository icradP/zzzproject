FROM golang:1.25.4-alpine AS build

RUN apk add --no-cache gcc musl-dev
WORKDIR /src
COPY go.mod go.sum ./
RUN go mod download
COPY . .
RUN CGO_ENABLED=1 go build -trimpath -ldflags="-s -w" -o /out/zzz-im-server ./cmd/server
RUN CGO_ENABLED=0 go build -trimpath -ldflags="-s -w" -o /out/zzz-im-vapid ./cmd/vapid

FROM alpine:3.22

RUN apk add --no-cache ca-certificates curl \
    && addgroup -S -g 10001 zzz \
    && adduser -S -D -H -u 10001 -G zzz zzz \
    && install -d -o zzz -g zzz -m 0750 /data
COPY --from=build /out/zzz-im-server /usr/local/bin/zzz-im-server
COPY --from=build /out/zzz-im-vapid /usr/local/bin/zzz-im-vapid

USER 10001:10001
EXPOSE 8080
VOLUME ["/data"]
HEALTHCHECK --interval=30s --timeout=3s --start-period=10s --retries=3 \
  CMD curl --fail --silent http://127.0.0.1:8080/health || exit 1

ENTRYPOINT ["/usr/local/bin/zzz-im-server"]
CMD ["-addr", ":8080", "-driver", "sqlite", "-dsn", "/data/zzz-im.db", "-media-dir", "/data/media"]
