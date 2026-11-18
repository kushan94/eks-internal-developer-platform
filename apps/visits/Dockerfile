FROM --platform=$BUILDPLATFORM golang:1.27.4-alpine AS build
ARG TARGETOS TARGETARCH
WORKDIR /src
COPY go.mod go.sum ./
RUN go mod download
COPY *.go ./
RUN CGO_ENABLED=0 GOOS=$TARGETOS GOARCH=$TARGETARCH go build -trimpath -ldflags="-s -w" -o /visits .

FROM gcr.io/distroless/static-debian13:nonroot
COPY --from=build /visits /visits
EXPOSE 8080
ENTRYPOINT ["/visits"]
