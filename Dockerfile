# syntax=docker/dockerfile:1-labs
FROM public.ecr.aws/docker/library/alpine:3.20 AS base
ENV TZ=UTC
WORKDIR /src

# source stage =================================================================
FROM base AS source
ARG VERSION
ADD https://github.com/jellyfin/jellyfin.git#v$VERSION ./

FROM base AS source-web
ARG VERSION
ADD https://github.com/jellyfin/jellyfin-web.git#v$VERSION ./

# normalize arch ===============================================================
FROM base AS base-arm64
ENV RUNTIME=linux-musl-arm64
FROM base AS base-amd64
ENV RUNTIME=linux-musl-x64

# backend stage ================================================================
FROM base-$TARGETARCH AS build-backend

# dependencies
RUN apk add --no-cache dotnet8-sdk

# source and build
COPY --from=source /src ./
RUN dotnet publish ./Jellyfin.Server \
        --configuration=Release \
        --output=/build \
        --no-self-contained \
        --use-current-runtime \
        -p:TreatWarningsAsErrors=false

# web stage ====================================================================
FROM base AS build-web

# dependencies
RUN apk add --no-cache nodejs npm

# node_modules
COPY --from=source-web /src/package*.json /src/tsconfig.json ./
RUN npm ci --include=dev

# source and build
COPY --from=source-web /src/babel.config.js /src/cssnano.config.js \
    /src/postcss.config.js /src/webpack.common.js /src/webpack.prod.js \
    /src/vite.config.ts ./
COPY --from=source-web /src/src ./src
RUN npm run build:production && \
    mv dist /build

# runtime stage ================================================================
FROM base

ENV S6_VERBOSITY=0 S6_BEHAVIOUR_IF_STAGE2_FAILS=2 PUID=65534 PGID=65534
ENV JELLYFIN_DATA_DIR=/config JELLYFIN_CONFIG_DIR=/config/config
ENV JELLYFIN_CACHE_DIR=/config/cache JELLYFIN_LOG_DIR=/config/logs
WORKDIR /config
VOLUME /config
EXPOSE 8096

# copy files
COPY --from=build-backend /build /app
COPY --from=build-web /build /app/jellyfin-web
COPY ./rootfs/. /

# runtime dependencies
RUN apk add --no-cache tzdata s6-overlay aspnetcore8-runtime curl ffmpeg

# run using s6-overlay
ENTRYPOINT ["/init"]
