FROM debian:bookworm-slim

RUN apt-get update \
    && apt-get install -y --no-install-recommends ca-certificates curl gcc git libc6-dev unzip \
    && rm -rf /var/lib/apt/lists/*

RUN curl -fsSL -o /tmp/v.zip https://github.com/vlang/v/releases/download/0.5.2/v_linux.zip \
    && unzip -q /tmp/v.zip -d /opt && rm /tmp/v.zip
ENV PATH=/opt/v:$PATH

ARG VILTRUM_REF=v0.12.3
RUN git clone --depth 1 --branch ${VILTRUM_REF} https://github.com/Tuntii/viltrum /root/.vmodules/viltrum

WORKDIR /app
COPY main.v ./
RUN v -prod -cflags '-march=native' -o viltrum-tfb main.v

EXPOSE 8080
CMD ["./viltrum-tfb"]
