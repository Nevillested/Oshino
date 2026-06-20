FROM golang:1.25 AS builder

WORKDIR /app
COPY . .
RUN go mod download
RUN CGO_ENABLED=0 GOOS=linux go build -o oshino .

FROM alpine:latest
RUN apk --no-cache add ca-certificates ffmpeg
WORKDIR /root/
COPY --from=builder /app/oshino .
COPY static/ static/
COPY my_cfg my_cfg

EXPOSE 8080
CMD ["./oshino"]
