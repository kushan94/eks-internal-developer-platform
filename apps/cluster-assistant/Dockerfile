FROM --platform=$BUILDPLATFORM golang:1.27.3-alpine AS build
ARG TARGETOS TARGETARCH
WORKDIR /src
COPY go.mod go.sum ./
RUN go mod download
COPY *.go ./
COPY web ./web
RUN CGO_ENABLED=0 GOOS=$TARGETOS GOARCH=$TARGETARCH go build -trimpath -ldflags="-s -w" -o /cluster-assistant .

FROM gcr.io/distroless/static-debian13:nonroot
COPY --from=build /cluster-assistant /cluster-assistant
EXPOSE 8080
ENTRYPOINT ["/cluster-assistant"]
