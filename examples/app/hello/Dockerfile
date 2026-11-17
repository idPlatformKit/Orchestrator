# syntax=docker/dockerfile:1
FROM --platform=${BUILDPLATFORM} golang:1.27 AS build
WORKDIR /src
ENV CGO_ENABLED=0
COPY go.mod go.sum ./
RUN go mod download
COPY . .
ARG TARGETOS
ARG TARGETARCH
RUN GOOS=${TARGETOS} GOARCH=${TARGETARCH} go build -o /hello .

# Non-root and without privileges: runs under Pod Security restricted. The
# user is numeric: with "nonroot", the kubelet can't check runAsNonRoot and
# refuses to start the container.
FROM gcr.io/distroless/static-debian12:nonroot
COPY --from=build /hello /hello
USER 65532:65532
EXPOSE 8080
ENTRYPOINT ["/hello"]
