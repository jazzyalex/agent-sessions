# Linux build image for the shared session core and as-core. Jammy (glibc 2.35) so the
# binary also runs on older distros; it runs unchanged on Ubuntu 24.04.
FROM swift:6.1-jammy
RUN apt-get update && apt-get install -y --no-install-recommends libsqlite3-dev && rm -rf /var/lib/apt/lists/*
WORKDIR /src
